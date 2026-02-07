import XCTest
@testable import capa

final class TUIThemeTests: XCTestCase {
  func testTitleRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).title(s)
    let plain = TUITheme(isTTY: false).title(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
    XCTAssertFalse(plain.contains(Ansi.escape))
  }

  func testPrimaryRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).primary(s)
    let plain = TUITheme(isTTY: false).primary(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }

  func testLabelRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).label(s)
    let plain = TUITheme(isTTY: false).label(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }

  func testOptionRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).option(s)
    let plain = TUITheme(isTTY: false).option(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }

  func testMutedRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).muted(s)
    let plain = TUITheme(isTTY: false).muted(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }

  func testAccentRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).accent(s, bold: true)
    let plain = TUITheme(isTTY: false).accent(s, bold: true)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }

  func testRecordingDotRespectsIsTTY() {
    let s = "Hello"
    let colored = TUITheme(isTTY: true).recordingDot(s)
    let plain = TUITheme(isTTY: false).recordingDot(s)

    XCTAssertTrue(colored.contains(Ansi.escape))
    XCTAssertEqual(plain, s)
  }
}