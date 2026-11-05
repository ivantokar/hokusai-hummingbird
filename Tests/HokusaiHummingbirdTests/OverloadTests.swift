import Foundation
import Hokusai
import HokusaiHummingbird
import Hummingbird
import NIOCore
import NIOPosix
import Testing

/// Overload and failures after output began, over real connections (hokusai #126).
///
/// The runtime configuration freezes at first use, so these need a process of their own with a
/// single evaluation slot and no queue. They are skipped unless `HOKUSAI_OVERLOAD_TESTS=1`;
/// run them with `HOKUSAI_OVERLOAD_TESTS=1 swift test --filter OverloadTests` (CI does).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HOKUSAI_OVERLOAD_TESTS"] == "1"))
struct OverloadTests {
    /// Applied once for the process: a suite value is made again for every test, and the
    /// configuration can be set only once.
    private static let configured = Result { try Hokusai.configure(.init(maxConcurrentEvaluations: .fixed(1), maxQueuedEvaluations: 0)) }

    init() throws { try Self.configured.get() }

    private func withServer(_ routes: (Router<BasicRequestContext>) -> Void, _ body: @escaping @Sendable (Int) async throws -> Void) async throws {
        let router = Router()
        routes(router)
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router, configuration: .init(address: .hostname("127.0.0.1", port: 0)),
            onServerRunning: { channel in continuation.yield(channel.localAddress?.port ?? 0) })
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await app.runService() }
            var port = 0
            for await value in ports { port = value; break }
            try await body(port)
            group.cancelAll()
        }
    }

    private func connect(_ port: Int) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        try await ClientBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .connect(host: "127.0.0.1", port: port) { channel in
                channel.eventLoop.makeCompletedFuture { try NIOAsyncChannel(wrappingChannelSynchronously: channel) }
            }
    }

    private func requestText(_ path: String) -> String { "GET \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" }

    /// Sends a request and reads until the server closes or `limit` bytes arrived.
    private func fetch(_ port: Int, _ path: String, limit: Int = .max) async throws -> [UInt8] {
        let channel = try await connect(port)
        var received: [UInt8] = []
        try await channel.executeThenClose { inbound, outbound in
            try await outbound.write(ByteBuffer(string: requestText(path)))
            for try await buffer in inbound {
                received += buffer.readableBytesView
                if received.count >= limit { break }
            }
        }
        return received
    }

    private func slotsFree(within seconds: Double = 15) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Hokusai.runtimeStatus.activeEvaluations == 0 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Decodes a chunked body: the payload bytes and whether the terminating chunk arrived.
    private func decodeChunked(_ bytes: [UInt8]) -> (payload: [UInt8], complete: Bool) {
        var payload: [UInt8] = []
        var index = bytes.firstRange(of: [13, 10, 13, 10]).map { $0.upperBound } ?? bytes.count
        while index < bytes.count {
            guard let lineEnd = bytes[index...].firstRange(of: [13, 10])?.lowerBound,
                let size = Int(String(decoding: bytes[index..<lineEnd], as: UTF8.self), radix: 16)
            else { return (payload, false) }
            index = lineEnd + 2
            if size == 0 { return (payload, true) }
            guard index + size <= bytes.count else { return (payload, false) }
            payload += bytes[index..<index + size]
            index += size + 2
        }
        return (payload, false)
    }

    private func text(_ bytes: [UInt8], _ count: Int = 400) -> String { String(decoding: bytes.prefix(count), as: UTF8.self) }

    /// With one slot and no queue, a request that arrives while another is being served is refused
    /// with a 503 and a JSON body naming the queue, the busy one is not disturbed, and the server
    /// serves again as soon as the slot is free.
    @Test(.timeLimit(.minutes(2)))
    func aRequestWhileTheOnlySlotIsBusyGets503AndTheServerRecovers() async throws {
        let big = try Hokusai(data: gradientTIFF(width: 2000, height: 2000)).png(compressionLevel: 0)
        let small = try Hokusai(data: gradientTIFF(width: 200, height: 200)).png(compressionLevel: 0)
        let expectedSmall = try await small.data().data
        try await withServer({ router in
            router.get("big") { _, _ in try await big.response(chunkSize: 4096) }
            router.get("small") { _, _ in try await small.response(chunkSize: 4096) }
        }) { port in
            // The first client takes the slot and then does not read, so its encoder stays blocked.
            let first = try await self.connect(port)
            try await first.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: self.requestText("/big")))
                var iterator = inbound.makeAsyncIterator()
                _ = try await iterator.next()
                try await Task.sleep(for: .milliseconds(300))
                #expect(Hokusai.runtimeStatus.activeEvaluations == 1, "the first request should hold the slot")

                let refused = try await self.fetch(port, "/small", limit: 100_000)
                let head = self.text(refused)
                #expect(head.hasPrefix("HTTP/1.1 503"), "expected 503, got: \(head.prefix(40))")
                #expect(head.contains("application/json") && head.contains("queuedEvaluations"), "the refusal should be a JSON error naming the queue: \(head)")
                #expect(Hokusai.runtimeStatus.queuedEvaluations == 0, "a refused request must not wait in the queue")
                #expect(Hokusai.runtimeStatus.activeEvaluations == 1, "the busy request was disturbed")
            }
            // The first client left, which cancels its evaluation and frees the slot.
            #expect(await self.slotsFree(), "the slot was not released after the first client left")

            let again = try await self.fetch(port, "/small")
            #expect(self.text(again, 20).hasPrefix("HTTP/1.1 200"))
            let (payload, complete) = self.decodeChunked(again)
            #expect(complete && payload == [UInt8](expectedSmall), "the server did not recover after the overload")
        }
    }

    /// A pipeline that fails once output has begun cannot change the status line it already sent.
    /// What it must do is end the body without the terminating chunk, so the client can tell the
    /// image is incomplete, and give the slot back.
    @Test(.timeLimit(.minutes(2)))
    func aFailureAfterOutputBeganTruncatesTheBodyAndFreesTheSlot() async throws {
        // A PNG cut in half, read sequentially: the header is fine and the pixels fail part-way.
        let whole = try await Hokusai(data: gradientTIFF(width: 1500, height: 1500)).png(compressionLevel: 0).data().data
        let broken = try Hokusai(data: Data(whole.prefix(whole.count / 2)), options: InputOptions(access: .sequential, failOn: .truncated)).png(compressionLevel: 0)
        let healthy = try Hokusai(data: gradientTIFF(width: 100, height: 100)).png()
        let expectedHealthy = try await healthy.data().data
        try await withServer({ router in
            router.get("broken") { _, _ in try await broken.response(chunkSize: 512) }
            router.get("healthy") { _, _ in try await healthy.response() }
        }) { port in
            let received = try await self.fetch(port, "/broken")
            #expect(self.text(received, 20).hasPrefix("HTTP/1.1 200"), "output had begun, so the status was already 200")
            let (payload, complete) = self.decodeChunked(received)
            #expect(!complete, "the body ended cleanly although the image failed part-way")
            #expect(!payload.isEmpty, "this test expects the failure to come after output began")
            #expect(await self.slotsFree(), "the failed evaluation still holds its slot")

            let ok = try await self.fetch(port, "/healthy")
            let (body, finished) = self.decodeChunked(ok)
            #expect(finished && body == [UInt8](expectedHealthy), "the server did not serve after the failure")
        }
    }
}
