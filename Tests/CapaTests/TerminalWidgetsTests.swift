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
    let theme = TUITheme(isTTY: true)
    let s = LoudnessMeter.render(label: "MIC", db: -18, holdDB: -12, clipped: true, width: 8, style: .smooth, theme: theme)
    XCTAssertTrue(s.contains("MIC"))
    XCTAssertTrue(s.contains("dB"))
    XCTAssertTrue(s.contains("!"))
    XCTAssertGreaterThan(Ansi.visibleWidth(s), 0)
  }

  func testFitTickerLineDropsSuffixWhenTooWide() {
    let base = "REC 00:10"
    let suffix = "MIC -20dB ████████  SYS -30dB ████████"
    let narrow = fitTickerLine(base: base, suffix: suffix, maxColumns: 10)
    XCTAssertEqual(narrow, base)

    let wide = fitTickerLine(base: base, suffix: suffix, maxColumns: 120)
    XCTAssertNotEqual(wide, base)
    XCTAssertTrue(wide.contains(suffix))
  }

  func testLoudnessMeterFraction() {
    XCTAssertEqual(LoudnessMeter.fraction(db: 0), 1.0)
    XCTAssertEqual(LoudnessMeter.fraction(db: -60), 0.0)
    XCTAssertEqual(LoudnessMeter.fraction(db: -30), 0.5)
  }

  func testLoudnessMeterColorCode() {
    XCTAssertEqual(LoudnessMeter.colorCode(db: -2), TUITheme.Color.meterHot)
    XCTAssertEqual(LoudnessMeter.colorCode(db: -12), TUITheme.Color.meterMid)
    XCTAssertEqual(LoudnessMeter.colorCode(db: -20), TUITheme.Color.meterLow)
  }

  func testBarRenderColoredSmooth() {
    let s = Bar.renderColoredSmooth(fraction: 0.5, width: 10, fillFG: 1, trackFG: 2, trackBG: 3)
    XCTAssertEqual(Ansi.visibleWidth(s), 10)
  }

  func testBarRenderMeterSmooth() {
    let s = Bar.renderMeterSmooth(fraction: 0.5, holdFraction: 0.8, width: 10, fillFG: 1, trackFG: 2, trackBG: 3, holdFG: 4)
    XCTAssertEqual(Ansi.visibleWidth(s), 10)
  }
}
