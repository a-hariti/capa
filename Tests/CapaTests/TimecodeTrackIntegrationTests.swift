import AVFoundation
import CoreMedia
import XCTest
@testable import capa

final class TimecodeTrackIntegrationTests: XCTestCase {
  func testWritesAssociatedTimecodeTrack() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let url = tempDir.appendingPathComponent("tc.mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let vSettings: [String: Any] = [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 96,
      AVVideoHeightKey: 64,
    ]
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    videoIn.expectsMediaDataInRealTime = false
    XCTAssertTrue(writer.canAdd(videoIn))
    writer.add(videoIn)

    let attrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: 96,
      kCVPixelBufferHeightKey as String: 64,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: attrs)

    let tz = TimeZone(secondsFromGMT: 0)!
    let sync = TimecodeSyncContext(syncID: "sync-int", startDate: Date(timeIntervalSince1970: 12_345), fps: 60, timeZone: tz)
    let tcIn = sync.makeTimecodeWriterInput()
    XCTAssertTrue(writer.canAdd(tcIn))
    writer.add(tcIn)
    videoIn.addTrackAssociation(withTrackOf: tcIn, type: AVAssetTrack.AssociationType.timecode.rawValue)

    XCTAssertTrue(writer.startWriting())
    writer.startSession(atSourceTime: .zero)

    let pts: [CMTime] = [
      .zero,
      CMTime(value: 1, timescale: 60),
      CMTime(value: 2, timescale: 60),
    ]
    for (idx, t) in pts.enumerated() {
      while !videoIn.isReadyForMoreMediaData {
        try await Task.sleep(nanoseconds: 5_000_000)
      }
      let pb = try makePixelBuffer(width: 96, height: 64, shade: UInt8(30 + idx * 50))
      XCTAssertTrue(adaptor.append(pb, withPresentationTime: t))
    }

    let tcDuration = CMTime(value: 3, timescale: 60)
    let tcSample = try sync.makeTimecodeSampleBuffer(presentationTimeStamp: .zero, duration: tcDuration)
    XCTAssertTrue(tcIn.append(tcSample))

    videoIn.markAsFinished()
    tcIn.markAsFinished()
    await withCheckedContinuation { cont in
      writer.finishWriting { cont.resume() }
    }
    XCTAssertEqual(writer.status, .completed)

    let asset = AVURLAsset(url: url)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
    XCTAssertEqual(videoTracks.count, 1)
    XCTAssertEqual(timecodeTracks.count, 1)

    let associated = try await videoTracks[0].loadAssociatedTracks(ofType: .timecode)
    XCTAssertEqual(associated.count, 1)

    let formatDescriptions = try await timecodeTracks[0].load(.formatDescriptions)
    guard let first = formatDescriptions.first else {
      return XCTFail("Missing timecode format description")
    }
    XCTAssertEqual(CMFormatDescriptionGetMediaSubType(first), kCMTimeCodeFormatType_TimeCode32)

    let reader = try AVAssetReader(asset: asset)
    let tcOut = AVAssetReaderTrackOutput(track: timecodeTracks[0], outputSettings: nil)
    tcOut.alwaysCopiesSampleData = false
    XCTAssertTrue(reader.canAdd(tcOut))
    reader.add(tcOut)
    XCTAssertTrue(reader.startReading())
    guard tcOut.copyNextSampleBuffer() != nil else {
      return XCTFail("Missing timecode sample")
    }
  }
}

private func makeTempDir() throws -> URL {
  let base = URL(fileURLWithPath: NSTemporaryDirectory())
  let dir = base.appendingPathComponent("capa-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func makePixelBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
  var pb: CVPixelBuffer?
  let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
  ]
  let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
  guard status == kCVReturnSuccess, let pixelBuffer = pb else {
    throw NSError(domain: "TimecodeTrackIntegrationTests", code: 1)
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
  guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
    throw NSError(domain: "TimecodeTrackIntegrationTests", code: 2)
  }
  memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
  return pixelBuffer
}
