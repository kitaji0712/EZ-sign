import CoreNFC
import SwiftUI
import UIKit

/// 書き込み 1 回分の流れ。Core NFC のセッションを開き、EZ Sign が見つかったら
/// テスト画面を送り、描画が終わるまで POLL する。途中経過はすべて log に残す。
///
/// iPhone はタグとの接続を約 20 秒で打ち切る。描画には約 24 秒かかるので、1 つの接続では終わらない。
/// 実機の結果（docs/PROTOCOL.md）:
/// - 1 回目: 接続から 20.5 秒で POLL が NFCError 103。直後にこのアプリがセッションを閉じていた
/// - 2 回目: 17 秒で restartPolling したら、描画中のパネルは再検出されず、21.1 秒で NFCError 202
/// 公式アプリは読み取り画面を閉じずに約 30 秒で書き込める。そこで描画中の待ち方を 2 通り用意する。
enum RefreshStrategy: String, CaseIterable, Identifiable {
    /// 接続が切られる前に POLL をやめ、セッションは開いたまま（電波は出たまま）描画が終わるのを待つ。
    /// 終わったころにつなぎ直して完了を確かめる（公式アプリの動きからの推測）
    case quietWait = "静かに待つ"
    /// セッションの上限前に今のセッションを閉じ、新しいセッションで続きを待つ
    case switchSession = "セッション切り替え"

    var id: String { rawValue }
}

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

    /// 描画中のつなぎ直し方
    private enum Reconnect {
        /// 同じセッションで restartPolling する（通信の一時的な失敗）
        case sameSession
        /// 新しいセッションでパネルを見つけ直す（セッションの上限）
        case newSession
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var log: [String] = []
    @Published private(set) var preview: Frame
    @Published var layout: PixelLayout = PanelModel.inch4_2.layout {
        didSet { preview = makePattern() }
    }
    @Published var reconnectOnLoss = true
    @Published var refreshStrategy: RefreshStrategy = .quietWait

    /// 打ち切られると見込む時間（実測より少し短めに見積もる）
    private let limitFromBegin: Duration = .milliseconds(20_500)
    private let limitFromDetection: Duration = .milliseconds(19_500)
    /// 上限のこれだけ前に POLL をやめる（静かに待つ）／新しいセッションへ切り替える
    private let switchMargin: Duration = .milliseconds(1_500)
    /// 静かに待つとき、REFRESH からこの時間まで待ってから完了を確かめる（PC での実測 約 24 秒 + 余裕）
    private let expectedRefreshTime: Duration = .seconds(26)
    /// 位置確認から REFRESH まで（実測 約 6.6 秒）に余裕を足した時間。残りが足りなければ書き込む前に切り替える
    private let timeNeededForTransfer: Duration = .seconds(9)
    /// 1 回の書き込みでセッションを切り替える回数の上限
    private let maxSessionSwitches = 3
    /// 新しいセッションで EZ Sign が見つかるまで待つ上限（描画中のパネルは応答しないことがある）
    private let redetectTimeout: Duration = .seconds(30)
    /// 同じセッションでつなぎ直すとき、EZ Sign が見つかるまで待つ上限
    private let reconnectTimeout: Duration = .seconds(5)

    private let delegate = SessionDelegate()
    private var session: NFCTagReaderSession?
    private var runNumber = 0
    private var sessionStart = ContinuousClock.now
    /// 今のセッションを始めた時刻と、そのセッションで最初に EZ Sign を検出した時刻
    private var sessionBegunAt: ContinuousClock.Instant?
    private var firstDetectedAt: ContinuousClock.Instant?
    private var connectedAt: ContinuousClock.Instant?
    private var sessionSwitches = 0
    /// タグが見つかるのを待っている処理
    private var tagWaiter: CheckedContinuation<NFCTag, Error>?
    /// 待ち時間切れの判定で、どの待ちかを見分ける番号
    private var tagWaiterToken = 0
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
        sessionSwitches = 0
        append("書き込み #\(runNumber) / iOS \(UIDevice.current.systemVersion) / \(deviceModel())"
               + " / 画素の並び \(layout.rawValue) / 切れたらつなぎ直す \(reconnectOnLoss ? "はい" : "いいえ")"
               + " / 描画中の待ち方 \(refreshStrategy.rawValue)")

        guard beginSession(message: "EZ Sign にタッチしてください") else {
            phase = .failed("NFC セッションを作れませんでした")
            return
        }
        phase = .waitingForTag

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
            append("完了（開始から \(elapsedText())）")
            session?.alertMessage = "書き込みが終わりました"
            try? await Task.sleep(for: .seconds(1))
            session?.invalidate()
        } catch {
            let message = describe(error)
            append("失敗: \(message)")
            phase = .failed(message)
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
            if refreshStrategy == .switchSession, let remaining = remainingSessionTime(), remaining < timeNeededForTransfer {
                // 描画に入る前に打ち切られないよう、書き込む前に新しいセッションにする
                try switchSession(reason: "セッションの残りが \(formatSeconds(remaining)) 秒で、転送には足りない")
                continue
            }
            phase = .checkingPlacement
            session?.alertMessage = "認識しました。確認しています…"
            do {
                try await proto.checkPlacement()
            } catch let error as WriteFailure {
                throw error
            } catch {
                append("位置確認で失敗: \(describe(error))。書き込まずに当て直してもらいます")
                phase = .waitingForTag
                session?.alertMessage = "うまく通信できませんでした。当てる位置を少しずらして、もう一度タッチしてください"
                session?.restartPolling()
                continue
            }
            session?.alertMessage = "転送を開始します。動かさないでください"
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
                    self?.session?.alertMessage = "転送中です（\(sent * 100 / total)%）。動かさないでください"
                })
                let refreshStart = ContinuousClock.now
                try await proto.startRefresh()
                return (proto, refreshStart)
            } catch where reconnectOnLoss && isTagLost(error) && attempt < 3 {
                attempt += 1
                append("送信中に接続が切れました（\(connectionAgeText())）。最初からやり直します")
                phase = .waitingForTag
                session?.alertMessage = "接続が切れました。もう一度タッチしてください"
                session?.restartPolling()
            }
        }
    }

    /// 描画が終わるまで待つ。待ち方は refreshStrategy で選ぶ。
    /// - 静かに待つ: 接続が切られる前に POLL をやめ、セッションは開いたまま REFRESH から
    ///   expectedRefreshTime まで待つ。そのあと POLL し、接続が切れていれば同じセッションでつなぎ直す
    /// - セッション切り替え: 上限の前に新しいセッションへ切り替えて、続きを POLL する
    private func waitUntilDrawn(_ first: EZSignProtocol, refreshStart: ContinuousClock.Instant) async throws -> Double {
        var proto = first
        var reconnect: Reconnect?
        var waitedQuietly = false
        phase = .refreshing(seconds: 0)
        session?.alertMessage = "描画中です。動かさないでください"
        while true {
            do {
                if let how = reconnect {
                    proto = try await reconnectDuringRefresh(how, refreshStart: refreshStart)
                    reconnect = nil
                }
                let result = try await proto.waitForRefresh(
                    startedAt: refreshStart,
                    pauseWhen: { [weak self] in !waitedQuietly && (self?.isNearSessionLimit() ?? false) },
                    progress: { [weak self] elapsed in self?.showRefreshing(elapsed) })
                switch result {
                case let .done(elapsed):
                    return elapsed.seconds
                case .paused:
                    switch refreshStrategy {
                    case .quietWait:
                        try await waitQuietly(refreshStart: refreshStart)
                        waitedQuietly = true
                        // このまま同じ接続で POLL する。切られていれば下の catch でつなぎ直す
                    case .switchSession:
                        try switchSession(reason: "セッションの上限が近い（REFRESH から "
                                          + "\(formatSeconds(ContinuousClock.now - refreshStart)) 秒）")
                        reconnect = .newSession
                    }
                }
            } catch where reconnectOnLoss && (isTagLost(error) || (refreshStrategy == .quietWait && isConnectionInvalidated(error))) {
                append("描画中に接続が切れました: \(describe(error))（REFRESH から "
                       + "\(formatSeconds(ContinuousClock.now - refreshStart)) 秒、\(connectionAgeText())）。同じセッションでつなぎ直します")
                reconnect = .sameSession
            } catch where refreshStrategy == .switchSession && isSessionEnding(error) && isNearSessionLimit(margin: .seconds(3)) {
                // 見込みより早く打ち切られた場合。利用者のキャンセルと区別するため、上限の近くだけ
                try switchSession(reason: "描画中にセッションが終わった（\(describe(error))）")
                reconnect = .newSession
            }
        }
    }

    /// POLL を止め、セッションには触らずに（電波は出たままのはず）描画が終わる見込みの時刻まで待つ。
    private func waitQuietly(refreshStart: ContinuousClock.Instant) async throws {
        let until = refreshStart + expectedRefreshTime
        append("POLL をやめて、REFRESH から \(formatSeconds(expectedRefreshTime)) 秒まで静かに待ちます"
               + "（\(connectionAgeText())、このセッションの開始から \(sessionAgeText())）")
        while ContinuousClock.now < until {
            // 待っている間にセッションが終わったら（didInvalidate で記録される）、続けられない
            guard session != nil else { throw WriteFailure.sessionClosed }
            showRefreshing(ContinuousClock.now - refreshStart)
            try await Task.sleep(for: .milliseconds(500))
        }
        guard session != nil else { throw WriteFailure.sessionClosed }
        append("待ち終わり。完了を確かめます（\(connectionAgeText())、このセッションの開始から \(sessionAgeText())）")
    }

    /// 描画中につなぎ直し、POLL を続けられる状態にする。
    private func reconnectDuringRefresh(_ how: Reconnect, refreshStart: ContinuousClock.Instant) async throws -> EZSignProtocol {
        phase = .reconnecting
        let start = ContinuousClock.now
        let timeout: Duration
        switch how {
        case .sameSession:
            session?.alertMessage = "そのまま動かさないでください"
            session?.restartPolling()
            timeout = reconnectTimeout
        case .newSession:
            timeout = redetectTimeout
        }
        let proto = makeProtocol(try await waitForTag(timeout: timeout))
        append("再接続まで \(Int((ContinuousClock.now - start).seconds * 1000)) ms"
               + "（REFRESH から \(formatSeconds(ContinuousClock.now - refreshStart)) 秒）")
        try await proto.resumeAfterReconnect()
        return proto
    }

    private func showRefreshing(_ elapsed: Duration) {
        let seconds = Int(elapsed.seconds)
        guard phase != .refreshing(seconds: seconds) else { return }
        phase = .refreshing(seconds: seconds)
        session?.alertMessage = "描画中です（\(seconds) 秒）。動かさないでください"
    }

    private func makeProtocol(_ transport: APDUTransport) -> EZSignProtocol {
        EZSignProtocol(transport: transport, log: { [weak self] line in self?.append(line) })
    }

    // MARK: - セッション

    /// 新しいセッションを始める。前のセッションがまだ閉じていなければ、閉じた直後に始まる
    /// （同時に動けるセッションは 1 つで、後から始めたものは待ち行列に入る）。
    @discardableResult
    private func beginSession(message: String) -> Bool {
        guard let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: delegate) else { return false }
        session.alertMessage = message
        self.session = session
        sessionBegunAt = .now
        firstDetectedAt = nil
        connectedAt = nil
        detectedTag = nil
        session.begin()
        return true
    }

    /// 今のセッションを閉じて、すぐ新しいセッションを始める。
    private func switchSession(reason: String) throws {
        guard sessionSwitches < maxSessionSwitches else { throw WriteFailure.tooManySessionSwitches }
        sessionSwitches += 1
        append("\(reason)。新しいセッションに切り替えます（\(sessionSwitches) 回目）")
        let old = session
        session = nil  // ここから先、古いセッションの通知は「前のセッション」として記録だけする
        old?.invalidate()
        phase = .reconnecting
        guard beginSession(message: "そのまま動かさないでください") else { throw WriteFailure.sessionClosed }
    }

    /// 今のセッションが iPhone に打ち切られると見込む時刻。
    private func sessionDeadline() -> ContinuousClock.Instant? {
        guard let begunAt = sessionBegunAt else { return nil }
        var deadline = begunAt + limitFromBegin
        if let detectedAt = firstDetectedAt {
            deadline = min(deadline, detectedAt + limitFromDetection)
        }
        return deadline
    }

    private func remainingSessionTime() -> Duration? {
        sessionDeadline().map { $0 - ContinuousClock.now }
    }

    private func isNearSessionLimit() -> Bool {
        isNearSessionLimit(margin: switchMargin)
    }

    private func isNearSessionLimit(margin: Duration) -> Bool {
        guard let remaining = remainingSessionTime() else { return false }
        return remaining <= margin
    }

    // MARK: - タグの検出と接続

    /// EZ Sign が見つかるのを待って接続する。timeout を渡すと、その時間内に見つからなければ失敗する。
    private func waitForTag(timeout: Duration? = nil) async throws -> APDUTransport {
        while true {
            // セッションが終わっていたら、タグはもう来ない
            guard session != nil else { throw WriteFailure.sessionClosed }
            let tag: NFCTag
            if let pending = detectedTag {
                detectedTag = nil
                tag = pending
            } else {
                tagWaiterToken += 1
                if let timeout {
                    let token = tagWaiterToken
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.expireTagWaiter(token)
                    }
                }
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

    /// 待ち時間切れ。token の待ちがまだ続いていれば失敗させる。
    private func expireTagWaiter(_ token: Int) {
        guard token == tagWaiterToken, let waiter = tagWaiter else { return }
        tagWaiter = nil
        append("EZ Sign が見つからないまま待ち時間を過ぎました")
        waiter.resume(throwing: WriteFailure.tagNotFound)
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
        append("接続しました（このセッションの開始から \(sessionAgeText())）")
        return transport
    }

    // MARK: - SessionDelegate から呼ばれる

    func sessionDidBecomeActive(_ session: NFCTagReaderSession) {
        guard session === self.session else { return }
        append("NFC の読み取りを開始しました")
    }

    func session(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard session === self.session else { return }
        if firstDetectedAt == nil { firstDetectedAt = .now }
        guard tags.count == 1, let tag = tags.first else {
            append("タグが \(tags.count) 個見つかりました")
            session.alertMessage = "EZ Sign だけをタッチしてください"
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
        guard session === self.session else {
            append("前のセッション終了: \(describe(error))")
            return
        }
        self.session = nil
        detectedTag = nil
        append("NFC セッション終了: \(describe(error))（このセッションの開始から \(sessionAgeText())）")
        // 書き込みの成否は run() が決める（ここで失敗にすると、切り替えて続ける途中でも失敗表示になる）
        if let waiter = tagWaiter {
            tagWaiter = nil
            waiter.resume(throwing: error)
        }
    }

    // MARK: - 補助

    /// 同じセッションでつなぎ直せば続けられそうな通信エラーか。
    private func isTagLost(_ error: Error) -> Bool {
        let nsError = error as NSError
        // 100 接続が切れた / 101 再送の上限 / 102 タグの応答エラー / 104 つながっていない
        return nsError.domain == NFCErrorDomain && [100, 101, 102, 104].contains(nsError.code)
    }

    /// 接続が打ち切られたエラーか（103。1 回目の実機ではこの後もセッションは生きていた）。
    private func isConnectionInvalidated(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NFCErrorDomain && nsError.code == 103
    }

    /// セッションそのものが終わったエラーか。
    private func isSessionEnding(_ error: Error) -> Bool {
        if case WriteFailure.sessionClosed? = error as? WriteFailure { return true }
        let nsError = error as NSError
        // 103 セッション無効 / 201 時間切れ / 202 予期せず終了（実機では上限のときに 103 と 202 が出た）
        return nsError.domain == NFCErrorDomain && [103, 201, 202].contains(nsError.code)
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

    private func sessionAgeText() -> String {
        guard let sessionBegunAt else { return "-" }
        return "\(formatSeconds(ContinuousClock.now - sessionBegunAt)) 秒"
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
        case .waitingForTag: return "EZ Sign にタッチしてください"
        case .checkingPlacement: return "位置を確認中（動かさないでください）"
        case .authenticating: return "認証中"
        case let .sending(sent, total): return "転送中です（\(sent * 100 / total)%）"
        case let .refreshing(seconds): return "描画中です（\(seconds) 秒）。動かさないでください"
        case .reconnecting: return "つなぎ直しています（動かさないでください）"
        case let .done(seconds): return "完了（描画 \(formatSeconds(seconds)) 秒）"
        case let .failed(message): return "失敗: \(message)"
        }
    }
}
