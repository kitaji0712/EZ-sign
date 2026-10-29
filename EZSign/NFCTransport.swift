import CoreNFC

/// ISO 7816 タグとして見つかった EZ Sign に APDU を送る（ふつうはこちら）。
struct ISO7816Transport: APDUTransport {
    let tag: any NFCISO7816Tag

    func send(_ apdu: [UInt8]) async throws -> APDUResponse {
        let (data, sw1, sw2) = try await tag.sendCommand(apdu: try makeAPDU(apdu))
        return APDUResponse(data: [UInt8](data), sw1: sw1, sw2: sw2)
    }
}

/// MIFARE として見つかった EZ Sign に APDU を送る。
/// Info.plist に AID（D2760000850101）を書かないと、iOS は EZ Sign をこちらで渡す。
/// ISO 7816 として渡されたときの「接続から約 20 秒」の上限がこちらでもかかるかを確かめる（docs/PROTOCOL.md）。
///
/// 送り方は 2 通り。family が plus / desfire なら ISO 7816 の APDU として、それ以外はバイト列をそのまま送る。
/// 最初の 1 回が通信以外の理由で失敗したら、もう一方の送り方を試す。
final class MiFareTransport: APDUTransport {
    enum Mode: String {
        case iso7816 = "ISO 7816 の APDU として送る"
        case raw = "バイト列をそのまま送る"
    }

    let tag: any NFCMiFareTag
    private(set) var mode: Mode
    /// 最初に失敗して送り方を切り替えたときの理由（ログ用）
    private(set) var fallbackReason: String?
    /// 一度でも成功したら送り方を固定する
    private var confirmed = false

    init(tag: any NFCMiFareTag) {
        self.tag = tag
        mode = (tag.mifareFamily == .plus || tag.mifareFamily == .desfire) ? .iso7816 : .raw
    }

    func send(_ apdu: [UInt8]) async throws -> APDUResponse {
        do {
            let response = try await send(apdu, as: mode)
            confirmed = true
            return response
        } catch where !confirmed && !isConnectionError(error) {
            let nsError = error as NSError
            fallbackReason = "\(mode.rawValue)で失敗（\(nsError.localizedDescription) \(nsError.code)）"
            mode = mode == .iso7816 ? .raw : .iso7816
            let response = try await send(apdu, as: mode)
            confirmed = true
            return response
        }
    }

    private func send(_ apdu: [UInt8], as mode: Mode) async throws -> APDUResponse {
        switch mode {
        case .iso7816:
            let (data, sw1, sw2) = try await tag.sendMiFareISO7816Command(try makeAPDU(apdu))
            return APDUResponse(data: [UInt8](data), sw1: sw1, sw2: sw2)
        case .raw:
            // 応答は APDU の応答そのもの（データ + SW1 SW2）
            let raw = try await tag.sendMiFareCommand(commandPacket: Data(apdu))
            let response = [UInt8](raw)
            guard response.count >= 2 else { throw WriteFailure.shortResponse(hexString(response)) }
            return APDUResponse(data: Array(response.dropLast(2)),
                                sw1: response[response.count - 2], sw2: response[response.count - 1])
        }
    }
}

/// MIFARE の種別の表示名。
func familyName(_ family: NFCMiFareFamily) -> String {
    switch family {
    case .unknown: return "unknown（ISO 14443 Type A）"
    case .ultralight: return "Ultralight"
    case .plus: return "Plus"
    case .desfire: return "DESFire"
    @unknown default: return "その他（\(family.rawValue)）"
    }
}

/// 接続そのものの失敗（送り方を変えても直らない）か。
private func isConnectionError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NFCErrorDomain && (100...104).contains(nsError.code)
}

private func makeAPDU(_ bytes: [UInt8]) throws -> NFCISO7816APDU {
    guard let apdu = NFCISO7816APDU(data: Data(bytes)) else {
        throw WriteFailure.malformedAPDU(hexString(bytes.prefix(8)))
    }
    return apdu
}

/// Core NFC のデリゲート。受け取ったものを WriteController（メインアクター）に渡すだけ。
final class SessionDelegate: NSObject, NFCTagReaderSessionDelegate {
    weak var controller: WriteController?

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        let controller = self.controller
        Task { @MainActor in controller?.sessionDidBecomeActive(session) }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let controller = self.controller
        Task { @MainActor in controller?.session(session, didInvalidateWith: error) }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        let controller = self.controller
        Task { @MainActor in controller?.session(session, didDetect: tags) }
    }
}

enum WriteFailure: Error, CustomStringConvertible {
    case unsupportedTag
    case unsupportedModel(String)
    case malformedAPDU(String)
    case sessionClosed
    case tagNotFound
    case tooManySessionSwitches
    case shortResponse(String)

    var description: String {
        switch self {
        case .unsupportedTag: return "EZ Sign ではないタグです"
        case let .unsupportedModel(name): return "\(name) のパネルにはまだ対応していません（4.2 インチのみ）"
        case let .malformedAPDU(head): return "APDU を作れませんでした（\(head)…）"
        case .sessionClosed: return "NFC セッションが終了しています"
        case .tagNotFound: return "つなぎ直そうとしましたが、EZ Sign が見つかりませんでした"
        case .tooManySessionSwitches: return "NFC セッションの切り替えが多すぎます"
        case let .shortResponse(bytes): return "応答が短すぎます（\(bytes)）"
        }
    }
}
