import XCTest
import ArgumentParser
@testable import capa

final class CLIParsingTests: XCTestCase {
  func testParseDisplaySelection() throws {
    let parsed = try Capa.parseAsRoot(["--display", "2"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    if case .index(let idx) = cmd.displaySelection {
      XCTAssertEqual(idx, 2)
    } else {
      XCTFail("Expected index(2), got \(String(describing: cmd.displaySelection))")
    }
  }

  func testParseAudioAndFPS() throws {
    let parsed = try Capa.parseAsRoot(["--audio", "system", "--fps", "30"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertEqual(cmd.audioRouting, AudioRouting.system)
    if case .cfr(let fps) = cmd.fpsSelection {
      XCTAssertEqual(fps, 30)
    } else {
      XCTFail("Expected cfr(30), got \(String(describing: cmd.fpsSelection))")
    }
  }

  func testParseAudioFlexibleOrderAndSafeMixOff() throws {
    let parsed = try Capa.parseAsRoot([
      "--audio", "system+mic",
      "--safe-mix", "off",
    ])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertEqual(cmd.audioRouting, AudioRouting.micAndSystem)
    XCTAssertEqual(cmd.safeMixMode, .off)
  }

  func testParseAudioMicOnly() throws {
    let parsed = try Capa.parseAsRoot(["--audio", "mic"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertEqual(cmd.audioRouting, AudioRouting.mic)
  }

  func testParseVFRMode() throws {
    let parsed = try Capa.parseAsRoot(["--fps", "vfr"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    if case .vfr = cmd.fpsSelection {
      // success
    } else {
      XCTFail("Expected vfr, got \(String(describing: cmd.fpsSelection))")
    }
  }

  func testDefaultFPSIsNil() throws {
    let parsed = try Capa.parseAsRoot([])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertNil(cmd.fpsSelection, "Default fpsSelection should be nil (VFR)")
  }

  func testUnknownArgumentThrows() {
    XCTAssertThrowsError(try Capa.parseAsRoot(["--nope"]))
  }

  func testParseProjectName() throws {
    let parsed = try Capa.parseAsRoot(["--project-name", "demo"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertEqual(cmd.projectName, "demo")
  }

  func testEmptyProjectNameThrows() {
    XCTAssertThrowsError(try Capa.parseAsRoot(["--project-name", "   "]))
  }

  func testNoOpenFlagParses() throws {
    let parsed = try Capa.parseAsRoot(["--no-open"])
    guard let cmd = parsed as? Capa else {
      return XCTFail("Failed to parse as Capa")
    }
    XCTAssertTrue(cmd.noOpenFlag)
  }

  func testOpenFlagIsNotSupported() {
    XCTAssertThrowsError(try Capa.parseAsRoot(["--open"]))
  }
}
