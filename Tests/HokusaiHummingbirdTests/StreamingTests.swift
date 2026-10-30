import Foundation
import Hokusai
import HokusaiHummingbird
import Hummingbird
import NIOCore
import Testing

/// What a client connection sees: a writer Hummingbird would hand to the body.
private final class Wire: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [ByteBuffer] = []
    private var finished = false
    var received: [ByteBuffer] { lock.withLock { chunks } }
    var isFinished: Bool { lock.withLock { finished } }
    func append(_ buffer: ByteBuffer) { lock.withLock { chunks.append(buffer) } }
    func finish() { lock.withLock { finished = true } }
}

private struct WireFailure: Error {}

private struct WireWriter: ResponseBodyWriter {
    let wire: Wire
    var delay: Duration?
    var failAfter: Int?
    var stallForever = false

    mutating func write(_ buffer: ByteBuffer) async throws {
        if stallForever { try await Task.sleep(for: .seconds(60)) }
        if let delay { try await Task.sleep(for: delay) }
        if let failAfter, wire.received.count >= failAfter { throw WireFailure() }
        wire.append(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws { wire.finish() }
}

@Suite struct StreamingTests {
    private func pipeline() throws -> Hokusai {
        try Hokusai(data: gradientTIFF(width: 320, height: 240)).png(compressionLevel: 0)
    }

    @Test func theBodyIsWrittenInBoundedBuffersAndFinished() async throws {
        let image = try pipeline()
        let direct = try await image.data()
        let response = try await image.response(chunkSize: 4096)
        #expect(response.body.contentLength == nil, "a streamed body has no declared length")

        let wire = Wire()
        try await response.body.write(WireWriter(wire: wire))
        let buffers = wire.received
        #expect(buffers.count > 5)
        #expect(buffers.allSatisfy { $0.readableBytes > 0 && $0.readableBytes <= 4096 })
        #expect(buffers.flatMap { Array($0.readableBytesView) } == [UInt8](direct.data))
        #expect(wire.isFinished)
    }

    @Test func aSlowClientLosesNothing() async throws {
        let image = try pipeline()
        let direct = try await image.data()
        let wire = Wire()
        try await image.response(chunkSize: 8192).body.write(WireWriter(wire: wire, delay: .milliseconds(3)))
        #expect(wire.received.flatMap { Array($0.readableBytesView) } == [UInt8](direct.data))
    }

    @Test func aWriterFailureStopsEncodingAndSurfaces() async throws {
        let image = try pipeline()
        let wire = Wire()
        do {
            try await image.response(chunkSize: 4096).body.write(WireWriter(wire: wire, failAfter: 2))
            Issue.record("expected the writer's error")
        } catch is WireFailure {
            #expect(wire.received.count == 2)
            #expect(!wire.isFinished)
        } catch {
            Issue.record("expected WireFailure, got \(error)")
        }
        // The evaluation slot was released: another response still works.
        let wireAfter = Wire()
        try await image.response(chunkSize: 65536).body.write(WireWriter(wire: wireAfter))
        #expect(wireAfter.isFinished)
    }

    /// Hummingbird cancels the request task when the client disconnects.
    @Test func aDisconnectCancelsTheEvaluation() async throws {
        let image = try Hokusai(data: gradientTIFF(width: 1500, height: 1500)).png(compressionLevel: 0)
        let response = try await image.response(chunkSize: 4096)
        let wire = Wire()
        let task = Task { try await response.body.write(WireWriter(wire: wire, stallForever: true)) }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        do {
            try await task.value
            Issue.record("expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(Date().timeIntervalSince(start) < 10)
        #expect(!wire.isFinished)
    }
}
