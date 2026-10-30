import Hokusai
import HokusaiNIO
import Hummingbird
import NIOCore

extension Hokusai {
    /// A streamed image or PDF response for this pipeline.
    ///
    /// Choose the encoder on the pipeline first (`.webp(quality: 82)`,
    /// `.pdf()`, ...); `Content-Type` comes from the format it produces. The
    /// body is written with ``Hokusai/writeByteBuffers(allocator:chunkSize:_:)``,
    /// so each buffer is handed to Hummingbird's writer as it is encoded and a
    /// slow client slows encoding down; the complete output is never held (a
    /// TIFF is the one exception, see Hokusai's streaming notes). When the
    /// client disconnects Hummingbird cancels the request task, which stops
    /// the evaluation.
    ///
    /// Before the response is committed the source header is read, so a missing
    /// or unreadable image becomes a `4xx` instead of a broken `200`. A failure
    /// after the first byte can only end the stream early.
    ///
    /// - Parameters:
    ///   - status: Response status.
    ///   - headers: Extra headers; `Content-Type` is set from the encoder.
    ///   - chunkSize: Target size of each streamed buffer.
    ///   - allocator: Allocates each buffer; pass the channel's allocator if you have it.
    public func response(
        status: HTTPResponse.Status = .ok,
        headers: HTTPFields = [:],
        chunkSize: Int = 64 * 1024,
        allocator: ByteBufferAllocator = ByteBufferAllocator()
    ) async throws -> Response {
        guard let format = outputFormat else {
            throw HTTPError(.internalServerError, message: "Select an encoder (for example .webp() or .pdf()) before building a response")
        }
        do {
            _ = try await metadata()
        } catch let error as HokusaiError {
            throw error.httpError
        }

        var headers = headers
        headers[.contentType] = format.mimeType
        let pipeline = self
        return Response(status: status, headers: headers, body: ResponseBody { writer in
            try await pipeline.writeByteBuffers(allocator: allocator, chunkSize: chunkSize) { buffer in
                try await writer.write(buffer)
            }
            try await writer.finish(nil)
        })
    }
}
