import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func centeredSquare(for image: CGImage) -> CGRect {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let side = min(w, h)
        return CGRect(x: (w - side) / 2, y: (h - side) / 2, width: side, height: side)
    }

    /// Crops (top-left origin, pixels) and scales down to at most `maxSide`.
    static func render(_ image: CGImage, crop: CGRect, maxSide: Int = 1400) -> CGImage? {
        guard let cropped = image.cropping(to: crop.integral) else { return nil }
        let side = min(maxSide, max(cropped.width, cropped.height))
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.92) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Saves a centered square crop of any image file as JPEG.
    static func writeSquare(from source: URL, to dest: URL) throws {
        guard let image = load(source), let out = render(image, crop: centeredSquare(for: image)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try writeJPEG(out, to: dest)
    }
}

/// Small in-memory cache so lists of thumbnails don't hit the disk on every redraw.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
