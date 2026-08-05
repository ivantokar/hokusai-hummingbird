<p align="center">
<img src="./hokusai-hummingbird-logo-v1.png" alt="Hokusai for Hummingbird" width="500">
</p>

# Hokusai Hummingbird

[Hummingbird 2](https://github.com/hummingbird-project/hummingbird) integration for [Hokusai 1.0](https://github.com/ivantokar/hokusai). Decode a raw image upload into an immutable pipeline, transform it, then return an asynchronous image or PDF response.

## Requirements

- Swift 6.0+, Hummingbird 2, and Hokusai 1.0.
- libvips and Cairo with PDF support.

```bash
# macOS
brew install vips cairo pkg-config

# Ubuntu/Debian
sudo apt install libvips-dev libcairo2-dev pkg-config
```

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/ivantokar/hokusai-hummingbird.git", from: "1.0.0")
]
```

Add `HokusaiHummingbird` to the target that defines your routes.

## Configure at startup

```swift
import HokusaiHummingbird

try Hokusai.initialize()
```

Hokusai also initializes lazily when an image is loaded. Calling `initialize()` is recommended so native-runtime failures appear at startup. Do not call `Hokusai.shutdown()` in a normal server lifecycle.

## Raw image upload

Hummingbird 2 streams request bodies. `hokusaiImage()` consumes that stream once and enforces a 20 MiB limit by default.

```swift
import HokusaiHummingbird
import Hummingbird

let router = Router()
router.post("resize") { request, _ async throws -> Response in
    let image = try await request.hokusaiImage()
    let resized = try image.resize(width: 800, height: 600, fit: .cover)
    return try await resized.response(format: "jpeg", quality: 85)
}
```

```bash
curl -X POST http://localhost:8080/resize \
  --data-binary "@photo.jpg" \
  -o output.jpg
```

Pass a custom size limit when necessary:

```swift
let image = try await request.hokusaiImage(maximumSize: 5 * 1024 * 1024)
```

Missing or invalid image data returns `400 Bad Request`; oversized uploads return `413 Content Too Large`.

## Image and PDF responses

`response` evaluates Hokusai's pipeline asynchronously and sets the correct `Content-Type` header.

```swift
try await image.response(format: "jpeg", quality: 85)
try await image.response(format: "png", compression: 6)
try await image.response(format: "webp", quality: 82)
try await image.response(format: "avif", quality: 50)
try await image.response(format: "pdf")
```

The PDF response is a Cairo-backed PDF containing Hokusai's evaluated raster page. It is suited to image reports and layered compositions, but does not currently preserve selectable vector text. The planned vector-PDF API is tracked in [Hokusai issue #13](https://github.com/ivantokar/hokusai/issues/13).

## Example: image report PDF

```swift
router.post("report") { request, _ async throws -> Response in
    let image = try await request.hokusaiImage()
    let report = try image
        .resize(width: 1240, height: 1754, fit: .contain)
        .drawText(
            "Monthly report",
            x: 72,
            y: 96,
            options: TextOptions(font: "sans Bold", fontSize: 52, color: [20, 30, 50, 255])
        )
    return try await report.response(format: "pdf")
}
```

## Related projects

- [Hokusai](https://github.com/ivantokar/hokusai)
- [Hokusai Vapor](https://github.com/ivantokar/hokusai-vapor)
