<p align="center">
<img src="./hokusai-hummingbird-logo-v1.png" alt="Hokusai for Hummingbird" width="500">
</p>

# Hokusai Hummingbird

[Hummingbird 2](https://github.com/hummingbird-project/hummingbird) integration for [Hokusai 2](https://github.com/ivantokar/hokusai). Read a raw image upload into an immutable pipeline, transform it, and stream the encoded image or PDF back with Hummingbird's backpressure.

**Documentation: <https://ivantokar.com/oss/hokusai/integrations/hummingbird/>** · [all Hokusai documentation](https://ivantokar.com/oss/hokusai/) · [Українською](https://ivantokar.com/oss/hokusai/uk/integrations/hummingbird/)

This package is a thin layer. Streaming, cancellation and limits are Hokusai's own (`writeByteBuffers` in `HokusaiNIO`, built on the core `writeChunks`); nothing here is a second native bridge, and no Hummingbird type reaches Hokusai.

## Requirements

- Swift 6.0+ (CI runs Swift 6.4), Hummingbird 2.x, Hokusai 2.
- libvips 8.16+ and Cairo with PDF support.

```bash
# macOS
brew install vips cairo pkg-config

# Ubuntu/Debian (libvips must be 8.16 or newer; build it if your distribution is older)
sudo apt install libvips-dev libcairo2-dev pkg-config
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/ivantokar/hokusai-hummingbird.git", from: "2.0.0")
]
```

Add `HokusaiHummingbird` to the target that defines your routes.

## Configure at startup

```swift
import Hokusai

try Hokusai.configure(.init(maxConcurrentEvaluations: .fixed(4), maxQueuedEvaluations: 64))
try Hokusai.initialize()
```

Configuration freezes at first use, so do it before the first request. Hokusai initializes lazily otherwise; calling `initialize()` surfaces native-runtime failures at startup.

## Upload, transform, respond

```swift
import HokusaiHummingbird
import Hummingbird

let router = Router()
router.add(middleware: HokusaiErrorMiddleware())

router.post("resize") { request, _ -> Response in
    let image = try await request.hokusaiImage()                 // 413 above 20 MiB
    return try await image
        .resize(width: 800, height: 600, fit: .cover)
        .webp(quality: 82)                                       // choose the encoder on the pipeline
        .response()                                              // Content-Type: image/webp
}
```

```bash
curl -X POST http://localhost:8080/resize --data-binary "@photo.jpg" -o output.webp
```

### Upload limits

`hokusaiImage` reads the body as it arrives, never past its limit: a declared `Content-Length` over `maximumSize` is rejected before a byte is read, and a body without one is rejected as soon as it grows past the limit (`413 Content Too Large`). An empty body is `400`.

```swift
let image = try await request.hokusaiImage(
    options: InputOptions(limits: InputLimits(maxPixels: 50_000_000)),   // Hokusai's own decode limits
    maximumSize: 5 * 1024 * 1024)
```

A small upload stays in memory. One larger than `memoryLimit` (1 MiB by default) moves to a private temporary file (`Hokusai(spooling:)`), so the encoded upload takes at most `memoryLimit` plus one chunk of memory however large `maximumSize` is. The pipeline owns the file and removes it when the last copy of the pipeline is released; a process that dies first leaves `hokusai-upload-*` files in `spoolDirectory` (the system temporary directory by default), which a server can sweep at start.

```swift
let image = try await request.hokusaiImage(
    maximumSize: 200 * 1024 * 1024,   // raised: the body is spooled, not held
    memoryLimit: 1 << 20)
```

This bounds the memory of the encoded upload; decoding is bounded separately by `InputLimits.maxPixels`.

### Streamed responses

`response()` writes through `Hokusai.writeByteBuffers`, so each buffer is handed to Hummingbird's `ResponseBodyWriter` as it is encoded and a slow client slows encoding down. At most four 64 KiB buffers of encoded output are held, whatever the image size. When the client disconnects Hummingbird cancels the request task and the evaluation stops. PDF takes the same path.

```swift
try await image.png(compressionLevel: 6).response()
try await image.pdf().response(status: .created, headers: [.cacheControl: "no-store"])
try await image.avif(quality: 50).response(chunkSize: 128 * 1024)
```

- The body is chunked; there is no `Content-Length`, because the size is unknown until encoding ends.
- `Content-Type` comes from the encoder the pipeline carries. A pipeline without one is a `500`.
- Before the response is committed the source header is read, so a missing or unreadable image is a `4xx` rather than a broken `200`. A failure after the first byte can only end the stream early, which is how HTTP works once headers are sent.
- TIFF is encoded in memory first, then streamed.

### Errors

`HokusaiErrorMiddleware` turns a `HokusaiError` thrown by a route into an HTTP error; `hokusaiImage` and `response` already do this for what they run. Add the middleware for routes that evaluate a pipeline themselves with `data()` or `write(to:)`.

| `HokusaiError` | Status |
| --- | --- |
| `invalidInput`, `invalidOption` | 400 |
| `decode` | 422 |
| `resource` (bytes) | 413 |
| `resource` (pixels, channels) | 422 |
| `resource` (evaluation queue full) | 503 |
| `unsupported` | 501 |
| `io`, `transform`, `encode`, `runtime` | 500 |

`error.httpStatus` and `error.httpError` are public if you want a different policy.

## Example: image report PDF

```swift
router.post("report") { request, _ -> Response in
    let image = try await request.hokusaiImage()
    let report = try image
        .resize(width: 1240, height: 1754, fit: .contain)
        .pdf(pageSize: .a4(), margins: .all(36), background: .white)
    return try await report.response()
}
```

The PDF is a Cairo-backed document containing the evaluated raster page; selectable vector text is tracked in [Hokusai issue #13](https://github.com/ivantokar/hokusai/issues/13).

## Related projects

- [Documentation](https://ivantokar.com/oss/hokusai/)
- [Examples](https://github.com/ivantokar/hokusai-examples): a web playground on Vapor and Hummingbird, and a macOS playground
- [Hokusai](https://github.com/ivantokar/hokusai)
- [Hokusai Vapor](https://github.com/ivantokar/hokusai-vapor)
