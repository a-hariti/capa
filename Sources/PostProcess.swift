@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Post-processes a recorded `.mov` to add a "Master" audio track that is the mix of all source tracks,
/// while also preserving per-source tracks (re-encoded as AAC for consistency).
///
/// Why: some players (QuickTime) only play one audio track at a time. Keeping per-source tracks enables
/// editing control, while the master provides a convenient default.
enum PostProcess {
  struct AudioPlan {
    /// (track, label)
    var sources: [(AVAssetTrack, String)]
    var wantsMaster: Bool
  }

  static func planForTracks(_ tracks: [AVAssetTrack], includeSystemAudio: Bool, includeMicrophone: Bool) -> AudioPlan {
    // Our capture writer creates audio tracks in this order:
    // 1) microphone (if enabled)
    // 2) system audio (if enabled)
    //
    // When only one is enabled, there's only one audio track.
    var sources: [(AVAssetTrack, String)] = []
    var i = 0
    if includeMicrophone, i < tracks.count {
      sources.append((tracks[i], "Microphone"))
      i += 1
    }
    if includeSystemAudio, i < tracks.count {
      sources.append((tracks[i], "System Audio"))
      i += 1
    }

    // If the above mapping didn't match (e.g. older files), fall back to generic labels.
    if sources.isEmpty && !tracks.isEmpty {
      sources = tracks.enumerated().map { ($0.element, "Audio \($0.offset + 1)") }
    }

    return AudioPlan(sources: sources, wantsMaster: !sources.isEmpty)
  }

  static func addMasterAudioTrackIfNeeded(
    url: URL,
    includeSystemAudio: Bool,
    includeMicrophone: Bool
  ) async throws {
    let asset = AVURLAsset(url: url)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let plan = planForTracks(audioTracks, includeSystemAudio: includeSystemAudio, includeMicrophone: includeMicrophone)
    guard plan.wantsMaster else { return }
    // If there's only one source track, skip the master mix and keep the original audio as-is.
    guard plan.sources.count > 1 else { return }

    let tmpURL = url.deletingLastPathComponent()
      .appendingPathComponent(".capa-tmp-\(UUID().uuidString).mov")

    try await rewriteWithMasterAudio(asset: asset, plan: plan, outputURL: tmpURL)

    // Atomic-ish replace on same volume.
    let fm = FileManager.default
    _ = try? fm.replaceItemAt(url, withItemAt: tmpURL, backupItemName: nil, options: .usingNewMetadataOnly)
  }

  // MARK: - Implementation

  private static func rewriteWithMasterAudio(asset: AVAsset, plan: AudioPlan, outputURL: URL) async throws {
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw NSError(domain: "PostProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing video track"])
    }

    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

    // Video passthrough to preserve sharpness and exact encoding.
    let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoOut.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOut) else {
      throw NSError(domain: "PostProcess", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add video reader output"])
    }
    reader.add(videoOut)

    let fds = try await videoTrack.load(.formatDescriptions)
    let videoHint = fds.first
    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoHint)
    videoIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoIn) else {
      throw NSError(domain: "PostProcess", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video writer input"])
    }
    writer.add(videoIn)

    // Decode audio to a common PCM format for mixing and re-encode sources + master to AAC.
    let sampleRate: Double = 48_000
    let channels: Int = 2
    let pcmSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let aacSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channels,
      AVEncoderBitRateKey: 160_000,
    ]

    // Prefer "original" audio first (system audio if present, then microphone).
    let orderedSources = plan.sources.sorted { a, b in
      let aIsSystem = (a.1 == "System Audio")
      let bIsSystem = (b.1 == "System Audio")
      if aIsSystem != bIsSystem { return aIsSystem }
      return a.1 < b.1
    }

    var sourceAudio: [(label: String, out: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
    for (track, label) in orderedSources {
      let out = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
      out.alwaysCopiesSampleData = false
      guard reader.canAdd(out) else {
        throw NSError(domain: "PostProcess", code: 10, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio reader output (\(label))"])
      }
      reader.add(out)

      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
      input.expectsMediaDataInRealTime = false
      input.metadata = [trackTitle(label)]
      if label == "System Audio" {
        input.languageCode = "qab"
        input.extendedLanguageTag = "qab-x-capa-system"
      } else {
        input.languageCode = "qac"
        input.extendedLanguageTag = "qac-x-capa-mic"
      }
      guard writer.canAdd(input) else {
        throw NSError(domain: "PostProcess", code: 11, userInfo: [NSLocalizedDescriptionKey: "Cannot add audio writer input (\(label))"])
      }
      writer.add(input)
      sourceAudio.append((label: label, out: out, input: input))
    }

    // Add master last; it's primarily a reference mix for alignment in post.
    let masterIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
    masterIn.expectsMediaDataInRealTime = false
    masterIn.metadata = [trackTitle("Master (Mixed)")]
    masterIn.languageCode = "qaa"
    masterIn.extendedLanguageTag = "qaa-x-capa-master"
    guard writer.canAdd(masterIn) else {
      throw NSError(domain: "PostProcess", code: 12, userInfo: [NSLocalizedDescriptionKey: "Cannot add master audio input"])
    }
    writer.add(masterIn)

    guard reader.startReading() else {
      throw reader.error ?? NSError(domain: "PostProcess", code: 20, userInfo: [NSLocalizedDescriptionKey: "Reader failed to start"])
    }
    guard writer.startWriting() else {
      throw writer.error ?? NSError(domain: "PostProcess", code: 21, userInfo: [NSLocalizedDescriptionKey: "Writer failed to start"])
    }
    // Choose session start as the earliest PTS across video/audio to preserve offsets.
    guard let firstVideo = videoOut.copyNextSampleBuffer() else {
      throw NSError(domain: "PostProcess", code: 22, userInfo: [NSLocalizedDescriptionKey: "No video samples"])
    }
    var firstAudio: [CMSampleBuffer?] = []
    firstAudio.reserveCapacity(sourceAudio.count)
    var minPTS = CMSampleBufferGetPresentationTimeStamp(firstVideo)
    for src in sourceAudio {
      let s = src.out.copyNextSampleBuffer()
      firstAudio.append(s)
      if let s {
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        if pts < minPTS { minPTS = pts }
      }
    }
    writer.startSession(atSourceTime: minPTS)

    // Drive writer readiness the idiomatic way (Apple docs): requestMediaDataWhenReady.
    // We coordinate all tracks from a single serial queue.
    let q = DispatchQueue(label: "capa.postprocess")

    final class Driver: @unchecked Sendable {
      struct Segment {
        var start: Int64
        var frames: Int
        var data: [Float]
      }

      struct AudioSource {
        var label: String
        var out: AVAssetReaderTrackOutput
        var input: AVAssetWriterInput
        var seed: CMSampleBuffer?
        var pending: [CMSampleBuffer] = []
        var segments: [Segment] = []
        var readEnd: Int64 = 0
        var finishedReading = false
      }

      let writer: AVAssetWriter
      let videoOut: AVAssetReaderTrackOutput
      let videoIn: AVAssetWriterInput
      var sources: [AudioSource]
      let masterIn: AVAssetWriterInput
      let sampleRate: Int
      let channels: Int
      let chunkFrames: Int = 1024
      let srScale: CMTimeScale
      let perSampleDuration: CMTime

      var masterIndex: Int64 = 0
      var audioDone = false
      var videoDone = false
      var audioSignaled = false
      var videoSignaled = false
      var failure: Error?
      var pendingVideo: CMSampleBuffer?

      init(
        writer: AVAssetWriter,
        videoOut: AVAssetReaderTrackOutput,
        videoIn: AVAssetWriterInput,
        sources: [(label: String, out: AVAssetReaderTrackOutput, input: AVAssetWriterInput)],
        masterIn: AVAssetWriterInput,
        sampleRate: Int,
        channels: Int,
        firstVideo: CMSampleBuffer?,
        firstAudio: [CMSampleBuffer?]
      ) {
        self.writer = writer
        self.videoOut = videoOut
        self.videoIn = videoIn
        self.sources = sources.map { AudioSource(label: $0.label, out: $0.out, input: $0.input) }
        self.masterIn = masterIn
        self.sampleRate = sampleRate
        self.channels = channels
        self.srScale = CMTimeScale(sampleRate)
        self.perSampleDuration = CMTime(value: 1, timescale: self.srScale)
        self.pendingVideo = firstVideo
        for (i, s) in firstAudio.enumerated() where i < self.sources.count {
          self.sources[i].seed = s
        }
      }

      func ptsToSamples(_ pts: CMTime) -> Int64 {
        CMTimeConvertScale(pts, timescale: srScale, method: .roundHalfAwayFromZero).value
      }

      func extractFloats(_ sbuf: CMSampleBuffer) throws -> [Float] {
        var block: CMBlockBuffer?
        var abl = AudioBufferList(mNumberBuffers: 0, mBuffers: AudioBuffer())
        var sizeNeeded: Int = 0
        let st = withUnsafeMutablePointer(to: &abl) { ablPtr in
          withUnsafeMutablePointer(to: &block) { blockPtr in
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
              sbuf,
              bufferListSizeNeededOut: &sizeNeeded,
              bufferListOut: ablPtr,
              bufferListSize: MemoryLayout<AudioBufferList>.size,
              blockBufferAllocator: kCFAllocatorDefault,
              blockBufferMemoryAllocator: kCFAllocatorDefault,
              flags: 0,
              blockBufferOut: blockPtr
            )
          }
        }
        guard st == noErr else {
          throw NSError(domain: "PostProcess", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Failed to extract audio buffer list"])
        }
        guard abl.mNumberBuffers == 1 else {
          throw NSError(domain: "PostProcess", code: 62, userInfo: [NSLocalizedDescriptionKey: "Unexpected non-interleaved audio"])
        }
        let buf = abl.mBuffers
        guard let mData = buf.mData else { return [] }
        let floatCount = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
        let ptr = mData.bindMemory(to: Float.self, capacity: floatCount)
        return Array(UnsafeBufferPointer(start: ptr, count: floatCount))
      }

      func makePCMSampleBuffer(startIndex: Int64, frames: Int, samples: [Float]) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
          mSampleRate: Float64(sampleRate),
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
          throw NSError(domain: "PostProcess", code: Int(stDesc), userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format description"])
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
          throw NSError(domain: "PostProcess", code: Int(stBlock), userInfo: [NSLocalizedDescriptionKey: "Failed to create block buffer"])
        }

        samples.withUnsafeBytes { bytes in
          _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: dataLen)
        }

        var timing = CMSampleTimingInfo(
          duration: perSampleDuration,
          presentationTimeStamp: CMTime(value: startIndex, timescale: srScale),
          decodeTimeStamp: .invalid
        )
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
          throw NSError(domain: "PostProcess", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "Failed to create audio sample buffer"])
        }
        return sbuf
      }

      func failIfNeeded() -> Bool {
        if failure != nil { return true }
        if writer.status == .failed {
          failure = writer.error ?? NSError(domain: "PostProcess", code: 24, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
          return true
        }
        return false
      }

      func readMoreAudioIfNeeded() throws {
        for i in sources.indices {
          if sources[i].finishedReading { continue }
          if sources[i].pending.count >= 32 { continue }
          let sbuf: CMSampleBuffer?
          if let seed = sources[i].seed {
            sbuf = seed
            sources[i].seed = nil
          } else {
            sbuf = sources[i].out.copyNextSampleBuffer()
          }
          if let sbuf {
            sources[i].pending.append(sbuf)
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            let start = ptsToSamples(pts)
            let frames = CMSampleBufferGetNumSamples(sbuf)
            if frames > 0 {
              let floats = try extractFloats(sbuf)
              sources[i].segments.append(Segment(start: start, frames: frames, data: floats))
              sources[i].readEnd = max(sources[i].readEnd, start + Int64(frames))
            }
          } else {
            sources[i].finishedReading = true
          }
        }
      }

      func popExpiredSegments(for i: Int, before startIndex: Int64) {
        while let first = sources[i].segments.first {
          let end = first.start + Int64(first.frames)
          if end <= startIndex { sources[i].segments.removeFirst() } else { break }
        }
      }

      func mixChunk(startIndex: Int64, frames: Int) -> [Float] {
        var out = Array(repeating: Float(0), count: frames * channels)
        let gain = 1.0 / Float(max(1, sources.count))
        for i in sources.indices {
          popExpiredSegments(for: i, before: startIndex)
          var remainingFrames = frames
          var dstFrame = 0
          var segIdx = 0
          while remainingFrames > 0 {
            guard segIdx < sources[i].segments.count else { break }
            let seg = sources[i].segments[segIdx]
            let segEnd = seg.start + Int64(seg.frames)
            let here = startIndex + Int64(dstFrame)
            if here < seg.start {
              let gapFrames = Int(min(Int64(remainingFrames), seg.start - here))
              dstFrame += gapFrames
              remainingFrames -= gapFrames
              continue
            }
            if here >= segEnd {
              segIdx += 1
              continue
            }
            let segOffset = Int(here - seg.start)
            let avail = seg.frames - segOffset
            let use = min(remainingFrames, avail)
            let srcBase = segOffset * channels
            let dstBase = dstFrame * channels
            for s in 0..<(use * channels) {
              out[dstBase + s] += seg.data[srcBase + s] * gain
            }
            dstFrame += use
            remainingFrames -= use
          }
        }
        for i in out.indices {
          if out[i] > 1 { out[i] = 1 }
          else if out[i] < -1 { out[i] = -1 }
        }
        return out
      }

      func minReadEnd() -> Int64 {
        sources.map(\.readEnd).min() ?? 0
      }

      func maxReadEnd() -> Int64 {
        sources.map(\.readEnd).max() ?? 0
      }

      func tryAppendPendingSources() {
        for i in sources.indices {
          guard sources[i].input.isReadyForMoreMediaData else { continue }
          guard let sbuf = sources[i].pending.first else { continue }
          if sources[i].input.append(sbuf) {
            sources[i].pending.removeFirst()
          } else {
            failure = writer.error ?? NSError(domain: "PostProcess", code: 31, userInfo: [NSLocalizedDescriptionKey: "Audio append failed (\(sources[i].label))"])
            return
          }
        }
      }

      func tryEmitMaster() throws {
        guard masterIn.isReadyForMoreMediaData else { return }
        let readyEnd = minReadEnd()
        while masterIndex + Int64(chunkFrames) <= readyEnd && masterIn.isReadyForMoreMediaData {
          let mixed = mixChunk(startIndex: masterIndex, frames: chunkFrames)
          let sbuf = try makePCMSampleBuffer(startIndex: masterIndex, frames: chunkFrames, samples: mixed)
          if !masterIn.append(sbuf) {
            failure = writer.error ?? NSError(domain: "PostProcess", code: 70, userInfo: [NSLocalizedDescriptionKey: "Master audio append failed"])
            return
          }
          masterIndex += Int64(chunkFrames)
        }
      }

      func finalizeAudioIfDone() throws -> Bool {
        let allRead = sources.allSatisfy { $0.finishedReading }
        let allPendingAppended = sources.allSatisfy { $0.pending.isEmpty }
        if !allRead || !allPendingAppended { return false }

        let maxEnd = maxReadEnd()
        while masterIndex < maxEnd && masterIn.isReadyForMoreMediaData {
          let frames = Int(min(Int64(chunkFrames), maxEnd - masterIndex))
          let mixed = mixChunk(startIndex: masterIndex, frames: frames)
          let sbuf = try makePCMSampleBuffer(startIndex: masterIndex, frames: frames, samples: mixed)
          if !masterIn.append(sbuf) {
            failure = writer.error ?? NSError(domain: "PostProcess", code: 71, userInfo: [NSLocalizedDescriptionKey: "Master audio append failed (tail)"])
            return false
          }
          masterIndex += Int64(frames)
        }

        if masterIndex >= maxEnd {
          for i in sources.indices { sources[i].input.markAsFinished() }
          masterIn.markAsFinished()
          audioDone = true
          return true
        }
        return false
      }

      func stepAudio() {
        if audioDone { return }
        if failIfNeeded() {
          for i in sources.indices { sources[i].input.markAsFinished() }
          masterIn.markAsFinished()
          audioDone = true
          return
        }
        do {
          try readMoreAudioIfNeeded()
          try tryEmitMaster()
          tryAppendPendingSources()
          _ = try finalizeAudioIfDone()
        } catch {
          failure = error
        }
      }

      func stepVideo() {
        if videoDone { return }
        if failIfNeeded() {
          videoIn.markAsFinished()
          videoDone = true
          return
        }
        while videoIn.isReadyForMoreMediaData {
          if failIfNeeded() { break }
          let sbuf: CMSampleBuffer?
          if let pendingVideo {
            sbuf = pendingVideo
            self.pendingVideo = nil
          } else {
            sbuf = videoOut.copyNextSampleBuffer()
          }
          guard let sbuf else {
            videoIn.markAsFinished()
            videoDone = true
            return
          }
          if !videoIn.append(sbuf) {
            failure = writer.error ?? NSError(domain: "PostProcess", code: 30, userInfo: [NSLocalizedDescriptionKey: "Video append failed"])
            videoIn.markAsFinished()
            videoDone = true
            return
          }
        }
      }
    }

    let driver = Driver(
      writer: writer,
      videoOut: videoOut,
      videoIn: videoIn,
      sources: sourceAudio,
      masterIn: masterIn,
      sampleRate: Int(sampleRate),
      channels: channels,
      firstVideo: firstVideo,
      firstAudio: firstAudio
    )

    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
      final class AwaitState: @unchecked Sendable {
        let cont: CheckedContinuation<Void, any Error>
        let driver: Driver
        var remaining = 2
        var finished = false

        init(cont: CheckedContinuation<Void, any Error>, driver: Driver) {
          self.cont = cont
          self.driver = driver
        }
      }

      let state = AwaitState(cont: cont, driver: driver)

      let finish: @Sendable (Error?) -> Void = { error in
        guard !state.finished else { return }
        state.finished = true
        if let error {
          state.cont.resume(throwing: error)
        } else {
          state.cont.resume(returning: ())
        }
      }

      let partDone: @Sendable () -> Void = {
        state.remaining -= 1
        if state.remaining <= 0 {
          finish(state.driver.failure)
        }
      }

      // All callbacks are executed on `q` by AVFoundation.
      driver.videoIn.requestMediaDataWhenReady(on: q) {
        driver.stepVideo()
        if let err = driver.failure { finish(err); return }
        if driver.videoDone, !driver.videoSignaled {
          driver.videoSignaled = true
          partDone()
        }
      }

      let audioInputs = driver.sources.map(\.input) + [driver.masterIn]
      for input in audioInputs {
        input.requestMediaDataWhenReady(on: q) {
          driver.stepAudio()
          if let err = driver.failure { finish(err); return }
          if driver.audioDone, !driver.audioSignaled {
            driver.audioSignaled = true
            partDone()
          }
        }
      }
    }

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      writer.finishWriting { cont.resume(returning: ()) }
    }

    if writer.status == .failed {
      throw writer.error ?? NSError(domain: "PostProcess", code: 40, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
    }
  }

  private static func trackTitle(_ title: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .quickTimeUserDataTrackName
    item.value = title as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }
}
