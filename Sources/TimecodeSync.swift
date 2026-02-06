import AVFoundation
import CoreMedia
import Foundation

struct TimecodeSyncContext: Sendable {
  let syncID: String
  let startDate: Date
  let fps: Int
  let startTimecode: String
  let startISO8601UTC: String
  let startFrameNumber: Int32

  var shortID: String {
    String(syncID.prefix(8))
  }

  init(
    syncID: String = UUID().uuidString.lowercased(),
    startDate: Date = Date(),
    fps: Int,
    timeZone: TimeZone = .current
  ) {
    self.syncID = syncID
    self.startDate = startDate
    self.fps = max(1, fps)
    self.startTimecode = Self.makeTimecode(from: startDate, fps: self.fps, timeZone: timeZone)
    self.startISO8601UTC = Self.iso8601UTC(startDate)
    self.startFrameNumber = Self.frameNumber(fromTimecode: self.startTimecode, fps: self.fps)
  }

  func metadata(role: String) -> [AVMetadataItem] {
    [
      metadataItem(identifier: .commonIdentifierSoftware, value: "capa"),
      metadataItem(identifier: .commonIdentifierCreationDate, value: startISO8601UTC),
      metadataItem(identifier: .commonIdentifierDescription, value: metadataDescription(role: role)),
    ]
  }

  func makeTimecodeWriterInput() -> AVAssetWriterInput {
    let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil)
    input.expectsMediaDataInRealTime = false
    input.metadata = [trackTitle("Timecode")]
    input.languageCode = "qad"
    input.extendedLanguageTag = "qad-x-capa-timecode"
    return input
  }

  func makeTimecodeSampleBuffer(presentationTimeStamp: CMTime, duration: CMTime) throws -> CMSampleBuffer {
    var format: CMTimeCodeFormatDescription?
    let sourceRefName: [CFString: Any] = [
      kCMTimeCodeFormatDescriptionKey_Value: "capa-\(shortID)",
      kCMTimeCodeFormatDescriptionKey_LangCode: 0
    ]
    let extensions: [CFString: Any] = [
      kCMTimeCodeFormatDescriptionExtension_SourceReferenceName: sourceRefName
    ]
    let createStatus = CMTimeCodeFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
      frameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
      frameQuanta: UInt32(fps),
      flags: kCMTimeCodeFlag_24HourMax,
      extensions: extensions as CFDictionary,
      formatDescriptionOut: &format
    )
    guard createStatus == noErr, let format else {
      throw NSError(
        domain: "TimecodeSyncContext",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "CMTimeCodeFormatDescriptionCreate failed (\(createStatus))"]
      )
    }

    var dataBuffer: CMBlockBuffer?
    let size = MemoryLayout<Int32>.size
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: size,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: size,
      flags: 0,
      blockBufferOut: &dataBuffer
    )
    guard blockStatus == kCMBlockBufferNoErr, let dataBuffer else {
      throw NSError(
        domain: "TimecodeSyncContext",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "CMBlockBufferCreateWithMemoryBlock failed (\(blockStatus))"]
      )
    }

    var beFrame = startFrameNumber.bigEndian
    let replaceStatus = CMBlockBufferReplaceDataBytes(
      with: &beFrame,
      blockBuffer: dataBuffer,
      offsetIntoDestination: 0,
      dataLength: size
    )
    guard replaceStatus == kCMBlockBufferNoErr else {
      throw NSError(
        domain: "TimecodeSyncContext",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "CMBlockBufferReplaceDataBytes failed (\(replaceStatus))"]
      )
    }

    var timing = CMSampleTimingInfo(
      duration: duration,
      presentationTimeStamp: presentationTimeStamp,
      decodeTimeStamp: .invalid
    )
    var sampleSize = size
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
      allocator: kCFAllocatorDefault,
      dataBuffer: dataBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: format,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw NSError(
        domain: "TimecodeSyncContext",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferCreate failed (\(sampleStatus))"]
      )
    }

    return sampleBuffer
  }

  private func metadataDescription(role: String) -> String {
    "capa-sync id=\(syncID) role=\(role) tc=\(startTimecode) fps=\(fps) start=\(startISO8601UTC)"
  }

  private func trackTitle(_ title: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .quickTimeUserDataTrackName
    item.value = title as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }

  private func metadataItem(identifier: AVMetadataIdentifier, value: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }

  private static func makeTimecode(from date: Date, fps: Int, timeZone: TimeZone) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)

    let h = max(0, min(23, c.hour ?? 0))
    let m = max(0, min(59, c.minute ?? 0))
    let s = max(0, min(59, c.second ?? 0))
    let ns = max(0, c.nanosecond ?? 0)
    let ff = min(max(0, Int((Double(ns) / 1_000_000_000.0) * Double(max(1, fps)))), max(0, fps - 1))
    return String(format: "%02d:%02d:%02d:%02d", h, m, s, ff)
  }

  private static func frameNumber(fromTimecode timecode: String, fps: Int) -> Int32 {
    let parts = timecode.split(separator: ":").map(String.init)
    guard parts.count == 4 else { return 0 }
    let h = Int(parts[0]) ?? 0
    let m = Int(parts[1]) ?? 0
    let s = Int(parts[2]) ?? 0
    let f = Int(parts[3]) ?? 0

    let safeFPS = max(1, fps)
    let total = (((h * 60) + m) * 60 + s) * safeFPS + f
    if total <= Int(Int32.min) { return Int32.min }
    if total >= Int(Int32.max) { return Int32.max }
    return Int32(total)
  }

  private static func iso8601UTC(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
  }
}
