import ImageIO
import SwiftUI
import UIKit

/// Decoded covers kept in memory, already shrunk to the size they are shown at: a page that
/// reappears shows them at once, and a small row never decodes a full-size image.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.totalCostLimit = 96 << 20
    }

    func cached(_ url: URL, pixels: Int) -> UIImage? {
        images.object(forKey: Self.key(url, pixels))
    }

    /// Loads (from disk, the URL cache or the network), shrinks and decodes off the main thread.
    func image(for url: URL, pixels: Int) async -> UIImage? {
        if let cached = cached(url, pixels: pixels) { return cached }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let image = Self.downsample(data, pixels: pixels) else { return nil }
        images.setObject(image, forKey: Self.key(url, pixels),
                         cost: Int(image.size.width * image.size.height) * 4)
        return image
    }

    private static func key(_ url: URL, _ pixels: Int) -> NSString {
        "\(pixels)|\(url.absoluteString)" as NSString
    }

    /// At most `pixels` on the longer side (never enlarged), decoded right away.
    private static func downsample(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                                                       [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// An image from `ImageCache`, shown at once when it is already in memory, with a placeholder
/// (and a short fade) while it loads.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    let pixels: Int
    @ViewBuilder let placeholder: Placeholder

    private struct Loaded {
        let url: URL
        let image: UIImage
    }

    @State private var loaded: Loaded?

    var body: some View {
        if let image = currentImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            placeholder
                .task(id: url) { await load() }
        }
    }

    private var currentImage: UIImage? {
        guard let url else { return nil }
        if let cached = ImageCache.shared.cached(url, pixels: pixels) { return cached }
        return loaded?.url == url ? loaded?.image : nil
    }

    private func load() async {
        guard let url, let image = await ImageCache.shared.image(for: url, pixels: pixels),
              !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) { loaded = Loaded(url: url, image: image) }
    }
}
