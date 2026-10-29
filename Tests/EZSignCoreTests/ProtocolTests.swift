import XCTest
@testable import EZSignCore

/// magic-epaper-app / ezsign-nfc が送る手順どおりに応える偽の EZ Sign。
final class FakeTag: APDUTransport {
    var sent: [[UInt8]] = []
    var received: [UInt8] = []
    var pollsUntilReady: Int
    /// 最初の VERIFY を拒否する
    var rejectFirstVerify = false
    /// POLL をこの回数だけ拒否する（再接続直後の確認用）
    var rejectedPolls = 0
    var initReply: [UInt8] = Array(hex: "A007F0072002580190")
    var replies: [[UInt8]: APDUResponse] = [:]
    /// この回数だけ送ったら、それ以降は通信エラーにする（位置がずれた想定）
    var connectionLostAfter: Int?

    struct ConnectionLost: Error {}

    init(pollsUntilReady: Int = 3) {
        self.pollsUntilReady = pollsUntilReady
    }

    func send(_ apdu: [UInt8]) async throws -> APDUResponse {
        if let limit = connectionLostAfter, sent.count >= limit { throw ConnectionLost() }
        sent.append(apdu)
        if let reply = replies[apdu] { return reply }
        switch apdu {
        case EZSignCommand.select, EZSignCommand.refresh:
            return .ok
        case EZSignCommand.verify:
            if rejectFirstVerify {
                rejectFirstVerify = false
                return APDUResponse(sw1: 0x63, sw2: 0x00)
            }
            return .ok
        case EZSignCommand.initWrite:
            return APDUResponse(data: initReply, sw1: 0x90, sw2: 0x00)
        case EZSignCommand.poll:
            if rejectedPolls > 0 {
                rejectedPolls -= 1
                return APDUResponse(sw1: 0x6D, sw2: 0x00)
            }
            pollsUntilReady -= 1
            return APDUResponse(data: [pollsUntilReady <= 0 ? 0x00 : 0x01], sw1: 0x90, sw2: 0x00)
        default:
            guard apdu.count >= 5, apdu[0] == 0xF0, apdu[1] == 0xD2 else {
                XCTFail("知らない APDU: \(hexString(apdu))")
                return APDUResponse(sw1: 0x6D, sw2: 0x00)
            }
            let sequence = Int(apdu[2]) << 8 | Int(apdu[3])
            XCTAssertEqual(sequence, received.count / EZSignCommand.chunkSize, "DATA の順番が違う")
            XCTAssertEqual(Int(apdu[4]), apdu.count - 5)
            received += apdu[5...]
            return .ok
        }
    }
}

final class ProtocolTests: XCTestCase {
    private func makeProtocol(_ tag: FakeTag) -> EZSignProtocol {
        var proto = EZSignProtocol(transport: tag)
        proto.sleep = { _ in }
        return proto
    }

    func testCommandBytesMatchReference() {
        XCTAssertEqual(EZSignCommand.select, Array(hex: "00A4040007D2760000850101"))
        XCTAssertEqual(EZSignCommand.verify, Array(hex: "002000010420091210"))
        XCTAssertEqual(EZSignCommand.initWrite, Array(hex: "00D1000000"))
        XCTAssertEqual(EZSignCommand.refresh, Array(hex: "F0D4858000"))
        XCTAssertEqual(EZSignCommand.poll, Array(hex: "F0DE000001"))
        XCTAssertEqual(Array(EZSignCommand.data(sequence: 0x0102, chunk: [0xAA, 0xBB][...])),
                       [0xF0, 0xD2, 0x01, 0x02, 0x02, 0xAA, 0xBB])
    }

    func testFourPointTwoFrameIs120FullChunks() {
        let commands = EZSignCommand.dataCommands(for: [UInt8](repeating: 0x55, count: 30_000))
        XCTAssertEqual(commands.count, 120)
        XCTAssertTrue(commands.allSatisfy { $0[4] == 250 && $0.count == 255 })
        XCTAssertEqual(Array(commands[119][0...4]), [0xF0, 0xD2, 0x00, 119, 250])
    }

    func testTwoPointNineFrameEndsWithShortChunk() {
        let commands = EZSignCommand.dataCommands(for: [UInt8](repeating: 0, count: 9_472))
        XCTAssertEqual(commands.count, 38)
        XCTAssertEqual(commands.last?[4], 222)
        XCTAssertEqual(commands.last?.count, 227)
    }

    func testFullWriteSendsReferenceSequence() async throws {
        let tag = FakeTag()
        let proto = makeProtocol(tag)
        var frame = [UInt8]()
        for i in 0..<30_000 { frame.append(UInt8(i % 251)) }

        let info = try await proto.begin()
        XCTAssertEqual(info.identify(), .inch4_2)
        var lastProgress = (0, 0)
        try await proto.sendFrame(frame, progress: { lastProgress = ($0, $1) })
        try await proto.startRefresh()
        try await proto.waitForRefresh(startedAt: ContinuousClock.now)

        XCTAssertEqual(tag.received, frame)
        XCTAssertEqual(lastProgress.0, 120)
        XCTAssertEqual(lastProgress.1, 120)
        XCTAssertEqual(Array(tag.sent[0..<4]),
                       [EZSignCommand.select, EZSignCommand.verify, EZSignCommand.select, EZSignCommand.initWrite])
        XCTAssertEqual(tag.sent[4 + 120], EZSignCommand.refresh)
        XCTAssertEqual(tag.sent.last, EZSignCommand.poll)
        XCTAssertEqual(tag.sent.count, 4 + 120 + 1 + 3)
    }

    func testPlacementCheckSendsOnlySelectProbes() async throws {
        let tag = FakeTag()
        try await makeProtocol(tag).checkPlacement(probes: 8)
        XCTAssertEqual(tag.sent, Array(repeating: EZSignCommand.select, count: 8))
    }

    func testPlacementCheckFailsWhenAProbeIsRejected() async {
        let tag = FakeTag()
        tag.replies[EZSignCommand.select] = APDUResponse(sw1: 0x6A, sw2: 0x82)
        do {
            try await makeProtocol(tag).checkPlacement()
            XCTFail("拒否されたのに位置確認が通った")
        } catch let error as EZSignError {
            XCTAssertEqual(error, .rejected(step: "位置確認 SELECT", status: "6A 82"))
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testPlacementCheckFailsWhenConnectionDrops() async {
        let tag = FakeTag()
        tag.connectionLostAfter = 3
        do {
            try await makeProtocol(tag).checkPlacement(probes: 8)
            XCTFail("途中で切れたのに位置確認が通った")
        } catch {
            XCTAssertTrue(error is FakeTag.ConnectionLost)
            XCTAssertEqual(tag.sent.count, 3)
        }
    }

    func testVerifyIsRetriedOnce() async throws {
        let tag = FakeTag()
        tag.rejectFirstVerify = true
        _ = try await makeProtocol(tag).begin()
        XCTAssertEqual(tag.sent, [EZSignCommand.select, EZSignCommand.verify, EZSignCommand.verify,
                                  EZSignCommand.select, EZSignCommand.initWrite])
    }

    func testRejectedStepThrowsWithItsName() async {
        let tag = FakeTag()
        tag.replies[EZSignCommand.initWrite] = APDUResponse(sw1: 0x6A, sw2: 0x82)
        do {
            _ = try await makeProtocol(tag).begin()
            XCTFail("INIT の拒否が投げられていない")
        } catch let error as EZSignError {
            XCTAssertEqual(error, .rejected(step: "INIT", status: "6A 82"))
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    func testResumeAfterReconnectReauthenticatesWhenPollIsRejected() async throws {
        let tag = FakeTag()
        tag.rejectedPolls = 1
        try await makeProtocol(tag).resumeAfterReconnect()
        XCTAssertEqual(tag.sent, [EZSignCommand.poll, EZSignCommand.select, EZSignCommand.verify, EZSignCommand.select])
    }

    func testResumeAfterReconnectKeepsGoingWhenPollIsAccepted() async throws {
        let tag = FakeTag()
        try await makeProtocol(tag).resumeAfterReconnect()
        XCTAssertEqual(tag.sent, [EZSignCommand.poll])
    }

    func testWaitForRefreshTimesOut() async {
        let tag = FakeTag(pollsUntilReady: .max)
        let proto = makeProtocol(tag)
        do {
            try await proto.waitForRefresh(startedAt: ContinuousClock.now - .seconds(61))
            XCTFail("タイムアウトしていない")
        } catch let error as EZSignError {
            guard case .refreshTimedOut = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }
    }

    // ezsign-nfc の tests/test_protocol.py にある実機（4.2 インチ）の INIT 応答
    func testIdentifyFromRealInitReply() {
        let reply = Array(hex: "A007F0072002580190A1070112" + "0030FFFFFFB10108B20114B30100"
                          + "C00A53454142303932383330C104BE2DCD1DD1070120" + "0000000000")
        let info = DeviceInfo(initReply: reply)
        XCTAssertEqual(info.serialNumber, "SEAB092830")
        XCTAssertEqual(info.identify(), .inch4_2)
        XCTAssertEqual(DeviceInfo(records: [0xA0: Array(hex: "F007200200800128")]).identify(), .inch2_9)
        XCTAssertNil(DeviceInfo(records: [0xA0: [0x00, 0x00]]).identify())
    }
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self = bytes
    }
}
