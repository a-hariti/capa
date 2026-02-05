import XCTest
@testable import capa

final class TerminalWidgetsTests: XCTestCase {
  func testSmoothBarEndpoints() {
    XCTAssertEqual(Ansi.visibleWidth(Bar.render(fraction: 0, width: 8, style: .smooth)), 8)
    XCTAssertEqual(Ansi.visibleWidth(Bar.render(fraction: 1, width: 8, style: .smooth)), 8)
  }

  func testSmoothBarHalf() {
    XCTAssertEqual(Ansi.visibleWidth(Bar.render(fraction: 0.5, width: 8, style: .smooth)), 8)
  }

  func testStepsBarEndpoints() {
    XCTAssertEqual(Bar.render(fraction: 0, width: 8, style: .steps), "▁")
    XCTAssertEqual(Bar.render(fraction: 1, width: 8, style: .steps), "█")
  }

  func testVisibleWidthStripsAnsi() {
    let s = "a " + Ansi.fg256(46) + "b" + Ansi.reset + " c"
    XCTAssertEqual(Ansi.visibleWidth(s), 5)

    let s2 = Ansi.hideCursor + "x" + Ansi.showCursor
    XCTAssertEqual(Ansi.visibleWidth(s2), 1)
  }

  func testLoudnessMeterRenders() {
    let s = LoudnessMeter.render(label: "MIC", db: -18, width: 8, style: .smooth)
    XCTAssertTrue(s.contains("MIC"))
    XCTAssertTrue(s.contains("dB"))
    XCTAssertGreaterThan(Ansi.visibleWidth(s), 0)
  }
}
