import Foundation
import Hokusai
import HokusaiNIO
import Hummingbird
import NIOCore

extension Request {
    /// Reads a raw image upload into an immutable Hokusai pipeline.
    ///
    /// The body is read as it arrives and never beyond `maximumSize`: a declared
    /// `Content-Length` over the limit is rejected before any byte is read, and a
    /// body without one is rejected as soon as it grows past the limit. Both give
    /// `413 Content Too Large`, and an empty body gives `400 Bad Request`.
    ///
    /// A small upload stays in memory. One larger than `memoryLimit` bytes moves to
    /// a private temporary file (``Hokusai/init(spooling:options:memoryLimit:spoolDirectory:)``),
    /// so the encoded upload occupies at most `memoryLimit` plus one chunk of memory
    /// however large `maximumSize` is. The pipeline owns the file and removes it
    /// when the last copy of the pipeline is released.
    ///
    /// Nothing is decoded here, so a corrupt image surfaces when the pipeline is
    /// evaluated (``Hokusai/response(status:headers:chunkSize:allocator:)`` does that
    /// before it commits to a response).
    ///
    /// - Parameters:
    ///   - options: Input options, including Hokusai's own decode limits. The
    ///     byte limit is the smaller of `options.limits.maxBytes` and `maximumSize`.
    ///   - maximumSize: Largest accepted upload, in bytes.
    ///   - memoryLimit: The largest upload kept in memory, in bytes (default 1 MiB).
    ///   - spoolDirectory: Where a larger upload is spooled. Defaults to the
    ///     system temporary directory; it must exist.
    public func hokusaiImage(
        options: InputOptions = .init(),
        maximumSize: Int = 20 * 1024 * 1024,
        memoryLimit: Int = 1_048_576,
        spoolDirectory: URL? = nil
    ) async throws -> Hokusai {
        guard maximumSize > 0 else {
            throw HTTPError(.internalServerError, message: "The Hokusai maximum upload size must be positive")
        }
        if let declared = headers[.contentLength].flatMap({ Int($0) }), declared > maximumSize {
            throw HTTPError(.contentTooLarge, message: "The image upload exceeds the configured size limit")
        }
        var options = options
        options.limits.maxBytes = min(options.limits.maxBytes, maximumSize)
        do {
            return try await Hokusai(
                spooling: body, options: options, memoryLimit: memoryLimit, spoolDirectory: spoolDirectory)
        } catch let error as HokusaiError {
            throw error.httpError
        }
    }
}
