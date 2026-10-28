/// INIT の応答に入っている機種情報。タグ・長さ・値（TLV）の並び。
/// 4.2 インチで観測された例（ezsign-nfc）:
///   A0: F0 07 20 02 58 01 90（01 90 = 400 が幅）  C0: シリアル番号（ASCII）  C1: UID
struct DeviceInfo: Equatable {
    let records: [UInt8: [UInt8]]

    init(initReply data: [UInt8]) {
        var records: [UInt8: [UInt8]] = [:]
        var i = 0
        while i + 2 <= data.count {
            let tag = data[i]
            let length = Int(data[i + 1])
            let end = min(i + 2 + length, data.count)
            records[tag] = Array(data[(i + 2)..<end])
            i += 2 + length
        }
        self.records = records
    }

    init(records: [UInt8: [UInt8]]) {
        self.records = records
    }

    var serialNumber: String? {
        records[0xC0].map { String(decoding: $0, as: UTF8.self) }
    }

    /// A0 の中に、ちょうど 1 機種の幅（だめなら高さ）が 16 ビット値として入っていればその機種。
    /// 2.9 インチと 2.13 インチは高さ 128 が同じなので、幅を先に見る。
    func identify(among models: [PanelModel] = PanelModel.all) -> PanelModel? {
        let a0 = records[0xA0] ?? []
        guard a0.count >= 2 else { return nil }
        let words = Set((0..<(a0.count - 1)).map { Int(a0[$0]) << 8 | Int(a0[$0 + 1]) })
        for dimension in [\PanelModel.width, \PanelModel.height] {
            let hits = models.filter { words.contains($0[keyPath: dimension]) }
            if hits.count == 1 { return hits[0] }
        }
        return nil
    }

    /// ログ用の 1 行表記。
    var summary: String {
        records.keys.sorted().map { tag in
            let value = records[tag]!
            let shown = tag == 0xC0 ? (serialNumber ?? "") : hexString(value)
            return "\(hexString([tag]))=\(shown)"
        }.joined(separator: " / ")
    }
}
