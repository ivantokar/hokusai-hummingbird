import Hokusai
import HokusaiNIO
import Hummingbird
import NIOCore

extension Request {
    /// Reads a raw image upload into an immutable Hokusai pipeline.
    ///
    /// Hokusai decodes a complete source, so the body is collected, but never
    /// beyond `maximumSize`: a declared `Content-Length` over the limit is
    /// rejected before any byte is read, and a body without one is rejected as
    /// soon as it grows past the limit. Both give `413 Content Too Large`, and
    /// an empty body gives `400 Bad Request`.
    ///
    /// The bytes are collected into one buffer and handed to
    /// ``Hokusai/init(buffer:options:byteTransferStrategy:)``; nothing is
    /// decoded here, so a corrupt image surfaces when the pipeline is
    /// evaluated (``Hokusai/response(status:headers:chunkSize:allocator:)`` does that
    /// before it commits to a response).
    ///
    /// - Parameters:
    ///   - options: Input options, including Hokusai's own decode limits.
    ///   - maximumSize: Largest accepted upload, in bytes.
    public func hokusaiImage(
        options: InputOptions = .init(),
        maximumSize: Int = 20 * 1024 * 1024
    ) async throws -> Hokusai {
        guard maximumSize > 0 else {
            throw HTTPError(.internalServerError, message: "The Hokusai maximum upload size must be positive")
        }
        if let declared = headers[.contentLength].flatMap({ Int($0) }), declared > maximumSize {
            throw HTTPError(.contentTooLarge, message: "The image upload exceeds the configured size limit")
        }

        var collected = ByteBufferAllocator().buffer(capacity: min(headers[.contentLength].flatMap { Int($0) } ?? 64 * 1024, maximumSize))
        for try await buffer in body {
            guard buffer.readableBytes <= maximumSize - collected.readableBytes else {
                throw HTTPError(.contentTooLarge, message: "The image upload exceeds the configured size limit")
            }
            collected.writeImmutableBuffer(buffer)
        }
        guard collected.readableBytes > 0 else {
            throw HTTPError(.badRequest, message: "No image data in the request body")
        }
        do {
            return try Hokusai(buffer: collected, options: options)
        } catch let error as HokusaiError {
            throw error.httpError
        }
    }
}
