# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Added
- Overload and failure tests over real connections (hokusai#126): with one slot and no queue a
  second request gets a `503` JSON error naming the queue, the busy request is not disturbed and the
  server serves again once the slot is free; a pipeline that fails after output began ends the body
  without the terminating chunk, so the client can tell the image is incomplete, and frees its slot.
  They run in a process of their own (`HOKUSAI_OVERLOAD_TESTS=1 swift test --filter OverloadTests`).
- Tests over real HTTP connections: a client that reads slowly receives every byte,
  a client that disconnects part-way leaves no evaluation holding a slot, and the
  server keeps serving after dropped connections (hokusai#126).

## [2.0.0] - 2026-11-03

First release. It is versioned with Hokusai: this package and Hokusai share the major and minor version.

### Added
- `Hokusai.response(status:headers:chunkSize:allocator:)`: a streamed image or PDF response for a Hokusai 2 pipeline, written through `writeByteBuffers` with backpressure. `Content-Type` comes from the encoder the pipeline carries, and the source header is read before the response is committed, so an unreadable image is a `4xx` instead of a broken `200`.
- `Request.hokusaiImage(options:maximumSize:)`: reads a raw upload into a pipeline, never past `maximumSize` (`413` over the limit, `400` when empty), with Hokusai's own `InputOptions`.
- `HokusaiError.httpStatus` and `.httpError`, and `HokusaiErrorMiddleware`, to map Hokusai errors to HTTP statuses by case.
- CI on Linux (Swift 6.4, Hummingbird release and main) and macOS.

### Requirements
- Hokusai 2.0.0, Hummingbird 2.x, libvips 8.16+ and Cairo with PDF support.
