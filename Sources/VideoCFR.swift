@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Rewrites a `.mov` in-place to a constant frame rate by re-encoding video on an exact time grid.
/// Audio tracks are passed through as-is (all embedded audio tracks are preserved).
enum VideoCFR {
  struct Cancelled: Error, LocalizedError {
    var errorDescription: String? { "Transcoding cancelled by user" }
  }

  static func rewriteInPlace(
    url: URL,
    fps: Int,
    shouldCancel: @escaping @Sendable () -> Bool = { false },
    cancelHint: String? = nil
  ) async throws {
    let asset = AVURLAsset(url: url)

    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    guard !videoTracks.isEmpty else {
      throw NSError(domain: "VideoCFR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing video track"])
    }
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".capa-cfr-\(UUID().uuidString).mov")

    do {
      try await rewrite(
        asset: asset,
        videoTracks: videoTracks,
        audioTracks: audioTracks,
        outputURL: tmpURL,
        fps: fps,
        shouldCancel: shouldCancel,
        cancelHint: cancelHint
      )
    } catch {
      if error is Cancelled {
        try? FileManager.default.removeItem(at: tmpURL)
      }
      throw error
    }

    let fm = FileManager.default
    _ = try? fm.replaceItemAt(url, withItemAt: tmpURL, backupItemName: nil, options: .usingNewMetadataOnly)
  }

  private static func trackTitle(_ title: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .quickTimeUserDataTrackName
    item.value = title as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }

  // MARK: - Implementation

  private static func rewrite(
    asset: AVAsset,
    videoTracks: [AVAssetTrack],
    audioTracks: [AVAssetTrack],
    outputURL: URL,
    fps: Int,
    shouldCancel: @escaping @Sendable () -> Bool,
    cancelHint: String?
  ) async throws {
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

    let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)

    struct VideoSetup {
      let out: AVAssetReaderTrackOutput
      let input: AVAssetWriterInput
      let adaptor: AVAssetWriterInputPixelBufferAdaptor
    }

    // Label tracks consistently for editors: largest is "Screen", second (if exactly two) is "Camera".
    var videoAreas: [(i: Int, area: Double)] = []
    videoAreas.reserveCapacity(videoTracks.count)
    for (i, t) in videoTracks.enumerated() {
      let size = try await t.load(.naturalSize)
      let xform = try await t.load(.preferredTransform)
      let transformed = size.applying(xform)
      let area = Double(abs(transformed.width) * abs(transformed.height))
      videoAreas.append((i: i, area: area))
    }
    let sortedByArea = videoAreas.sorted { $0.area > $1.area }
    let screenIndex = sortedByArea.first?.i ?? 0
    let cameraIndex: Int? = (sortedByArea.count >= 2) ? sortedByArea[1].i : nil
    let videoTitles: [String] = videoTracks.indices.map { i in
      if i == screenIndex { return "Screen" }
      if let cameraIndex, i == cameraIndex, videoTracks.count == 2 { return "Camera" }
      return "Video \(i + 1)"
    }

    var videoSetups: [VideoSetup] = []
    videoSetups.reserveCapacity(videoTracks.count)

    // Video decode -> pixel buffers, one pipe per video track.
    for (i, track) in videoTracks.enumerated() {
      let videoOutSettings: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
      ]
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: videoOutSettings)
      out.alwaysCopiesSampleData = false
      guard reader.canAdd(out) else {
        throw NSError(domain: "VideoCFR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"])
      }
      reader.add(out)

      // Determine codec from the existing track (preserve codec family).
      let videoFormatDescriptions = try await track.load(.formatDescriptions)
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

      let naturalSize = try await track.load(.naturalSize)
      let preferredTransform = try await track.load(.preferredTransform)
      // Decode outputs pixel buffers in encoded orientation; preserve the original transform metadata.
      let width = Int(abs(naturalSize.width).rounded())
      let height = Int(abs(naturalSize.height).rounded())

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

      let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
      input.expectsMediaDataInRealTime = false
      input.transform = preferredTransform
      input.metadata = [trackTitle(videoTitles[i])]
      guard writer.canAdd(input) else {
        throw NSError(domain: "VideoCFR", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"])
      }
      writer.add(input)

      let adaptorAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: adaptorAttrs)

      videoSetups.append(VideoSetup(out: out, input: input, adaptor: adaptor))
    }

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

    // Timecode passthrough (preserve editor sync metadata).
    struct TimecodePipe {
      let out: AVAssetReaderTrackOutput
      let input: AVAssetWriterInput
    }
    var timecodePipes: [TimecodePipe] = []
    if !timecodeTracks.isEmpty {
      for (i, t) in timecodeTracks.enumerated() {
        let out = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
        out.alwaysCopiesSampleData = false
        if reader.canAdd(out) { reader.add(out) }

        let hint = (try await t.load(.formatDescriptions)).first
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        input.metadata = [trackTitle(timecodeTracks.count == 1 ? "Timecode" : "Timecode \(i + 1)")]
        input.languageCode = (try? await t.load(.languageCode)) ?? nil
        input.extendedLanguageTag = (try? await t.load(.extendedLanguageTag)) ?? nil
        if writer.canAdd(input) {
          writer.add(input)
          timecodePipes.append(TimecodePipe(out: out, input: input))
        }
      }

      if let tcIn = timecodePipes.first?.input {
        for v in videoSetups {
          v.input.addTrackAssociation(withTrackOf: tcIn, type: AVAssetTrack.AssociationType.timecode.rawValue)
        }
      }
    }

    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "VideoCFR", code: 6, userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
    }
    guard writer.startWriting() else {
      throw writer.error ?? NSError(domain: "VideoCFR", code: 7, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start"])
    }

    // Pull first sample for each video track to seed the CFR timeline.
    var firstVideoSamples: [CMSampleBuffer] = []
    firstVideoSamples.reserveCapacity(videoSetups.count)
    for setup in videoSetups {
      guard let first = setup.out.copyNextSampleBuffer() else {
        throw NSError(domain: "VideoCFR", code: 8, userInfo: [NSLocalizedDescriptionKey: "No video samples"])
      }
      firstVideoSamples.append(first)
    }

    // Choose session start as the earliest PTS across video/audio to allow passthrough.
    var minPTS = CMSampleBufferGetPresentationTimeStamp(firstVideoSamples[0])
    for s in firstVideoSamples.dropFirst() {
      let pts = CMSampleBufferGetPresentationTimeStamp(s)
      if pts < minPTS { minPTS = pts }
    }

    var firstAudioSamples: [CMSampleBuffer?] = []
    firstAudioSamples.reserveCapacity(audioPipes.count)
    for pipe in audioPipes {
      let s = pipe.out.copyNextSampleBuffer()
      firstAudioSamples.append(s)
      if let s {
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        if pts < minPTS { minPTS = pts }
      }
    }

    writer.startSession(atSourceTime: minPTS)

    // Append timecode samples synchronously before driving video/audio.
    for p in timecodePipes {
      while let sbuf = p.out.copyNextSampleBuffer() {
        if shouldCancel() {
          throw Cancelled()
        }
        while !p.input.isReadyForMoreMediaData {
          if shouldCancel() {
            throw Cancelled()
          }
          try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !p.input.append(sbuf) {
          throw writer.error ?? NSError(domain: "VideoCFR", code: 25, userInfo: [NSLocalizedDescriptionKey: "Timecode append failed"])
        }
      }
      p.input.markAsFinished()
    }

    let q = DispatchQueue(label: "capa.cfr")

    final class State: @unchecked Sendable {
      let writer: AVAssetWriter
      let reader: AVAssetReader
      let fps: Int
      let startPTS: CMTime
      let endPTS: CMTime
      let shouldCancel: @Sendable () -> Bool

      struct VideoState {
        let out: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        var next: CMSampleBuffer?
        var lastPixel: CVPixelBuffer?
        var nextPTS: CMTime = .invalid
        var frameIndex: Int64 = 0
        var done = false
        var signaled = false
      }

      var videos: [VideoState]

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
        shouldCancel: @escaping @Sendable () -> Bool,
        videoSetups: [VideoSetup],
        firstVideo: [CMSampleBuffer],
        audio: [AudioPipe],
        firstAudio: [CMSampleBuffer?]
      ) {
        self.writer = writer
        self.reader = reader
        self.fps = fps
        self.startPTS = startPTS
        self.endPTS = endPTS
        self.shouldCancel = shouldCancel
        precondition(videoSetups.count == firstVideo.count)
        self.videos = zip(videoSetups, firstVideo).map { setup, first in
          var vs = VideoState(out: setup.out, input: setup.input, adaptor: setup.adaptor, next: first, lastPixel: nil)
          if let pb = CMSampleBufferGetImageBuffer(first) {
            vs.lastPixel = pb
          }
          return vs
        }
        self.audio = audio
        self.nextAudio = firstAudio
        self.audioDone = Array(repeating: false, count: audio.count)
        self.audioSignaled = Array(repeating: false, count: audio.count)
      }

      func failIfNeeded() -> Bool {
        if failure != nil { return true }
        if shouldCancel() {
          failure = Cancelled()
          return true
        }
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

      func stepVideo(i: Int) {
        if videos[i].done { return }
        if failIfNeeded() {
          videos[i].input.markAsFinished()
          videos[i].done = true
          return
        }

        let frameDur = CMTime(value: 1, timescale: CMTimeScale(max(1, min(240, fps))))

        while videos[i].input.isReadyForMoreMediaData {
          if failIfNeeded() { break }

          let t = startPTS + CMTimeMultiply(frameDur, multiplier: Int32(videos[i].frameIndex))
          if t > endPTS {
            videos[i].input.markAsFinished()
            videos[i].done = true
            return
          }

          // Pull forward until nextVideoPTS > t.
          if videos[i].nextPTS == .invalid, let next = videos[i].next {
            videos[i].nextPTS = CMSampleBufferGetPresentationTimeStamp(next)
          }
          while let next = videos[i].next, videos[i].nextPTS <= t {
            if let pb = CMSampleBufferGetImageBuffer(next) {
              videos[i].lastPixel = pb
            }
            videos[i].next = videos[i].out.copyNextSampleBuffer()
            if let n = videos[i].next {
              videos[i].nextPTS = CMSampleBufferGetPresentationTimeStamp(n)
            } else {
              videos[i].nextPTS = .positiveInfinity
              break
            }
          }

          guard let lastPixel = videos[i].lastPixel else {
            // Still nothing decoded; advance.
            videos[i].frameIndex += 1
            continue
          }

          if !videos[i].adaptor.append(lastPixel, withPresentationTime: t) {
            failure = writer.error ?? NSError(domain: "VideoCFR", code: 23, userInfo: [NSLocalizedDescriptionKey: "Video append failed"])
            videos[i].input.markAsFinished()
            videos[i].done = true
            return
          }

          videos[i].frameIndex += 1
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
      shouldCancel: shouldCancel,
      videoSetups: videoSetups,
      firstVideo: firstVideoSamples,
      audio: audioPipes,
      firstAudio: firstAudioSamples
    )

    let progress = ProgressBar(prefix: "", total: totalFramesEstimate, subtitle: cancelHint)
    progress.startIfTTY()

    do {
      try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
        final class AwaitState: @unchecked Sendable {
          let cont: CheckedContinuation<Void, any Error>
          let state: State
          var remaining: Int
          var finished = false
          var cancelTimer: DispatchSourceTimer?

          init(cont: CheckedContinuation<Void, any Error>, state: State, remaining: Int) {
            self.cont = cont
            self.state = state
            self.remaining = remaining
          }
        }

        let awaitState = AwaitState(cont: cont, state: state, remaining: state.videos.count + audioPipes.count)

        let finish: @Sendable (Error?) -> Void = { error in
          guard !awaitState.finished else { return }
          awaitState.finished = true
          awaitState.cancelTimer?.cancel()
          awaitState.cancelTimer = nil
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

        for i in 0..<state.videos.count {
          state.videos[i].input.requestMediaDataWhenReady(on: q) {
            state.stepVideo(i: i)
            progress.update(completed: state.videos.first?.frameIndex ?? 0)
            if let err = state.failure { finish(err); return }
            if state.videos[i].done && !state.videos[i].signaled {
              state.videos[i].signaled = true
              partDone()
            }
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

        awaitState.cancelTimer = DispatchSource.makeTimerSource(queue: q)
        awaitState.cancelTimer?.schedule(deadline: .now(), repeating: .milliseconds(50))
        awaitState.cancelTimer?.setEventHandler {
          if awaitState.finished { return }
          if awaitState.state.failure != nil { return }
          if awaitState.state.shouldCancel() {
            awaitState.state.failure = Cancelled()
            finish(awaitState.state.failure)
          }
        }
        awaitState.cancelTimer?.resume()
      }
    } catch {
      let cancelled = error is Cancelled
      progress.stop(finalSubtitle: cancelled ? "Skipped CFR post-process. Kept original timing." : nil)
      if cancelled {
        reader.cancelReading()
        writer.cancelWriting()
      }
      throw error
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
