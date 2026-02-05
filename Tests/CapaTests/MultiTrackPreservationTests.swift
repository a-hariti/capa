import AVFoundation
import CoreMedia
import XCTest
@testable import capa

final class MultiTrackPreservationTests: XCTestCase {
  func testPostProcessAndCFRPreserveMultipleVideoTracks() async throws {
    let tempDir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let url = tempDir.appendingPathComponent("multi.mov")
    try writeMultiTrackMovie(url: url)

    // Sanity: the source movie has 2 video + 2 audio tracks.
    do {
      let asset = AVURLAsset(url: url)
      let videos = try await asset.loadTracks(withMediaType: .video)
      let audios = try await asset.loadTracks(withMediaType: .audio)
      XCTAssertEqual(videos.count, 2)
      XCTAssertEqual(audios.count, 2)
    }

    // Post-process adds master audio but must preserve all video tracks.
    try await PostProcess.addMasterAudioTrackIfNeeded(url: url, includeSystemAudio: true, includeMicrophone: true)
    do {
      let asset = AVURLAsset(url: url)
      let videos = try await asset.loadTracks(withMediaType: .video)
      let audios = try await asset.loadTracks(withMediaType: .audio)
      XCTAssertEqual(videos.count, 2)
      XCTAssertEqual(audios.count, 3) // mic + system + master
    }

    // CFR rewrite must also preserve multiple video tracks (and all audio tracks).
    try await VideoCFR.rewriteInPlace(url: url, fps: 60)
    do {
      let asset = AVURLAsset(url: url)
      let videos = try await asset.loadTracks(withMediaType: .video)
      let audios = try await asset.loadTracks(withMediaType: .audio)
      XCTAssertEqual(videos.count, 2)
      XCTAssertEqual(audios.count, 3)
    }
  }
}

private func makeTempDir() throws -> URL {
  let base = URL(fileURLWithPath: NSTemporaryDirectory())
  let dir = base.appendingPathComponent("capa-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func writeMultiTrackMovie(url: URL) throws {
  let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

  // Video 1 (screen-ish): 160x90.
  let v1Settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 160,
    AVVideoHeightKey: 90,
  ]
  let v1In = AVAssetWriterInput(mediaType: .video, outputSettings: v1Settings)
  v1In.expectsMediaDataInRealTime = false
  let v1Attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: 160,
    kCVPixelBufferHeightKey as String: 90,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
  ]
  let v1Ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v1In, sourcePixelBufferAttributes: v1Attrs)

  // Video 2 (camera-ish): 80x60.
  let v2Settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 80,
    AVVideoHeightKey: 60,
  ]
  let v2In = AVAssetWriterInput(mediaType: .video, outputSettings: v2Settings)
  v2In.expectsMediaDataInRealTime = false
  let v2Attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: 80,
    kCVPixelBufferHeightKey as String: 60,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
  ]
  let v2Ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v2In, sourcePixelBufferAttributes: v2Attrs)

  // Two PCM audio tracks (float interleaved), 48kHz stereo.
  let sampleRate: Double = 48_000
  let channels = 2
  let aSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: channels,
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsBigEndianKey: false,
    AVLinearPCMIsNonInterleaved: false,
  ]
  let a1In = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
  a1In.expectsMediaDataInRealTime = false
  let a2In = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
  a2In.expectsMediaDataInRealTime = false

  for input in [v1In, v2In, a1In, a2In] {
    guard writer.canAdd(input) else {
      throw NSError(domain: "MultiTrackPreservationTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add writer input"])
    }
    writer.add(input)
  }

  guard writer.startWriting() else {
    throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "startWriting failed"])
  }
  writer.startSession(atSourceTime: .zero)

  // Write ~0.5s of video with a few irregular PTS so CFR has to do work.
  let vPTS: [CMTime] = [
    .zero,
    CMTime(seconds: 0.05, preferredTimescale: 600),
    CMTime(seconds: 0.20, preferredTimescale: 600),
    CMTime(seconds: 0.33, preferredTimescale: 600),
  ]
  for (i, t) in vPTS.enumerated() {
    while !v1In.isReadyForMoreMediaData || !v2In.isReadyForMoreMediaData {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    let pb1 = try makePixelBuffer(width: 160, height: 90, shade: UInt8(40 + i * 30))
    let pb2 = try makePixelBuffer(width: 80, height: 60, shade: UInt8(100 + i * 20))
    guard v1Ad.append(pb1, withPresentationTime: t) else {
      throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "append v1 failed"])
    }
    guard v2Ad.append(pb2, withPresentationTime: t) else {
      throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "append v2 failed"])
    }
  }

  // Write 1s of audio in 1024-frame chunks so PostProcess has enough data to mix.
  var audioPTS = CMTime.zero
  let framesPerChunk = 1024
  let chunkDur = CMTime(value: CMTimeValue(framesPerChunk), timescale: CMTimeScale(sampleRate))
  for chunkIndex in 0..<Int((sampleRate / Double(framesPerChunk)).rounded(.up)) {
    _ = chunkIndex
    while !a1In.isReadyForMoreMediaData || !a2In.isReadyForMoreMediaData {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
    // Track 1: low amplitude, Track 2: higher amplitude (just to differ).
    let a1 = try makePCMSampleBuffer(
      pts: audioPTS,
      frames: framesPerChunk,
      channels: channels,
      sampleRate: sampleRate,
      amplitude: 0.05
    )
    let a2 = try makePCMSampleBuffer(
      pts: audioPTS,
      frames: framesPerChunk,
      channels: channels,
      sampleRate: sampleRate,
      amplitude: 0.20
    )
    guard a1In.append(a1) else {
      throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "append a1 failed"])
    }
    guard a2In.append(a2) else {
      throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "append a2 failed"])
    }
    audioPTS = audioPTS + chunkDur
  }

  v1In.markAsFinished()
  v2In.markAsFinished()
  a1In.markAsFinished()
  a2In.markAsFinished()

  let sema = DispatchSemaphore(value: 0)
  writer.finishWriting { sema.signal() }
  sema.wait()

  if writer.status == .failed {
    throw writer.error ?? NSError(domain: "MultiTrackPreservationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
  }
}

private func makePixelBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
  var pb: CVPixelBuffer?
  let attrs: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
  ]
  let status = CVPixelBufferCreate(
    kCFAllocatorDefault,
    width,
    height,
    kCVPixelFormatType_32BGRA,
    attrs as CFDictionary,
    &pb
  )
  guard status == kCVReturnSuccess, let pixelBuffer = pb else {
    throw NSError(domain: "MultiTrackPreservationTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
  }

  CVPixelBufferLockBaseAddress(pixelBuffer, [])
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

  guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
    throw NSError(domain: "MultiTrackPreservationTests", code: 11, userInfo: [NSLocalizedDescriptionKey: "No base address"])
  }
  let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
  memset(base, Int32(shade), bytesPerRow * height)
  return pixelBuffer
}

private func makePCMSampleBuffer(
  pts: CMTime,
  frames: Int,
  channels: Int,
  sampleRate: Double,
  amplitude: Float
) throws -> CMSampleBuffer {
  var asbd = AudioStreamBasicDescription(
    mSampleRate: sampleRate,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kLinearPCMFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
    mFramesPerPacket: 1,
    mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
    mChannelsPerFrame: UInt32(channels),
    mBitsPerChannel: 32,
    mReserved: 0
  )

  var fmt: CMAudioFormatDescription?
  let stDesc = CMAudioFormatDescriptionCreate(
    allocator: kCFAllocatorDefault,
    asbd: &asbd,
    layoutSize: 0,
    layout: nil,
    magicCookieSize: 0,
    magicCookie: nil,
    extensions: nil,
    formatDescriptionOut: &fmt
  )
  guard stDesc == noErr, let fmt else {
    throw NSError(domain: "MultiTrackPreservationTests", code: 20, userInfo: [NSLocalizedDescriptionKey: "CMAudioFormatDescriptionCreate failed"])
  }

  // Interleaved float stereo frames.
  var samples = Array(repeating: Float(0), count: frames * channels)
  for i in 0..<frames {
    let v = amplitude * sin(Float(i) * 0.01)
    for c in 0..<channels { samples[i * channels + c] = v }
  }

  let dataLen = samples.count * MemoryLayout<Float>.size
  var block: CMBlockBuffer?
  let stBlock = CMBlockBufferCreateWithMemoryBlock(
    allocator: kCFAllocatorDefault,
    memoryBlock: nil,
    blockLength: dataLen,
    blockAllocator: kCFAllocatorDefault,
    customBlockSource: nil,
    offsetToData: 0,
    dataLength: dataLen,
    flags: 0,
    blockBufferOut: &block
  )
  guard stBlock == kCMBlockBufferNoErr, let block else {
    throw NSError(domain: "MultiTrackPreservationTests", code: 21, userInfo: [NSLocalizedDescriptionKey: "CMBlockBufferCreateWithMemoryBlock failed"])
  }

  samples.withUnsafeBytes { bytes in
    _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataLen)
  }

  let dur = CMTime(value: 1, timescale: CMTimeScale(sampleRate))
  var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
  var sbuf: CMSampleBuffer?
  let st = CMSampleBufferCreateReady(
    allocator: kCFAllocatorDefault,
    dataBuffer: block,
    formatDescription: fmt,
    sampleCount: frames,
    sampleTimingEntryCount: 1,
    sampleTimingArray: &timing,
    sampleSizeEntryCount: 0,
    sampleSizeArray: nil,
    sampleBufferOut: &sbuf
  )
  guard st == noErr, let sbuf else {
    throw NSError(domain: "MultiTrackPreservationTests", code: 22, userInfo: [NSLocalizedDescriptionKey: "CMSampleBufferCreateReady failed"])
  }
  return sbuf
}
