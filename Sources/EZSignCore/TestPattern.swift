/// 書き込み確認用のテスト画面（4.2 インチ 400×300 向けの配置）。
///
/// 見てほしいところ:
/// - 文字が左右反転・上下逆になっていないか（画素の並び順の確認）
/// - 4 色が正しく出ているか
/// - 1 ピクセルの市松模様や細線がつぶれていないか
/// - 下の時刻と番号が今回のものか（書き換わったかの確認）
enum TestPattern {
    static func make(stamp: String, layout: PixelLayout, model: PanelModel = .inch4_2) -> Frame {
        var frame = Frame(model: model)

        // 見出し（黒帯に白抜き）と、左上の向き確認用の赤い四角
        frame.fill(x: 0, y: 0, width: model.width, height: 44, color: .black)
        let title = "EZ SIGN WRITE TEST"
        frame.drawText(title, x: (model.width - BitmapFont.width(of: title, scale: 3)) / 2, y: 12, scale: 3, color: .white)
        frame.fill(x: 0, y: 0, width: 10, height: 10, color: .red)

        // 4 色の見本
        let swatches: [(PaletteColor, String)] = [(.black, "BLACK"), (.white, "WHITE"), (.yellow, "YELLOW"), (.red, "RED")]
        for (index, (color, label)) in swatches.enumerated() {
            let x = 12 + index * 96
            frame.fill(x: x, y: 56, width: 88, height: 72, color: color)
            frame.strokeRect(x: x, y: 56, width: 88, height: 72, color: .black, lineWidth: 2)
            frame.drawText(label, x: x + (88 - BitmapFont.width(of: label, scale: 2)) / 2, y: 136, scale: 2, color: .black)
        }

        // 細かい模様: 1px 市松 / 2px 市松 / 赤黄 1px 市松 / 1px 横線
        frame.checkerboard(x: 12, y: 160, width: 88, height: 40, cell: 1, .black, .white)
        frame.checkerboard(x: 108, y: 160, width: 88, height: 40, cell: 2, .black, .white)
        frame.checkerboard(x: 204, y: 160, width: 88, height: 40, cell: 1, .red, .yellow)
        for row in stride(from: 160, to: 200, by: 2) {
            frame.fill(x: 300, y: row, width: 88, height: 1, color: .black)
        }

        // 設定と時刻
        frame.drawText("LAYOUT: \(layout.rawValue)", x: 12, y: 214, scale: 2, color: .black)
        frame.drawText(stamp, x: 12, y: 240, scale: 2, color: .red)

        // 下端の帯（右下は黄色、左下は黒）
        frame.fill(x: 0, y: model.height - 30, width: model.width, height: 30, color: .black)
        frame.fill(x: model.width - 60, y: model.height - 30, width: 60, height: 30, color: .yellow)
        frame.drawText("<- LEFT", x: 8, y: model.height - 22, scale: 2, color: .white)
        return frame
    }
}
