import CoreImage
import UIKit

struct LoadedArtwork {
    let image: UIImage
    /// A lively version of the cover's average colour, used to tint the player.
    let tint: UIColor?
    /// A tiny, already blurred copy for the player's background, so no blur is drawn live.
    let backdrop: UIImage?
}

/// Loads the full-size cover of the current track for the lock screen and the player background.
actor ArtworkLoader {
    static let shared = ArtworkLoader()

    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    func artwork(for track: Track) async -> LoadedArtwork? {
        var data: Data?
        if let local = Storage.localArtwork(for: track) {
            data = try? Data(contentsOf: local)
        } else if let remote = track.largeArtworkURL {
            data = try? await URLSession.shared.data(from: remote).0
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        return LoadedArtwork(image: image, tint: tint(of: image), backdrop: backdrop(of: image))
    }

    private func backdrop(of image: UIImage) -> UIImage? {
        guard let input = CIImage(image: image), input.extent.width > 0 else { return nil }
        let scale = 64 / max(input.extent.width, input.extent.height)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: small.extent)
        guard let cgImage = context.createCGImage(blurred, from: small.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func tint(of image: UIImage) -> UIColor? {
        guard let input = CIImage(image: image),
              let filter = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: input,
                  kCIInputExtentKey: CIVector(cgRect: input.extent),
              ]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let average = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                              blue: CGFloat(pixel[2]) / 255, alpha: 1)

        // Averages tend to be muddy: push saturation and keep brightness in a readable range.
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            return average
        }
        return UIColor(hue: hue, saturation: min(1, saturation * 1.3),
                       brightness: min(max(brightness, 0.35), 0.7), alpha: 1)
    }
}
