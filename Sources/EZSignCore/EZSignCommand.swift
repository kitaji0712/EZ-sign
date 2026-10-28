/// EZ Sign に送る APDU。手順と出典は docs/PROTOCOL.md。
enum EZSignCommand {
    /// DATA 1 回で送るバイト数。
    static let chunkSize = 250

    /// SELECT: NFC Forum Type 4 の NDEF アプリ（AID D2760000850101）を選ぶ
    static let select: [UInt8] = [0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01]
    /// VERIFY: 固定の 4 バイト鍵
    static let verify: [UInt8] = [0x00, 0x20, 0x00, 0x01, 0x04, 0x20, 0x09, 0x12, 0x10]
    /// INIT: 書き込み開始。応答に機種情報（TLV）が付く
    static let initWrite: [UInt8] = [0x00, 0xD1, 0x00, 0x00, 0x00]
    /// REFRESH: 受け取った画像の描画を始める
    static let refresh: [UInt8] = [0xF0, 0xD4, 0x85, 0x80, 0x00]
    /// POLL: 描画が終わったか。応答の 1 バイト目が 00 なら完了
    static let poll: [UInt8] = [0xF0, 0xDE, 0x00, 0x00, 0x01]

    /// DATA: F0 D2 <番号 上位> <番号 下位> <長さ> <データ>
    static func data(sequence: Int, chunk: ArraySlice<UInt8>) -> [UInt8] {
        precondition(!chunk.isEmpty && chunk.count <= chunkSize)
        precondition(sequence >= 0 && sequence <= 0xFFFF)
        return [0xF0, 0xD2, UInt8(sequence >> 8), UInt8(sequence & 0xFF), UInt8(chunk.count)] + chunk
    }

    /// フレームバッファを DATA コマンドの列にする。最後だけ短くてもよい（2.9 インチで確認済み）。
    static func dataCommands(for frame: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: frame.count, by: chunkSize).enumerated().map { sequence, start in
            data(sequence: sequence, chunk: frame[start..<min(start + chunkSize, frame.count)])
        }
    }
}

/// APDU の応答。データと状態語（SW1 SW2）。
struct APDUResponse: Equatable {
    var data: [UInt8]
    var sw1: UInt8
    var sw2: UInt8

    init(data: [UInt8] = [], sw1: UInt8, sw2: UInt8) {
        self.data = data
        self.sw1 = sw1
        self.sw2 = sw2
    }

    static let ok = APDUResponse(sw1: 0x90, sw2: 0x00)

    var isOK: Bool { sw1 == 0x90 && sw2 == 0x00 }
    var statusHex: String { hexString([sw1, sw2]) }
}

/// "90 00" のような 16 進表記。
func hexString<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    bytes.map { byte in
        let digits = String(byte, radix: 16, uppercase: true)
        return digits.count == 1 ? "0" + digits : digits
    }.joined(separator: " ")
}
