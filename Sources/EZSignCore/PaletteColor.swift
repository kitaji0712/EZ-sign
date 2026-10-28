/// EZ Sign（4 色モデル）が表示できる色。
/// rawValue はフレームバッファに書き込む 2 ビットの値（docs/PROTOCOL.md）。
enum PaletteColor: UInt8, CaseIterable {
    case black = 0
    case white = 1
    case yellow = 2
    case red = 3

    /// 画面プレビュー用の RGB。
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .black: return (0, 0, 0)
        case .white: return (255, 255, 255)
        case .yellow: return (255, 255, 0)
        case .red: return (255, 0, 0)
        }
    }

    /// RGB に一番近いパレット色。ディザリングはしない。
    /// 同じ距離なら allCases の先の色を選ぶ（ezsign-nfc の _nearest と同じ）。
    static func nearest(r: UInt8, g: UInt8, b: UInt8) -> PaletteColor {
        var best = PaletteColor.white
        var bestDistance = Int.max
        for color in allCases {
            let c = color.rgb
            let dr = Int(r) - Int(c.r)
            let dg = Int(g) - Int(c.g)
            let db = Int(b) - Int(c.b)
            let distance = dr * dr + dg * dg + db * db
            if distance < bestDistance {
                best = color
                bestDistance = distance
            }
        }
        return best
    }
}
