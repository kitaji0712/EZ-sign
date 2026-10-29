import CoreNFC
import SwiftUI
import UIKit

/// 書き込み 1 回分の流れ。Core NFC のセッションを開き、EZ Sign が見つかったら
/// テスト画面を送り、描画が終わるまで POLL する。途中経過はすべて log に残す。
///
/// iPhone ではタグとの接続が約 20 秒で切れるという報告があり、描画（約 24 秒）の途中で
/// 切れるかもしれない。切れたら同じセッションのままつなぎ直して完了を待つ。
@MainActor
final class WriteController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForTag
        case checkingPlacement
        case authenticating
        case sending(sent: Int, total: Int)
        case refreshing(seconds: Int)
        case reconnecting
        case done(seconds: Double)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var preview: Frame
    @Published var layout: PixelLayout = PanelModel.inch4_2.layout {
        didSet { preview = makePattern() }
    }
    @Published var reconnectOnLoss = true

    private let delegate = SessionDelegate()
    private var session: NFCTagReaderSession?
    private var runNumber = 0
    private var sessionStart = ContinuousClock.now
    private var connectedAt: ContinuousClock.Instant?
    /// タグが見つかるのを待っている処理
    private var tagWaiter: CheckedContinuation<NFCTag, Error>?
    /// 誰も待っていないときに見つかったタグ
    private var detectedTag: NFCTag?

    init() {
        preview = TestPattern.make(stamp: "#- ----------", layout: PanelModel.inch4_2.layout)
        delegate.controller = self
    }

    func start() {
        guard !phase.isRunning else { return }
        guard NFCTagReaderSession.readingAvailable else {
            phase = .failed("この端末では NFC の読み書きが使えません")
            return
        }
        runNumber += 1
        let frame = makePattern()
        preview = frame
        log = []
        sessionStart = .now
        connectedAt = nil
        detectedTag = nil
        append("書き込み #\(runNumber) / iOS \(UIDevice.current.systemVersion) / \(deviceModel())"
               + " / 画素の並び \(layout.rawValue) / つなぎ直し \(reconnectOnLoss ? "する" : "しない")")

        guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: delegate) else {
            phase = .failed("NFC セッションを作れませんでした")
            return
        }
        session.alertMessage = "iPhone の上部を EZ Sign の NFC の位置に当ててください"
        self.session = session
        phase = .waitingForTag
        session.begin()

        let bytes = frame.encoded(layout: layout)
        Task { await run(bytes) }
    }

    func copyLog() {
        UIPasteboard.general.string = log.joined(separator: "\n")
    }

    // MARK: - 書き込みの流れ

    private func run(_ bytes: [UInt8]) async {
        do {
            let seconds = try await write(bytes)
            phase = .done(seconds: seconds)
            append("完了（セッション開始から \(elapsedText())）")
            session?.alertMessage = "書き込みが終わりました"
            try? await Task.sleep(for: .seconds(1))
            session?.invalidate()
        } catch {
            let message = describe(error)
            append("失敗: \(message)")
            if phase.isRunning { phase = .failed(message) }
            session?.invalidate(errorMessage: message)
        }
    }

    /// 送信から描画完了まで。REFRESH から描画完了までの秒数を返す。
    private func write(_ bytes: [UInt8]) async throws -> Double {
        let (proto, refreshStart) = try await transfer(bytes)
        return try await waitUntilDrawn(proto, refreshStart: refreshStart)
    }

    /// 位置を確認してから、認証して画像を送り、REFRESH まで。
    /// 位置確認が通らなければ書き込まずに当て直してもらう。送信中に切れたら最初からやり直す（2 回まで）。
    private func transfer(_ bytes: [UInt8]) async throws -> (EZSignProtocol, ContinuousClock.Instant) {
        var attempt = 1
        while true {
            let proto = makeProtocol(try await waitForTag())
            phase = .checkingPlacement
            session?.alertMessage = "位置を確認しています。そのまま動かさないでください"
            do {
                try await proto.checkPlacement()
            } catch let error as WriteFailure {
                throw error
            } catch {
                append("位置確認で失敗: \(describe(error))。書き込まずに当て直してもらいます")
                phase = .waitingForTag
                session?.alertMessage = "うまく通信できませんでした。当てる位置を合わせて、もう一度かざしてください"
                session?.restartPolling()
                continue
            }
            session?.alertMessage = "位置 OK。書き込みを始めます。動かさないでください"
            do {
                phase = .authenticating
                let info = try await proto.begin()
                if let model = info.identify() {
                    append("機種: \(model.name)")
                    guard model == .inch4_2 else { throw WriteFailure.unsupportedModel(model.name) }
                } else {
                    append("機種を判別できませんでした。4.2 インチとして続けます")
                }
                try await proto.sendFrame(bytes, progress: { [weak self] sent, total in
                    self?.phase = .sending(sent: sent, total: total)
                    self?.session?.alertMessage = "送信中 \(sent) / \(total)"
                })
                let refreshStart = ContinuousClock.now
                try await proto.startRefresh()
                return (proto, refreshStart)
            } catch where reconnectOnLoss && isTagLost(error) && attempt < 3 {
                attempt += 1
                append("送信中に接続が切れました（\(connectionAgeText())）。最初からやり直します")
                phase = .waitingForTag
                session?.alertMessage = "接続が切れました。もう一度かざしてください"
                session?.restartPolling()
            }
        }
    }

    /// 描画が終わるまで POLL する。切れたらつなぎ直して続きを待つ。
    private func waitUntilDrawn(_ first: EZSignProtocol, refreshStart: ContinuousClock.Instant) async throws -> Double {
        var proto = first
        phase = .refreshing(seconds: 0)
        session?.alertMessage = "描画中です。動かさないでください"
        while true {
            do {
                let elapsed = try await proto.waitForRefresh(startedAt: refreshStart, progress: { [weak self] elapsed in
                    self?.showRefreshing(elapsed)
                })
                return elapsed.seconds
            } catch where reconnectOnLoss && isTagLost(error) {
                append("描画中に接続が切れました（REFRESH から \(formatSeconds(ContinuousClock.now - refreshStart)) 秒、"
                       + "\(connectionAgeText())）。つなぎ直します")
                phase = .reconnecting
                session?.alertMessage = "そのまま動かさないでください"
                session?.restartPolling()
                proto = makeProtocol(try await waitForTag())
                try await proto.resumeAfterReconnect()
            }
        }
    }

    private func showRefreshing(_ elapsed: Duration) {
        let seconds = Int(elapsed.seconds)
        guard phase != .refreshing(seconds: seconds) else { return }
        phase = .refreshing(seconds: seconds)
        session?.alertMessage = "描画中 \(seconds) 秒。動かさないでください"
    }

    private func makeProtocol(_ transport: APDUTransport) -> EZSignProtocol {
        EZSignProtocol(transport: transport, log: { [weak self] line in self?.append(line) })
    }

    // MARK: - タグの検出と接続

    private func waitForTag() async throws -> APDUTransport {
        while true {
            // セッションが終わっていたら、タグはもう来ない
            guard session != nil else { throw WriteFailure.sessionClosed }
            let tag: NFCTag
            if let pending = detectedTag {
                detectedTag = nil
                tag = pending
            } else {
                tag = try await withCheckedThrowingContinuation { tagWaiter = $0 }
            }
            do {
                return try await connect(tag)
            } catch let error as WriteFailure {
                throw error
            } catch {
                append("タグにつながりませんでした: \(describe(error))。もう一度探します")
                session?.restartPolling()
            }
        }
    }

    private func connect(_ tag: NFCTag) async throws -> APDUTransport {
        guard let session else { throw WriteFailure.sessionClosed }
        let transport: APDUTransport
        switch tag {
        case let .iso7816(iso):
            append("タグ検出: ISO 7816 / ID \(hexString(iso.identifier)) / AID \(iso.initialSelectedAID)"
                   + " / historical \(iso.historicalBytes.map { hexString($0) } ?? "なし")")
            transport = ISO7816Transport(tag: iso)
        case let .miFare(mifare):
            append("タグ検出: MIFARE（family \(mifare.mifareFamily.rawValue)）/ ID \(hexString(mifare.identifier))"
                   + " / historical \(mifare.historicalBytes.map { hexString($0) } ?? "なし")")
            transport = MiFareTransport(tag: mifare)
        default:
            append("タグ検出: 対応していない種類のタグ")
            throw WriteFailure.unsupportedTag
        }
        try await session.connect(to: tag)
        connectedAt = .now
        append("接続しました（セッション開始から \(elapsedText())）")
        return transport
    }

    // MARK: - SessionDelegate から呼ばれる

    func sessionDidBecomeActive(_ session: NFCTagReaderSession) {
        guard session === self.session else { return }
        append("NFC の読み取りを開始しました")
    }

    func session(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard session === self.session else { return }
        guard tags.count == 1, let tag = tags.first else {
            append("タグが \(tags.count) 個見つかりました")
            session.alertMessage = "EZ Sign だけをかざしてください"
            session.restartPolling()
            return
        }
        if let waiter = tagWaiter {
            tagWaiter = nil
            waiter.resume(returning: tag)
        } else {
            detectedTag = tag
        }
    }

    func session(_ session: NFCTagReaderSession, didInvalidateWith error: Error) {
        guard session === self.session else { return }
        self.session = nil
        detectedTag = nil
        append("NFC セッション終了: \(describe(error))（開始から \(elapsedText())）")
        if let waiter = tagWaiter {
            tagWaiter = nil
            waiter.resume(throwing: error)
        }
        if phase.isRunning { phase = .failed(describe(error)) }
    }

    // MARK: - 補助

    /// つなぎ直せば続けられそうな通信エラーか。
    private func isTagLost(_ error: Error) -> Bool {
        let nsError = error as NSError
        // 100 接続が切れた / 101 再送の上限 / 102 タグの応答エラー / 104 つながっていない
        return nsError.domain == NFCErrorDomain && [100, 101, 102, 104].contains(nsError.code)
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? EZSignError { return error.description }
        if let error = error as? WriteFailure { return error.description }
        let nsError = error as NSError
        return "\(nsError.localizedDescription)（\(nsError.domain) \(nsError.code)）"
    }

    private func append(_ line: String) {
        log.append("+\(elapsedText())s \(line)")
    }

    private func elapsedText() -> String {
        formatSeconds(ContinuousClock.now - sessionStart)
    }

    private func connectionAgeText() -> String {
        guard let connectedAt else { return "未接続" }
        return "接続から \(formatSeconds(ContinuousClock.now - connectedAt)) 秒"
    }

    private func makePattern() -> Frame {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = runNumber == 0 ? "#- ----------" : "#\(runNumber) \(formatter.string(from: Date()))"
        return TestPattern.make(stamp: stamp, layout: layout)
    }

    private func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

extension WriteController.Phase {
    var title: String {
        switch self {
        case .idle: return "待機中"
        case .waitingForTag: return "EZ Sign にかざしてください"
        case .checkingPlacement: return "位置を確認中（動かさないでください）"
        case .authenticating: return "認証中"
        case let .sending(sent, total): return "送信中 \(sent) / \(total)"
        case let .refreshing(seconds): return "描画中 \(seconds) 秒（動かさないでください）"
        case .reconnecting: return "つなぎ直しています（動かさないでください）"
        case let .done(seconds): return "完了（描画 \(formatSeconds(seconds)) 秒）"
        case let .failed(message): return "失敗: \(message)"
        }
    }
}
