# Changelog

All notable changes to this project are documented in this file.

## [2.0.0] - 2026-11-03

First release. It is versioned with Hokusai: this package and Hokusai share the major and minor version.

### Added
- `Hokusai.response(status:headers:chunkSize:allocator:)`: a streamed image or PDF response for a Hokusai 2 pipeline, written through `writeByteBuffers` with backpressure. `Content-Type` comes from the encoder the pipeline carries, and the source header is read before the response is committed, so an unreadable image is a `4xx` instead of a broken `200`.
- `Request.hokusaiImage(options:maximumSize:)`: reads a raw upload into a pipeline, never past `maximumSize` (`413` over the limit, `400` when empty), with Hokusai's own `InputOptions`.
- `HokusaiError.httpStatus` and `.httpError`, and `HokusaiErrorMiddleware`, to map Hokusai errors to HTTP statuses by case.
- CI on Linux (Swift 6.4, Hummingbird release and main) and macOS.

### Requirements
- Hokusai 2.0.0, Hummingbird 2.x, libvips 8.16+ and Cairo with PDF support.
