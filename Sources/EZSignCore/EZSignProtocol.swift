/// APDU を 1 つ送って応答を受け取る通信路。iPhone では Core NFC、テストでは偽のタグ。
protocol APDUTransport {
    func send(_ apdu: [UInt8]) async throws -> APDUResponse
}

enum EZSignError: Error, Equatable, CustomStringConvertible {
    /// 状態語が 90 00 以外だった
    case rejected(step: String, status: String)
    /// 時間内に描画完了の返事がなかった
    case refreshTimedOut(seconds: Double)

    var description: String {
        switch self {
        case let .rejected(step, status):
            return "\(step) が拒否されました（\(status)）"
        case let .refreshTimedOut(seconds):
            return "描画が \(formatSeconds(seconds)) 秒以内に終わりませんでした"
        }
    }
}

/// EZ Sign への書き込み手順（docs/PROTOCOL.md）。
///
/// 1 回の書き込みは checkPlacement → begin → sendFrame → startRefresh → waitForRefresh の順に呼ぶ。
/// 通信エラーはそのまま投げるので、呼び出し側でタグにつなぎ直してから
/// resumeAfterReconnect → waitForRefresh で続きを待てる。
///
/// 各メソッドは呼び出し元のアクターで動く（isolation 引数）。
/// メインアクターから呼べば log や progress もメインアクターで呼ばれる。
struct EZSignProtocol {
    var transport: APDUTransport
    var log: (String) -> Void = { _ in }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var clock = ContinuousClock()

    /// REFRESH から最初の POLL までの待ち時間（ezsign-nfc と同じ）。
    var refreshSettleTime: Duration = .milliseconds(1500)
    var pollInterval: Duration = .milliseconds(200)

    init(transport: APDUTransport, log: @escaping (String) -> Void = { _ in }) {
        self.transport = transport
        self.log = log
    }

    /// 書き込みの前に、当てた位置で通信が安定しているかを確かめる。
    /// 無害な SELECT を何回か送り、全部 90 00 で返ってくれば OK。だめなら投げる
    /// （拒否は EZSignError、通信エラーはそのまま）。
    /// これはこのアプリ独自の確認で、公式アプリの確認方法は分かっていない。
    func checkPlacement(probes: Int = 8, interval: Duration = .milliseconds(100),
                        isolation: isolated (any Actor)? = #isolation) async throws {
        var milliseconds: [Int] = []
        for _ in 0..<probes {
            let start = clock.now
            try await exchange(EZSignCommand.select, step: "位置確認 SELECT", requireOK: true, quiet: true)
            milliseconds.append(Int((clock.now - start).seconds * 1000))
            try await sleep(interval)
        }
        let average = milliseconds.reduce(0, +) / max(milliseconds.count, 1)
        log("位置確認 OK: \(probes) 回とも応答（平均 \(average) ms / 最大 \(milliseconds.max() ?? 0) ms）")
    }

    /// SELECT → VERIFY → SELECT → INIT。INIT の応答の機種情報を返す。
    func begin(isolation: isolated (any Actor)? = #isolation) async throws -> DeviceInfo {
        try await authenticate()
        let reply = try await exchange(EZSignCommand.initWrite, step: "INIT", requireOK: true)
        let info = DeviceInfo(initReply: reply.data)
        log("機種情報: \(info.summary)")
        return info
    }

    /// フレームバッファを DATA コマンドで全部送る。progress には (送った数, 全体の数) を渡す。
    func sendFrame(_ frame: [UInt8], progress: (Int, Int) -> Void = { _, _ in },
                   isolation: isolated (any Actor)? = #isolation) async throws {
        let commands = EZSignCommand.dataCommands(for: frame)
        let start = clock.now
        for (index, command) in commands.enumerated() {
            let number = index + 1
            let quiet = !(number == 1 || number == commands.count || number % 30 == 0)
            try await exchange(command, step: "DATA \(number)/\(commands.count)", requireOK: true, quiet: quiet)
            progress(number, commands.count)
        }
        log("DATA 送信完了: \(commands.count) 個 / \(frame.count) バイト / \(formatSeconds(clock.now - start)) 秒")
    }

    /// REFRESH を送り、最初の POLL まで少し待つ。
    func startRefresh(isolation: isolated (any Actor)? = #isolation) async throws {
        try await exchange(EZSignCommand.refresh, step: "REFRESH", requireOK: true)
        try await sleep(refreshSettleTime)
    }

    /// 描画が終わるまで POLL を繰り返す。start は REFRESH を送った時刻。
    /// 終わったら REFRESH からの経過時間を返す。progress には経過時間を渡す。
    @discardableResult
    func waitForRefresh(startedAt start: ContinuousClock.Instant, timeout: Duration = .seconds(60),
                        progress: (Duration) -> Void = { _ in },
                        isolation: isolated (any Actor)? = #isolation) async throws -> Duration {
        var polls = 0
        var lastStatus: [UInt8]?
        while true {
            let elapsed = clock.now - start
            if elapsed > timeout {
                throw EZSignError.refreshTimedOut(seconds: elapsed.seconds)
            }
            let response = try await exchange(EZSignCommand.poll, step: "POLL", quiet: true)
            polls += 1
            let status = Array(response.data.prefix(1))
            if status != lastStatus || polls % 25 == 0 {
                let shown = status.isEmpty ? "データなし" : hexString(status)
                log("POLL #\(polls): \(shown) / \(response.statusHex)（REFRESH から \(formatSeconds(elapsed)) 秒）")
                lastStatus = status
            }
            if status == [0x00] {
                log("描画完了（REFRESH から \(formatSeconds(elapsed)) 秒、POLL \(polls) 回）")
                return elapsed
            }
            progress(elapsed)
            try await sleep(pollInterval)
        }
    }

    /// 描画中につなぎ直した直後に呼ぶ。POLL が通ればそのまま、通らなければ認証からやり直す。
    func resumeAfterReconnect(isolation: isolated (any Actor)? = #isolation) async throws {
        let response = try await exchange(EZSignCommand.poll, step: "POLL（再接続直後）")
        if response.isOK { return }
        log("POLL が通らないので SELECT / VERIFY からやり直します")
        try await authenticate()
    }

    private func authenticate(isolation: isolated (any Actor)? = #isolation) async throws {
        try await exchange(EZSignCommand.select, step: "SELECT", requireOK: true)
        let verify = try await exchange(EZSignCommand.verify, step: "VERIFY")
        if !verify.isOK {
            try await sleep(.milliseconds(300))
            try await exchange(EZSignCommand.verify, step: "VERIFY（再試行）", requireOK: true)
        }
        try await exchange(EZSignCommand.select, step: "SELECT", requireOK: true)
    }

    @discardableResult
    private func exchange(_ apdu: [UInt8], step: String, requireOK: Bool = false, quiet: Bool = false,
                          isolation: isolated (any Actor)? = #isolation) async throws -> APDUResponse {
        let start = clock.now
        let response = try await transport.send(apdu)
        let milliseconds = Int((clock.now - start).seconds * 1000)
        if !quiet || (requireOK && !response.isOK) {
            let extra = response.data.isEmpty ? "" : " + \(response.data.count) バイト"
            log("\(step) → \(response.statusHex)\(extra)（\(milliseconds) ms）")
        }
        if requireOK && !response.isOK {
            throw EZSignError.rejected(step: step, status: response.statusHex)
        }
        return response
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

func formatSeconds(_ duration: Duration) -> String {
    formatSeconds(duration.seconds)
}

func formatSeconds(_ seconds: Double) -> String {
    let tenths = Int((seconds * 10).rounded())
    return "\(tenths / 10).\(tenths % 10)"
}
