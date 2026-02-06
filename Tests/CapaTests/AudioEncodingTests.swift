import AVFoundation
import XCTest
@testable import capa

final class AudioEncodingTests: XCTestCase {
  func testAACSettingsOverrideSampleRateAndChannels() {
    let baseline: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    let s = AudioEncoding.aacSettings(sampleRate: 24_000, channels: 1, baseline: baseline)
    XCTAssertEqual(s[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
    XCTAssertEqual(s[AVSampleRateKey] as? Double, 24_000)
    XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1)
    XCTAssertEqual(s[AVEncoderBitRateKey] as? Int, 96_000)
  }
}
