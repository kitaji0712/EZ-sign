/// パネル 1 画面分の画像。画素はパレット色で持つので、パネルに出せない色は入らない。
struct Frame: Equatable {
    let width: Int
    let height: Int
    private(set) var pixels: [PaletteColor]

    init(width: Int, height: Int, fill: PaletteColor = .white) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    init(model: PanelModel, fill: PaletteColor = .white) {
        self.init(width: model.width, height: model.height, fill: fill)
    }

    /// RGBA（1 画素 4 バイト、行優先）から作る。各画素は一番近いパレット色にする。
    init(rgba: [UInt8], width: Int, height: Int) {
        precondition(rgba.count == width * height * 4, "RGBA の大きさが合いません")
        self.init(width: width, height: height)
        for i in 0..<(width * height) {
            pixels[i] = PaletteColor.nearest(r: rgba[i * 4], g: rgba[i * 4 + 1], b: rgba[i * 4 + 2])
        }
    }

    /// フレームバッファから戻す（encoded(layout:) の逆）。
    init(decoding bytes: [UInt8], width: Int, height: Int, layout: PixelLayout) {
        precondition(bytes.count == width * height * 2 / 8, "フレームバッファの大きさが合いません")
        self.init(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let bit = layout.bitPosition(x: x, y: y, width: width, height: height)
                let value = (bytes[bit >> 3] >> UInt8(6 - (bit & 7))) & 0b11
                pixels[y * width + x] = PaletteColor(rawValue: value)!
            }
        }
    }

    subscript(x: Int, y: Int) -> PaletteColor {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    func contains(x: Int, y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height
    }

    /// パネルに送るフレームバッファ。1 画素 2 ビットで、バイトの上位ビットから詰める。
    func encoded(layout: PixelLayout) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 2 / 8)
        for y in 0..<height {
            for x in 0..<width {
                let bit = layout.bitPosition(x: x, y: y, width: width, height: height)
                bytes[bit >> 3] |= self[x, y].rawValue << UInt8(6 - (bit & 7))
            }
        }
        return bytes
    }

    /// プレビュー表示用の RGBA（1 画素 4 バイト、アルファは 255）。
    func rgba() -> [UInt8] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for color in pixels {
            let c = color.rgb
            bytes.append(contentsOf: [c.r, c.g, c.b, 255])
        }
        return bytes
    }
}
