import AVFoundation
import Foundation
import XCTest
@testable import capa

final class TimecodeSyncTests: XCTestCase {
  func testTimecodeUsesDateClockAndFPS() {
    var cal = Calendar(identifier: .gregorian)
    let tz = TimeZone(secondsFromGMT: 0)!
    cal.timeZone = tz
    let date = cal.date(from: DateComponents(
      calendar: cal,
      timeZone: tz,
      year: 2026,
      month: 2,
      day: 6,
      hour: 13,
      minute: 4,
      second: 9,
      nanosecond: 500_000_000
    ))!

    let sync = TimecodeSyncContext(syncID: "sync-1", startDate: date, fps: 60, timeZone: tz)
    XCTAssertEqual(sync.startTimecode, "13:04:09:30")
    XCTAssertEqual(sync.fps, 60)
  }

  func testMetadataContainsSyncDescription() async throws {
    let sync = TimecodeSyncContext(syncID: "sync-abc", startDate: Date(timeIntervalSince1970: 0), fps: 60, timeZone: TimeZone(secondsFromGMT: 0)!)
    let metadata = sync.metadata(role: "camera")
    var descriptions: [String] = []
    for item in metadata {
      if let value = try await item.load(.stringValue) {
        descriptions.append(value)
      }
    }
    let joined = descriptions.joined(separator: " ")

    XCTAssertTrue(joined.contains("sync-abc"))
    XCTAssertTrue(joined.contains("role=camera"))
    XCTAssertTrue(joined.contains("fps=60"))
  }

  func testTimecodeSampleBufferCarriesFrameNumber() throws {
    let tz = TimeZone(secondsFromGMT: 0)!
    let sync = TimecodeSyncContext(syncID: "sync-sample", startDate: Date(timeIntervalSince1970: 5000), fps: 60, timeZone: tz)
    let sample = try sync.makeTimecodeSampleBuffer(
      presentationTimeStamp: .zero,
      duration: CMTime(value: 1, timescale: 60)
    )

    guard let block = CMSampleBufferGetDataBuffer(sample) else {
      return XCTFail("Missing data buffer")
    }
    var frame = Int32.zero
    let status = withUnsafeMutableBytes(of: &frame) { bytes in
      CMBlockBufferCopyDataBytes(
        block,
        atOffset: 0,
        dataLength: MemoryLayout<Int32>.size,
        destination: bytes.baseAddress!
      )
    }
    XCTAssertEqual(status, kCMBlockBufferNoErr)
    XCTAssertEqual(Int32(bigEndian: frame), sync.startFrameNumber)
  }
}
