import Hokusai
import Hummingbird

extension HokusaiError {
    /// The HTTP error a request should fail with.
    ///
    /// The caller's mistakes are `4xx` and everything about this server is
    /// `5xx`, decided by the error case and never by message text:
    ///
    /// | Case | Status |
    /// | --- | --- |
    /// | `invalidInput`, `invalidOption` | 400 |
    /// | `decode` | 422 |
    /// | `resource` for bytes | 413 |
    /// | `resource` for pixels or channels | 422 |
    /// | `resource` for the evaluation queue | 503 |
    /// | `unsupported` | 501 |
    /// | `io`, `transform`, `encode`, `runtime` | 500 |
    public var httpStatus: HTTPResponse.Status {
        switch self {
        case .invalidInput, .invalidOption: .badRequest
        case .decode: .unprocessableContent
        case .resource(let failure):
            switch failure.kind {
            case .encodedBytes: .contentTooLarge
            case .queuedEvaluations: .serviceUnavailable
            default: .unprocessableContent
            }
        case .unsupported: .notImplemented
        case .io, .transform, .encode, .runtime: .internalServerError
        }
    }

    /// ``httpStatus`` with Hokusai's own description as the message.
    public var httpError: HTTPError {
        HTTPError(httpStatus, message: errorDescription ?? "Image processing failed")
    }
}

/// Turns a ``HokusaiError`` thrown by a route into its ``HokusaiError/httpError``.
///
/// ``Hokusai/response(status:headers:chunkSize:allocator:)`` and
/// ``Request/hokusaiImage(options:maximumSize:)`` already do this for what they
/// run; add the middleware for pipelines a route evaluates itself with
/// `data()` or `write(to:)`. `CancellationError` passes through.
public struct HokusaiErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    public init() {}

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as HokusaiError {
            throw error.httpError
        }
    }
}
