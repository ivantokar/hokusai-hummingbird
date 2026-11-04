import Foundation
import Hokusai
import HokusaiHummingbird
import Hummingbird
import NIOCore
import NIOPosix
import Testing

/// Real connections to a real server (hokusai #126): a client that reads slowly, a
/// client that disconnects part-way, and the evaluation slot afterwards. The body-level
/// tests in StreamingTests use a stand-in writer; these use sockets.
@Suite(.serialized) struct LiveHTTPTests {
    /// A server on an ephemeral port that streams `pipeline` at `/image`.
    private func withServer(
        _ pipeline: Hokusai, chunkSize: Int = 16 * 1024, _ body: @escaping @Sendable (Int) async throws -> Void
    ) async throws {
        let router = Router()
        router.get("image") { _, _ in try await pipeline.response(chunkSize: chunkSize) }
        let (ports, continuation) = AsyncStream<Int>.makeStream()
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: 0)),
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

    /// Waits until no evaluation holds a slot, which is what a dropped connection must lead to.
    private func slotsRelease(within seconds: Double = 15) async -> Bool {
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

    @Test(.timeLimit(.minutes(2)))
    func aSlowReadingClientReceivesEveryByte() async throws {
        let pipeline = try Hokusai(data: gradientTIFF(width: 600, height: 400)).png(compressionLevel: 0)
        let expected = try await pipeline.data().data
        try await withServer(pipeline) { port in
            let channel = try await connect(port)
            var received: [UInt8] = []
            try await channel.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "GET /image HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
                for try await buffer in inbound {
                    received += buffer.readableBytesView
                    try await Task.sleep(for: .milliseconds(20))   // far slower than the encoder
                }
            }
            let (payload, complete) = self.decodeChunked(received)
            #expect(complete, "the chunked body was not terminated")
            #expect(payload == [UInt8](expected), "\(payload.count) bytes arrived, expected \(expected.count)")
        }
        #expect(await slotsRelease())
    }

    @Test(.timeLimit(.minutes(2)))
    func aClientThatDisconnectsMidResponseReleasesTheEvaluation() async throws {
        let pipeline = try Hokusai(data: gradientTIFF(width: 2000, height: 2000)).png(compressionLevel: 0)
        try await withServer(pipeline, chunkSize: 4096) { port in
            for _ in 0..<5 {
                let channel = try await connect(port)
                try await channel.executeThenClose { inbound, outbound in
                    try await outbound.write(ByteBuffer(string: "GET /image HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
                    var seen = 0
                    for try await buffer in inbound {
                        seen += buffer.readableBytes
                        if seen > 20_000 { break }   // leaves the loop, which closes the connection
                    }
                }
            }
            #expect(await self.slotsRelease(), "an evaluation still holds a slot after every client left")
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func theServerStillServesAfterDroppedConnections() async throws {
        let pipeline = try Hokusai(data: gradientTIFF(width: 800, height: 800)).png(compressionLevel: 0)
        let expected = try await pipeline.data().data
        try await withServer(pipeline, chunkSize: 4096) { port in
            for _ in 0..<3 {
                let channel = try await connect(port)
                try await channel.executeThenClose { inbound, outbound in
                    try await outbound.write(ByteBuffer(string: "GET /image HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
                    for try await _ in inbound { break }
                }
            }
            let channel = try await connect(port)
            var received: [UInt8] = []
            try await channel.executeThenClose { inbound, outbound in
                try await outbound.write(ByteBuffer(string: "GET /image HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
                for try await buffer in inbound { received += buffer.readableBytesView }
            }
            let (payload, complete) = self.decodeChunked(received)
            #expect(complete && payload == [UInt8](expected), "a full request after dropped ones did not get the whole image")
        }
    }
}
