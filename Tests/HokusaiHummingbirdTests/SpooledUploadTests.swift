import Foundation
import Hokusai
import HokusaiHummingbird
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

/// Uploads spooled to a temporary file (hokusai#112): the route reads the body with
/// `memoryLimit: 0`, so every upload goes through the spool file, and the file must be gone
/// once the request is over.
@Suite struct SpooledUploadTests {
    private func router(spool: URL) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: HokusaiErrorMiddleware())
        router.post("spool") { request, _ -> Response in
            try await request.hokusaiImage(maximumSize: 1 << 20, memoryLimit: 0, spoolDirectory: spool)
                .png().response()
        }
        router.post("small") { request, _ -> Response in
            try await request.hokusaiImage(maximumSize: 100, memoryLimit: 0, spoolDirectory: spool)
                .png().response()
        }
        return router
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hokusai-hb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pipeline is released when the response has been sent, which can be a moment after the
    /// client has read it, so the directory is polled briefly.
    private func isEmpty(_ directory: URL) async throws -> Bool {
        for _ in 0..<50 {
            if try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @Test func aSpooledUploadIsProcessedAndItsFileRemoved() async throws {
        let spool = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        let app = Application(router: router(spool: spool))
        try await app.test(.router) { client in
            try await client.execute(uri: "/spool", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                let info = try await Hokusai(buffer: response.body).png().data().info
                #expect(info.width == 24)
            }
        }
        #expect(try await isEmpty(spool))
    }

    @Test func anUploadOverTheLimitIs413AndLeavesNoFile() async throws {
        let spool = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        let app = Application(router: router(spool: spool))
        try await app.test(.router) { client in
            try await client.execute(uri: "/small", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .contentTooLarge)
            }
        }
        #expect(try await isEmpty(spool))
    }

    @Test func anEmptyBodyIs400AndLeavesNoFile() async throws {
        let spool = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: spool) }
        let app = Application(router: router(spool: spool))
        try await app.test(.router) { client in
            try await client.execute(uri: "/spool", method: .post) { response in
                #expect(response.status == .badRequest)
            }
        }
        #expect(try await isEmpty(spool))
    }

    @Test func aMissingSpoolDirectoryIs500() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("hokusai-missing-\(UUID().uuidString)")
        let app = Application(router: router(spool: missing))
        try await app.test(.router) { client in
            try await client.execute(uri: "/spool", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .internalServerError)
            }
        }
    }
}
