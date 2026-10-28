import Foundation
import XCTest
@testable import EZSignCore

final class FrameTests: XCTestCase {
    func testFourPointTwoFrameIs30000BytesOfWhite() {
        let bytes = Frame(model: .inch4_2).encoded(layout: .rowMirror)
        XCTAssertEqual(bytes.count, 30_000)
        XCTAssertEqual(PanelModel.inch4_2.frameByteCount, 30_000)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0b01_01_01_01 })
    }

    // 以下の期待値は ezsign-nfc の tests/test_encode.py と同じ。
    func testRowLayout() {
        var frame = Frame(width: 8, height: 4)
        frame[0, 0] = .red
        frame[1, 0] = .black
        frame[0, 1] = .yellow
        let bytes = frame.encoded(layout: .row)
        XCTAssertEqual(bytes[0], 0b11_00_01_01)
        XCTAssertEqual(bytes[2], 0b10_01_01_01)
    }

    func testColMirrorMatchesMagicEpaperReference() {
        var frame = Frame(width: 8, height: 4)
        frame[7, 0] = .red
        frame[7, 1] = .black
        let bytes = frame.encoded(layout: .colMirror)
        XCTAssertEqual(bytes[0] >> 6, 3)
        XCTAssertEqual((bytes[0] >> 4) & 3, 0)
        XCTAssertEqual((bytes[0] >> 2) & 3, 1)
    }

    func testRowMirrorPutsRightmostPixelFirst() {
        var frame = Frame(model: .inch4_2)
        frame[399, 0] = .red
        frame[0, 0] = .black
        let bytes = frame.encoded(layout: .rowMirror)
        XCTAssertEqual(bytes[0] >> 6, 3)
        XCTAssertEqual(bytes[99] & 0b11, 0)
    }

    func testEveryLayoutRoundTrips() {
        var random = SeededRandom(seed: 2)
        var frame = Frame(width: 40, height: 30)
        for y in 0..<30 {
            for x in 0..<40 {
                frame[x, y] = PaletteColor(rawValue: UInt8(random.next() % 4))!
            }
        }
        for layout in PixelLayout.allCases {
            let decoded = Frame(decoding: frame.encoded(layout: layout), width: 40, height: 30, layout: layout)
            XCTAssertEqual(decoded, frame, layout.rawValue)
        }
    }

    func testNearestColour() {
        XCTAssertEqual(PaletteColor.nearest(r: 0, g: 0, b: 0), .black)
        XCTAssertEqual(PaletteColor.nearest(r: 250, g: 250, b: 250), .white)
        XCTAssertEqual(PaletteColor.nearest(r: 255, g: 192, b: 0), .yellow)
        XCTAssertEqual(PaletteColor.nearest(r: 200, g: 20, b: 30), .red)
    }

    func testRGBARoundTrip() {
        let frame = TestPattern.make(stamp: "#1 2026-10-28 12:00:00", layout: .rowMirror)
        XCTAssertEqual(Frame(rgba: frame.rgba(), width: frame.width, height: frame.height), frame)
    }

    func testFontGlyphsAreFiveBySeven() {
        for (character, rows) in BitmapFont.glyphs {
            XCTAssertEqual(rows.count, BitmapFont.glyphHeight, "\(character)")
            for row in rows {
                XCTAssertEqual(row.count, BitmapFont.glyphWidth, "\(character)")
                XCTAssertTrue(row.allSatisfy { $0 == "#" || $0 == "." }, "\(character)")
            }
        }
    }

    func testDrawTextClipsAtEdges() {
        var frame = Frame(width: 10, height: 5)
        let width = frame.drawText("AB", x: 7, y: 2, scale: 1, color: .black)
        XCTAssertEqual(width, 11)
        XCTAssertEqual(frame[8, 2], .black)  // "A" の 1 行目 ".###." の 2 文字目
    }

    func testTestPatternUsesAllFourColours() {
        let frame = TestPattern.make(stamp: "#1 2026-10-28 12:00:00", layout: .rowMirror)
        XCTAssertEqual(Set(frame.pixels), Set(PaletteColor.allCases))
        XCTAssertEqual(frame[0, 0], .red)

        // EZSIGN_PREVIEW_PPM にパスを入れると、目視確認用の画像を書き出す
        if let path = ProcessInfo.processInfo.environment["EZSIGN_PREVIEW_PPM"] {
            var ppm = Array("P6\n\(frame.width) \(frame.height)\n255\n".utf8)
            for color in frame.pixels {
                let c = color.rgb
                ppm += [c.r, c.g, c.b]
            }
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(ppm)))
        }
    }
}

/// テスト用の再現可能な乱数（xorshift）。
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
