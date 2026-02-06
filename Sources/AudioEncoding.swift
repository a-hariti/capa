import AVFoundation
import CoreMedia

enum AudioEncoding {
  static func aacSettings(sampleRate: Double, channels: Int, baseline: [String: Any]?) -> [String: Any] {
    var settings = baseline ?? [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 128_000,
    ]

    settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
    settings[AVSampleRateKey] = max(8_000, sampleRate)
    settings[AVNumberOfChannelsKey] = max(1, channels)

    // Keep bitrate sane for mono inputs (e.g. AirPods 24kHz/1ch).
    if let br = settings[AVEncoderBitRateKey] as? Int {
      if channels == 1 {
        settings[AVEncoderBitRateKey] = min(br, 96_000)
      }
    } else {
      settings[AVEncoderBitRateKey] = (channels == 1) ? 96_000 : 128_000
    }

    return settings
  }

  static func sampleRateAndChannels(from sample: CMSampleBuffer) -> (sampleRate: Double, channels: Int)? {
    guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
    guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
    let asbd = asbdPtr.pointee
    let sampleRate = asbd.mSampleRate
    let channels = Int(asbd.mChannelsPerFrame)
    guard sampleRate > 0, channels > 0 else { return nil }
    return (sampleRate, channels)
  }
}

