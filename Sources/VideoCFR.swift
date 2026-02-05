@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Rewrites a `.mov` in-place to a constant frame rate by re-encoding video on an exact time grid.
/// Audio tracks are passed through as-is (all embedded audio tracks are preserved).
enum VideoCFR {
  static func rewriteInPlace(url: URL, fps: Int) async throws {
    let asset = AVURLAsset(url: url)

    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw NSError(domain: "VideoCFR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing video track"])
    }
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".capa-cfr-\(UUID().uuidString).mov")

    try await rewrite(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks, outputURL: tmpURL, fps: fps)

    let fm = FileManager.default
    _ = try? fm.removeItem(at: url)
    try fm.moveItem(at: tmpURL, to: url)
  }

  // MARK: - Implementation

  private static func rewrite(
    asset: AVAsset,
    videoTrack: AVAssetTrack,
    audioTracks: [AVAssetTrack],
    outputURL: URL,
    fps: Int
  ) async throws {
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

    // Video decode -> pixel buffers.
    let videoOutSettings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]
    let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutSettings)
    videoOut.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOut) else {
      throw NSError(domain: "VideoCFR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"])
    }
    reader.add(videoOut)

    // Determine codec from the existing track (preserve codec family).
    let videoFormatDescriptions = try await videoTrack.load(.formatDescriptions)
    let videoCodec: AVVideoCodecType = {
      guard let fd = videoFormatDescriptions.first else { return .h264 }
      let sub = CMFormatDescriptionGetMediaSubType(fd)
      return (sub == kCMVideoCodecType_HEVC) ? .hevc : .h264
    }()

    // Use Apple-tuned defaults then let it "breathe" (same approach as live recorder).
    let preset: AVOutputSettingsPreset = (videoCodec == .hevc) ? .hevc3840x2160 : .preset3840x2160
    guard let assistant = AVOutputSettingsAssistant(preset: preset) else {
      throw NSError(domain: "VideoCFR", code: 3, userInfo: [NSLocalizedDescriptionKey: "AVOutputSettingsAssistant unavailable"])
    }

    let naturalSize = try await videoTrack.load(.naturalSize)
    let preferredTransform = try await videoTrack.load(.preferredTransform)
    let transformed = naturalSize.applying(preferredTransform)
    let width = Int(abs(transformed.width).rounded())
    let height = Int(abs(transformed.height).rounded())

    guard var videoSettings = assistant.videoSettings else {
      throw NSError(domain: "VideoCFR", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing assistant video settings"])
    }
    videoSettings[AVVideoWidthKey] = width
    videoSettings[AVVideoHeightKey] = height
    videoSettings[AVVideoCodecKey] = videoCodec
    if var compression = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] {
      compression[kVTCompressionPropertyKey_RealTime as String] = false
      compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false
      compression[AVVideoExpectedSourceFrameRateKey] = max(1, min(240, fps))
      compression[AVVideoMaxKeyFrameIntervalKey] = max(1, min(240, fps)) * 2
      compression[AVVideoAllowFrameReorderingKey] = false

      compression.removeValue(forKey: AVVideoAverageBitRateKey)
      compression.removeValue(forKey: kVTCompressionPropertyKey_AverageBitRate as String)
      compression.removeValue(forKey: kVTCompressionPropertyKey_DataRateLimits as String)
      compression.removeValue(forKey: kVTCompressionPropertyKey_ConstantBitRate as String)
      compression[kVTCompressionPropertyKey_Quality as String] = 1.0
      videoSettings[AVVideoCompressionPropertiesKey] = compression
    }

    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    videoIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn) else {
      throw NSError(domain: "VideoCFR", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"])
    }
    writer.add(videoIn)

    let adaptorAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      kCVPixelBufferWidthKey as String: width,
      kCVPixelBufferHeightKey as String: height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: adaptorAttrs)

    // Audio passthrough: keep all embedded audio tracks exactly as recorded.
    struct AudioPipe {
      let out: AVAssetReaderTrackOutput
      let input: AVAssetWriterInput
    }
    var audioPipes: [AudioPipe] = []
    for track in audioTracks {
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      out.alwaysCopiesSampleData = false
      if reader.canAdd(out) { reader.add(out) }

      let hint = (try await track.load(.formatDescriptions)).first
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
      input.expectsMediaDataInRealTime = false
      input.languageCode = (try? await track.load(.languageCode)) ?? nil
      input.extendedLanguageTag = (try? await track.load(.extendedLanguageTag)) ?? nil
      if writer.canAdd(input) {
        writer.add(input)
        audioPipes.append(AudioPipe(out: out, input: input))
      }
    }

    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "VideoCFR", code: 6, userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
    }
    guard writer.startWriting() else {
      throw writer.error ?? NSError(domain: "VideoCFR", code: 7, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start"])
    }

    // Choose session start as the earliest PTS across video/audio to allow passthrough.
    let firstVideo = videoOut.copyNextSampleBuffer()
    guard let firstVideo else {
      throw NSError(domain: "VideoCFR", code: 8, userInfo: [NSLocalizedDescriptionKey: "No video samples"])
    }
    let firstVideoPTS = CMSampleBufferGetPresentationTimeStamp(firstVideo)

    var firstAudioSamples: [CMSampleBuffer?] = []
    firstAudioSamples.reserveCapacity(audioPipes.count)
    var minPTS = firstVideoPTS
    for pipe in audioPipes {
      let s = pipe.out.copyNextSampleBuffer()
      firstAudioSamples.append(s)
      if let s {
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        if pts < minPTS { minPTS = pts }
      }
    }

    writer.startSession(atSourceTime: minPTS)

    let q = DispatchQueue(label: "capa.cfr")

    final class State: @unchecked Sendable {
      let writer: AVAssetWriter
      let reader: AVAssetReader
      let fps: Int
      let startPTS: CMTime
      let endPTS: CMTime

      let videoOut: AVAssetReaderTrackOutput
      let videoIn: AVAssetWriterInput
      let adaptor: AVAssetWriterInputPixelBufferAdaptor

      var nextVideo: CMSampleBuffer?
      var lastPixel: CVPixelBuffer?
      var nextVideoPTS: CMTime = .invalid
      var frameIndex: Int64 = 0
      var videoDone = false

      var audio: [AudioPipe]
      var nextAudio: [CMSampleBuffer?]
      var audioDone: [Bool]
      var audioSignaled: [Bool]

      var videoSignaled = false
      var failure: Error?

      init(
        writer: AVAssetWriter,
        reader: AVAssetReader,
        fps: Int,
        startPTS: CMTime,
        endPTS: CMTime,
        videoOut: AVAssetReaderTrackOutput,
        videoIn: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        firstVideo: CMSampleBuffer,
        audio: [AudioPipe],
        firstAudio: [CMSampleBuffer?]
      ) {
        self.writer = writer
        self.reader = reader
        self.fps = fps
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.videoOut = videoOut
        self.videoIn = videoIn
        self.adaptor = adaptor
        self.nextVideo = firstVideo
        if let pb = CMSampleBufferGetImageBuffer(firstVideo) {
          self.lastPixel = pb
        }
        self.audio = audio
        self.nextAudio = firstAudio
        self.audioDone = Array(repeating: false, count: audio.count)
        self.audioSignaled = Array(repeating: false, count: audio.count)
      }

      func failIfNeeded() -> Bool {
        if failure != nil { return true }
        if writer.status == .failed {
          failure = writer.error ?? NSError(domain: "VideoCFR", code: 20, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
          return true
        }
        if reader.status == .failed {
          failure = reader.error ?? NSError(domain: "VideoCFR", code: 21, userInfo: [NSLocalizedDescriptionKey: "Reader failed"])
          return true
        }
        return false
      }

      func stepAudio(i: Int) {
        if audioDone[i] { return }
        if failIfNeeded() {
          audio[i].input.markAsFinished()
          audioDone[i] = true
          return
        }
        let input = audio[i].input
        let out = audio[i].out
        while input.isReadyForMoreMediaData {
          if failIfNeeded() { break }
          let sbuf: CMSampleBuffer?
          if let pre = nextAudio[i] {
            sbuf = pre
            nextAudio[i] = nil
          } else {
            sbuf = out.copyNextSampleBuffer()
          }
          guard let sbuf else {
            input.markAsFinished()
            audioDone[i] = true
            return
          }
          if !input.append(sbuf) {
            failure = writer.error ?? NSError(domain: "VideoCFR", code: 22, userInfo: [NSLocalizedDescriptionKey: "Audio append failed"])
            input.markAsFinished()
            audioDone[i] = true
            return
          }
        }
      }

      func stepVideo() {
        if videoDone { return }
        if failIfNeeded() {
          videoIn.markAsFinished()
          videoDone = true
          return
        }

        let frameDur = CMTime(value: 1, timescale: CMTimeScale(max(1, min(240, fps))))

        while videoIn.isReadyForMoreMediaData {
          if failIfNeeded() { break }

          let t = startPTS + CMTimeMultiply(frameDur, multiplier: Int32(frameIndex))
          if t > endPTS {
            videoIn.markAsFinished()
            videoDone = true
            return
          }

          // Pull forward until nextVideoPTS > t.
          if nextVideoPTS == .invalid, let nextVideo {
            nextVideoPTS = CMSampleBufferGetPresentationTimeStamp(nextVideo)
          }
          while let next = nextVideo, nextVideoPTS <= t {
            if let pb = CMSampleBufferGetImageBuffer(next) {
              lastPixel = pb
            }
            nextVideo = videoOut.copyNextSampleBuffer()
            if let nextVideo {
              nextVideoPTS = CMSampleBufferGetPresentationTimeStamp(nextVideo)
            } else {
              nextVideoPTS = .positiveInfinity
              break
            }
          }

          guard let lastPixel else {
            // Still nothing decoded; advance.
            frameIndex += 1
            continue
          }

          if !adaptor.append(lastPixel, withPresentationTime: t) {
            failure = writer.error ?? NSError(domain: "VideoCFR", code: 23, userInfo: [NSLocalizedDescriptionKey: "Video append failed"])
            videoIn.markAsFinished()
            videoDone = true
            return
          }

          frameIndex += 1
        }
      }
    }

    // End time: use the asset duration relative to 0; session is anchored at minPTS.
    let duration = try await asset.load(.duration)
    let endPTS = minPTS + duration
    let durationSeconds = max(0.0, duration.seconds)
    let totalFramesEstimate = Int64(max(1.0, ceil(durationSeconds * Double(fps))))

    let state = State(
      writer: writer,
      reader: reader,
      fps: fps,
      startPTS: minPTS,
      endPTS: endPTS,
      videoOut: videoOut,
      videoIn: videoIn,
      adaptor: adaptor,
      firstVideo: firstVideo,
      audio: audioPipes,
      firstAudio: firstAudioSamples
    )

    let progress = ProgressBar(prefix: "Transcoding", total: totalFramesEstimate)
    progress.startIfTTY()

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      final class AwaitState: @unchecked Sendable {
        let cont: CheckedContinuation<Void, any Error>
        let state: State
        var remaining: Int
        var finished = false

        init(cont: CheckedContinuation<Void, any Error>, state: State, remaining: Int) {
          self.cont = cont
          self.state = state
          self.remaining = remaining
        }
      }

      let awaitState = AwaitState(cont: cont, state: state, remaining: 1 + audioPipes.count)

      let finish: @Sendable (Error?) -> Void = { error in
        guard !awaitState.finished else { return }
        awaitState.finished = true
        if let error {
          awaitState.cont.resume(throwing: error)
        } else {
          awaitState.cont.resume(returning: ())
        }
      }

      let partDone: @Sendable () -> Void = {
        awaitState.remaining -= 1
        if awaitState.remaining <= 0 {
          finish(awaitState.state.failure)
        }
      }

      state.videoIn.requestMediaDataWhenReady(on: q) {
        state.stepVideo()
        progress.update(completed: state.frameIndex)
        if let err = state.failure { finish(err); return }
        if state.videoDone, !state.videoSignaled {
          state.videoSignaled = true
          partDone()
        }
      }

      for i in 0..<state.audio.count {
        state.audio[i].input.requestMediaDataWhenReady(on: q) {
          state.stepAudio(i: i)
          if let err = state.failure { finish(err); return }
          if state.audioDone[i] && !state.audioSignaled[i] {
            state.audioSignaled[i] = true
            partDone()
          }
        }
      }
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      writer.finishWriting { cont.resume(returning: ()) }
    }

    progress.stop()

    if writer.status == .failed {
      throw writer.error ?? NSError(domain: "VideoCFR", code: 24, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
    }
  }
}

final class ProgressBar: @unchecked Sendable {
  private let fd: UnsafeMutablePointer<FILE> = stderr
  private let prefix: String
  private let total: Int64
  private var lastLen = 0
  private var active = false

  init(prefix: String, total: Int64) {
    self.prefix = prefix
    self.total = max(1, total)
  }

  func startIfTTY() {
    guard isatty(fileno(fd)) != 0 else { return }
    active = true
    write("\u{001B}[?25l") // hide cursor
  }

  func update(completed: Int64) {
    guard active else { return }
    let clamped = max(0, min(total, completed))
    let pct = Int((Double(clamped) / Double(total)) * 100.0)
    let width = 24
    let filled = Int((Double(width) * Double(clamped)) / Double(total))
    let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: max(0, width - filled))
    let s = "\(prefix) [\(bar)] \(pct)%"
    let pad = max(0, lastLen - s.utf8.count)
    lastLen = s.utf8.count
    write("\r" + s + String(repeating: " ", count: pad))
  }

  func stop() {
    guard active else { return }
    active = false
    write("\r" + String(repeating: " ", count: max(0, lastLen)) + "\r")
    write("\u{001B}[?25h\n") // show cursor + newline
  }

  private func write(_ s: String) {
    s.withCString { cstr in
      fputs(cstr, fd)
      fflush(fd)
    }
  }
}
