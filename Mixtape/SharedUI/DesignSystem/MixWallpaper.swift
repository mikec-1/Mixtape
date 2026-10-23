// A picture of the user's choosing behind the whole app, in place of the colour.
// Kept on this device only: unlike the colour, it's too big to ride along with the account.

import SwiftUI
import ImageIO
import CoreImage
import UniformTypeIdentifiers

nonisolated enum MixWallpaper {

    /// The picture for pages, and a small blurred copy for the glass panels over it.
    struct Picture {
        let full: CGImage
        let frosted: CGImage
    }

    enum Failure: Error { case unreadable }

    static var url: URL {
        URL.applicationSupportDirectory.appending(path: "Mixtape/Wallpaper.jpg")
    }

    /// Downscales a picked image and keeps it as the wallpaper.
    @concurrent static func save(_ data: Data) async throws -> Picture {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let picture = picture(from: source) else { throw Failure.unreadable }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.unreadable }
        CGImageDestinationAddImage(file, picture.full,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(file) else { throw Failure.unreadable }
        return picture
    }

    @concurrent static func load() async -> Picture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return picture(from: source)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func picture(from source: CGImageSource) -> Picture? {
        guard let full = thumbnail(source, longEdge: 2560),
              let small = thumbnail(source, longEdge: 256),
              let frosted = frost(small) else { return nil }
        return Picture(full: full, frosted: frosted)
    }

    private static func thumbnail(_ source: CGImageSource, longEdge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge,
        ] as CFDictionary)
    }

    /// Blurred once, on the CPU, so the glass costs nothing to draw and needs no GPU effect.
    private static func frost(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let output = input.clampedToExtent()
            .applyingGaussianBlur(sigma: 8)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .cropped(to: input.extent)
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: input.extent)
    }
}

nonisolated extension CGImage {
    /// The middle of the picture at `size`'s shape, as aspect fill shows it. Shares the pixels.
    func filling(_ size: CGSize) -> CGImage {
        let w = CGFloat(width), h = CGFloat(height)
        let scale = max(size.width / w, size.height / h)
        let crop = CGSize(width: size.width / scale, height: size.height / scale)
        return cropping(to: CGRect(x: (w - crop.width) / 2, y: (h - crop.height) / 2,
                                   width: crop.width, height: crop.height).integral) ?? self
    }
}
