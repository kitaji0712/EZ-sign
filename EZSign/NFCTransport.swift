import CoreNFC

/// ISO 7816 タグとして見つかった EZ Sign に APDU を送る（ふつうはこちら）。
struct ISO7816Transport: APDUTransport {
    let tag: any NFCISO7816Tag

    func send(_ apdu: [UInt8]) async throws -> APDUResponse {
        let (data, sw1, sw2) = try await tag.sendCommand(apdu: try makeAPDU(apdu))
        return APDUResponse(data: [UInt8](data), sw1: sw1, sw2: sw2)
    }
}

/// MIFARE として見つかった場合の通信路（ISO 14443-4 対応タグなら APDU を送れる）。
struct MiFareTransport: APDUTransport {
    let tag: any NFCMiFareTag

    func send(_ apdu: [UInt8]) async throws -> APDUResponse {
        let (data, sw1, sw2) = try await tag.sendMiFareISO7816Command(try makeAPDU(apdu))
        return APDUResponse(data: [UInt8](data), sw1: sw1, sw2: sw2)
    }
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

    var description: String {
        switch self {
        case .unsupportedTag: return "EZ Sign ではないタグです"
        case let .unsupportedModel(name): return "\(name) のパネルにはまだ対応していません（4.2 インチのみ）"
        case let .malformedAPDU(head): return "APDU を作れませんでした（\(head)…）"
        case .sessionClosed: return "NFC セッションが終了しています"
        case .tagNotFound: return "つなぎ直そうとしましたが、EZ Sign が見つかりませんでした"
        }
    }
}
