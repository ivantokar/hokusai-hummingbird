import Foundation
import Hokusai
import HokusaiHummingbird
import HokusaiNIO
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing

/// A 24x16 gradient as an uncompressed little-endian TIFF, so the tests need no fixture files.
func gradientTIFF(width: Int = 24, height: Int = 16) -> Data {
    var data = Data()
    func u16(_ value: Int) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]) }
    func u32(_ value: Int) { u16(value & 0xFFFF); u16((value >> 16) & 0xFFFF) }
    func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Int) { u16(tag); u16(type); u32(count); u32(value) }
    let entries = 9
    let arrayOffset = 8 + 2 + entries * 12 + 4
    let pixelOffset = arrayOffset + 6
    data.append(contentsOf: [0x49, 0x49, 42, 0])
    u32(8)
    u16(entries)
    entry(256, 4, 1, width); entry(257, 4, 1, height); entry(258, 3, 3, arrayOffset)
    entry(259, 3, 1, 1); entry(262, 3, 1, 2); entry(273, 4, 1, pixelOffset)
    entry(277, 3, 1, 3); entry(278, 4, 1, height); entry(279, 4, 1, width * height * 3)
    u32(0)
    for _ in 0..<3 { u16(8) }
    for y in 0..<height { for x in 0..<width { data.append(contentsOf: [UInt8(x * 10 % 256), UInt8(y * 14 % 256), UInt8((x + y) % 256)]) } }
    return data
}

private func router() -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: HokusaiErrorMiddleware())
    router.post("webp") { request, _ -> Response in
        try await request.hokusaiImage(maximumSize: 1 << 20).resize(width: 12).webp(quality: 80).response()
    }
    router.post("png") { request, _ -> Response in
        try await request.hokusaiImage(maximumSize: 1 << 20).png().response(headers: [.cacheControl: "no-store"])
    }
    router.post("pdf") { request, _ -> Response in
        try await request.hokusaiImage(maximumSize: 1 << 20).pdf().response()
    }
    router.post("small") { request, _ -> Response in
        try await request.hokusaiImage(maximumSize: 100).png().response()
    }
    router.post("noencoder") { request, _ -> Response in
        try await request.hokusaiImage(maximumSize: 1 << 20).response()
    }
    router.post("evaluate") { request, _ -> Response in
        // A route that evaluates the pipeline itself relies on the middleware for its errors.
        let output = try await request.hokusaiImage(options: InputOptions(limits: InputLimits(maxPixels: 10)), maximumSize: 1 << 20).png().data()
        return Response(status: .ok, body: .init(byteBuffer: ByteBuffer(data: output.data)))
    }
    return router
}

@Suite struct ResponseTests {
    private func canEncode(_ format: ImageFormat) -> Bool { (try? Hokusai.capabilities().canEncode(format)) ?? false }

    @Test func aWebPResponseStreamsADecodableImageWithItsContentType() async throws {
        guard canEncode(.webp) else { return }
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/webp", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/webp")
                let info = try await Hokusai(buffer: response.body).png().data().info
                #expect(info.width == 12 && info.height == 8)
            }
        }
    }

    @Test func extraHeadersAreKeptAndContentTypeFollowsTheEncoder() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/png", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.headers[.contentType] == "image/png")
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.body.getBytes(at: 0, length: 4) == [0x89, 0x50, 0x4E, 0x47])
            }
        }
    }

    @Test func aPDFUsesTheSameStreamingPath() async throws {
        guard canEncode(.pdf) else { return }
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/pdf", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.headers[.contentType] == "application/pdf")
                #expect(response.body.getString(at: 0, length: 5) == "%PDF-")
            }
        }
    }

    /// Over a real socket the body goes out chunked, with no Content-Length.
    @Test func aLiveServerStreamsAChunkedBody() async throws {
        let app = Application(router: router())
        try await app.test(.live) { client in
            try await client.execute(uri: "/png", method: .post, body: ByteBuffer(data: gradientTIFF(width: 200, height: 150))) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentLength] == nil)
                #expect(response.headers[.transferEncoding] == "chunked")
                let info = try await Hokusai(buffer: response.body).png().data().info
                #expect(info.width == 200 && info.height == 150)
            }
        }
    }

    // MARK: - Upload limits

    @Test func anOversizedUploadIsRejectedWith413() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/small", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .contentTooLarge)
            }
        }
    }

    @Test func anEmptyUploadIs400() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/png", method: .post, body: ByteBuffer()) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test func anUndecodableUploadIsA4xxBeforeAnyBodyIsSent() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/png", method: .post, body: ByteBuffer(bytes: [UInt8](repeating: 0x42, count: 256))) { response in
                #expect(response.status == .unprocessableContent)
                #expect(response.headers[.contentType] != "image/png")
            }
        }
    }

    @Test func aMissingEncoderIsAServerError() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/noencoder", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .internalServerError)
            }
        }
    }

    @Test func theMiddlewareMapsAHokusaiLimitToItsStatus() async throws {
        let app = Application(router: router())
        try await app.test(.router) { client in
            try await client.execute(uri: "/evaluate", method: .post, body: ByteBuffer(data: gradientTIFF())) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
    }

    // MARK: - Error mapping

    @Test func everyErrorCaseHasADocumentedStatus() throws {
        let context = FailureContext(operation: "op", reason: "r")
        let cases: [(HokusaiError, HTTPResponse.Status)] = [
            (.invalidInput(reason: "x"), .badRequest),
            (.invalidOption(name: "n", reason: "r"), .badRequest),
            (.decode(context), .unprocessableContent),
            (.resource(ResourceFailure(kind: .encodedBytes, limit: 1, actual: 2, reason: "r")), .contentTooLarge),
            (.resource(ResourceFailure(kind: .decodedPixels, limit: 1, actual: 2, reason: "r")), .unprocessableContent),
            (.resource(ResourceFailure(kind: .queuedEvaluations, limit: 1, actual: 2, reason: "r")), .serviceUnavailable),
            (.unsupported(feature: "f", reason: "r"), .notImplemented),
            (.transform(context), .internalServerError),
            (.encode(context), .internalServerError),
        ]
        for (error, status) in cases { #expect(error.httpStatus == status, "\(error)") }
    }
}
