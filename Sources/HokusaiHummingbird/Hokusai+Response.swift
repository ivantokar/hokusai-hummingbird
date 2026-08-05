import Hokusai
import Hummingbird
import NIOCore

extension Hokusai {
    /// Evaluates the pipeline and returns an image or raster PDF Hummingbird response.
    public func response(
        format: String = "jpeg",
        quality: Int? = nil,
        compression: Int? = nil,
        status: HTTPResponse.Status = .ok
    ) async throws -> Response {
        let outputFormat = try HokusaiHummingbirdOutput.format(
            named: format,
            quality: quality,
            compression: compression
        )
        let output = try await encode(as: outputFormat).data()
        var headers = HTTPFields()
        headers[.contentType] = output.info.format.mimeType
        var buffer = ByteBufferAllocator().buffer(capacity: output.data.count)
        buffer.writeBytes(output.data)
        return Response(status: status, headers: headers, body: .init(byteBuffer: buffer))
    }
}

private enum HokusaiHummingbirdOutput {
    static func format(named name: String, quality: Int?, compression: Int?) throws -> OutputFormat {
        switch name.lowercased() {
        case "jpeg", "jpg": return .jpeg(.init(quality: quality ?? 80))
        case "png": return .png(.init(compressionLevel: compression ?? quality ?? 6))
        case "webp": return .webp(.init(quality: quality ?? 80))
        case "avif": return .avif(.init(quality: quality ?? 50))
        case "pdf": return .pdf()
        default:
            throw HTTPError(.badRequest, message: "Unsupported Hokusai output format: \(name)")
        }
    }
}
