import Foundation
import Hokusai
import HokusaiHummingbird
import Hummingbird
import Testing

private actor HokusaiTestRuntime {
    static let shared = HokusaiTestRuntime()
    private var isInitialized = false

    func ensureInitialized() throws {
        if !isInitialized {
            try Hokusai.initialize()
            isInitialized = true
        }
    }
}

private let samplePngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO9KX5kAAAAASUVORK5CYII="

@Test func pngResponseHasContentType() async throws {
    try await HokusaiTestRuntime.shared.ensureInitialized()
    let image = try Hokusai(data: #require(Data(base64Encoded: samplePngBase64)))
    let response = try await image.response(format: "png")

    #expect(response.status == .ok)
    #expect(response.headers[.contentType] == "image/png")
}

@Test func pdfResponseHasContentType() async throws {
    let image = try Hokusai(data: #require(Data(base64Encoded: samplePngBase64)))
    let response = try await image.response(format: "pdf")

    #expect(response.headers[.contentType] == "application/pdf")
}

@Test func rawRequestBodyDecodesToHokusaiPipeline() async throws {
    try await HokusaiTestRuntime.shared.ensureInitialized()
    let data = try #require(Data(base64Encoded: samplePngBase64))
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    let request = Request(
        head: HTTPRequest(method: .post, scheme: nil, authority: nil, path: "/resize"),
        body: .init(buffer: buffer)
    )

    let image = try await request.hokusaiImage(maximumSize: data.count)
    #expect(try image.metadata().width == 1)
    #expect(try image.metadata().height == 1)
}
