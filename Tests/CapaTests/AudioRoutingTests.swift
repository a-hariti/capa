import XCTest
@testable import capa

final class AudioRoutingTests: XCTestCase {
  func testParsesMicSystemInAnyOrder() throws {
    let a = AudioRouting(argument: "mic+system")
    let b = AudioRouting(argument: "system+++mic")
    XCTAssertEqual(a, .micAndSystem)
    XCTAssertEqual(b, .micAndSystem)
  }

  func testParsesNone() throws {
    let routing = try XCTUnwrap(AudioRouting(argument: "none"))
    XCTAssertEqual(routing, .none)
  }

  func testRejectsUnknownToken() {
    XCTAssertNil(AudioRouting(argument: "music"))
  }
}