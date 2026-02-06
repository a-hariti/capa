import XCTest
@testable import capa

final class TerminalInputTests: XCTestCase {
  func testDecodeUTF8CharacterASCII() {
    let c = TerminalController.decodeUTF8Character(startByte: 0x41, readNextByte: { _ in nil })
    XCTAssertEqual(c, "A")
  }

  func testDecodeUTF8CharacterTwoByteSequence() {
    var remaining: [UInt8] = [0xA9]
    let c = TerminalController.decodeUTF8Character(startByte: 0xC3, readNextByte: { _ in
      guard !remaining.isEmpty else { return nil }
      return remaining.removeFirst()
    })

    let expected = String(bytes: [0xC3, 0xA9], encoding: .utf8)?.first
    XCTAssertEqual(c, expected)
  }

  func testDecodeUTF8CharacterFourByteSequence() {
    var remaining: [UInt8] = [0x9F, 0x8E, 0xA5]
    let c = TerminalController.decodeUTF8Character(startByte: 0xF0, readNextByte: { _ in
      guard !remaining.isEmpty else { return nil }
      return remaining.removeFirst()
    })

    let expected = String(bytes: [0xF0, 0x9F, 0x8E, 0xA5], encoding: .utf8)?.first
    XCTAssertEqual(c, expected)
  }

  func testDecodeUTF8CharacterRejectsInvalidContinuation() {
    var remaining: [UInt8] = [0x41]
    let c = TerminalController.decodeUTF8Character(startByte: 0xC3, readNextByte: { _ in
      guard !remaining.isEmpty else { return nil }
      return remaining.removeFirst()
    })
    XCTAssertNil(c)
  }
}
