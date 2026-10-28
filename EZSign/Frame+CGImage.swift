import CoreGraphics
import Foundation

extension Frame {
    /// プレビュー表示用の画像。
    func makeCGImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba()) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
