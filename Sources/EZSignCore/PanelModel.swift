/// フレームバッファ内の画素の並び順。パネルの大きさごとに違う。
enum PixelLayout: String, CaseIterable, Identifiable {
    /// 行優先（左上から右へ）
    case row = "row"
    /// 行優先で左右反転。4.2 インチはこれ（ezsign-nfc が実機で確認）
    case rowMirror = "row-mirror"
    /// 列優先（左上から下へ）。2.9 インチはこれ
    case col = "col"
    /// 列優先で左右反転。2.13 インチはこれ
    case colMirror = "col-mirror"

    var id: String { rawValue }

    /// 画像上の (x, y) の画素が入るビット位置（1 画素 2 ビット）。
    func bitPosition(x: Int, y: Int, width: Int, height: Int) -> Int {
        switch self {
        case .row: return (y * width + x) * 2
        case .rowMirror: return (y * width + (width - 1 - x)) * 2
        case .col: return (x * height + y) * 2
        case .colMirror: return ((width - 1 - x) * height + y) * 2
        }
    }
}

/// EZ Sign の機種。解像度と画素の並び順を持つ。
struct PanelModel: Equatable {
    let name: String
    let width: Int
    let height: Int
    let layout: PixelLayout

    /// 1 画面分のフレームバッファの大きさ（バイト）。
    var frameByteCount: Int { width * height * 2 / 8 }

    static let inch4_2 = PanelModel(name: "4.2\"", width: 400, height: 300, layout: .rowMirror)
    static let inch2_9 = PanelModel(name: "2.9\"", width: 296, height: 128, layout: .col)
    static let inch2_13 = PanelModel(name: "2.13\"", width: 250, height: 128, layout: .colMirror)

    static let all: [PanelModel] = [inch4_2, inch2_9, inch2_13]
}
