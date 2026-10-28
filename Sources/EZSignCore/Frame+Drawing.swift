/// Frame に図形と文字を描く。はみ出した部分は捨てる。
/// アンチエイリアスはしない（パネルは灰色を出せないので、輪郭がにじむだけ）。
extension Frame {
    mutating func fill(x: Int, y: Int, width w: Int, height h: Int, color: PaletteColor) {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(x + w, width), y1 = min(y + h, height)
        guard x0 < x1, y0 < y1 else { return }
        for py in y0..<y1 {
            for px in x0..<x1 {
                self[px, py] = color
            }
        }
    }

    /// 長方形の枠線。線は内側に描く。
    mutating func strokeRect(x: Int, y: Int, width w: Int, height h: Int, color: PaletteColor, lineWidth: Int = 1) {
        fill(x: x, y: y, width: w, height: lineWidth, color: color)
        fill(x: x, y: y + h - lineWidth, width: w, height: lineWidth, color: color)
        fill(x: x, y: y, width: lineWidth, height: h, color: color)
        fill(x: x + w - lineWidth, y: y, width: lineWidth, height: h, color: color)
    }

    /// 市松模様。cell はマス目の一辺（ピクセル）。
    mutating func checkerboard(x: Int, y: Int, width w: Int, height h: Int, cell: Int,
                               _ first: PaletteColor, _ second: PaletteColor) {
        for py in max(y, 0)..<min(y + h, height) {
            for px in max(x, 0)..<min(x + w, width) {
                let even = ((px - x) / cell + (py - y) / cell) % 2 == 0
                self[px, py] = even ? first : second
            }
        }
    }

    /// 内蔵の 5×7 ドットフォントで文字を描く。英小文字は大文字で描く。
    /// 戻り値は描いた幅（ピクセル）。
    @discardableResult
    mutating func drawText(_ text: String, x: Int, y: Int, scale: Int = 1, color: PaletteColor) -> Int {
        var cursor = x
        for character in text.uppercased() {
            let rows = BitmapFont.glyph(for: character)
            for (row, line) in rows.enumerated() {
                for (column, dot) in line.enumerated() where dot == "#" {
                    fill(x: cursor + column * scale, y: y + row * scale, width: scale, height: scale, color: color)
                }
            }
            cursor += BitmapFont.advance * scale
        }
        return BitmapFont.width(of: text, scale: scale)
    }
}
