import Foundation
import Hokusai
import Hummingbird

extension Request {
    /// Decodes a raw image upload into an immutable Hokusai pipeline.
    ///
    /// Hummingbird request bodies are streamed. This method consumes the body once
    /// and rejects uploads that exceed `maximumSize`.
    public func hokusaiImage(
        maximumSize: Int = 20 * 1024 * 1024
    ) async throws -> Hokusai {
        guard maximumSize > 0 else {
            throw HTTPError(.internalServerError, message: "Hokusai maximum upload size must be positive")
        }

        var data = Data()
        for try await buffer in self.body {
            guard buffer.readableBytes <= maximumSize - data.count else {
                throw HTTPError(.contentTooLarge, message: "Image upload exceeds the configured size limit")
            }
            guard let chunk = buffer.getData(at: buffer.readerIndex, length: buffer.readableBytes) else {
                throw HTTPError(.badRequest, message: "Failed to read image data from request")
            }
            data.append(chunk)
        }
        guard !data.isEmpty else {
            throw HTTPError(.badRequest, message: "No image data in request body")
        }
        do {
            return try Hokusai(data: data)
        } catch {
            throw HTTPError(.badRequest, message: "Invalid image data")
        }
    }
}
