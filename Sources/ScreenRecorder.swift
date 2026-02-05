import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
@preconcurrency import ScreenCaptureKit

/// Records ScreenCaptureKit sample buffers into a `.mov` using `AVAssetWriter`.
///
/// We intentionally:
/// - Capture in BGRA + sRGB (like Apple's examples / common app pipelines).
/// - Use `AVOutputSettingsAssistant` as the baseline encoder config, then remove bitrate caps
///   and request max quality to avoid chroma starvation (the typical "washed out" symptom).
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  struct Options: Sendable {
    var outputURL: URL
    var videoCodec: AVVideoCodecType
    var includeMicrophone: Bool
    var microphoneDeviceID: String?
    var includeSystemAudio: Bool

    var width: Int
    var height: Int
  }

  private struct UnsafeSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let type: SCStreamOutputType
  }

  private let filter: SCContentFilter
  private let options: Options
  private let ioQueue = DispatchQueue(label: "capa.screen-recorder.io")

  private var stream: SCStream?

  private var writer: AVAssetWriter?
  private var videoIn: AVAssetWriterInput?
  private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var micAudioIn: AVAssetWriterInput?
  private var systemAudioIn: AVAssetWriterInput?

  // We must not drop audio samples just because the writer input has backpressure.
  // Dropping can produce perceptual artifacts (metallic/echoey audio). Buffer and drain instead.
  private var micQueue: [CMSampleBuffer] = []
  private var micQueueReadIndex: Int = 0
  private var systemQueue: [CMSampleBuffer] = []
  private var systemQueueReadIndex: Int = 0
  private var isStopping = false
  private var lastPTS: CMTime = .zero
  private var sessionStartPTS: CMTime?
  private var failure: (any Error)?

  init(filter: SCContentFilter, options: Options) {
    self.filter = filter
    self.options = options
  }

  func start() async throws {
    let stream: SCStream = try await withCheckedThrowingContinuation { cont in
      ioQueue.async {
        do {
          let s = try self.prepareStreamLocked()
          cont.resume(returning: s)
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
    try await stream.startCapture()
  }

  func stop() async throws {
    guard let stream else { return }

    await withCheckedContinuation { cont in
      ioQueue.async {
        self.isStopping = true
        cont.resume()
      }
    }

    do {
      try await stream.stopCapture()
    } catch {
      ioQueue.async { self.failure = self.failure ?? error }
    }

    try await withCheckedThrowingContinuation { cont in
      ioQueue.async {
        do {
          try self.finishLocked()
          cont.resume(returning: ())
        } catch {
          cont.resume(throwing: error)
        }
      }
    }
  }

  // MARK: - SCStreamOutput

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    let sample = UnsafeSample(buffer: sampleBuffer, type: type)
    ioQueue.async { self.handleLocked(sample: sample) }
  }

  // MARK: - SCStreamDelegate

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    ioQueue.async { self.failure = self.failure ?? error }
  }

  // MARK: - Internals (ioQueue only)

  private func prepareStreamLocked() throws -> SCStream {
    precondition(!Thread.isMainThread)

    let cfg = SCStreamConfiguration()
    cfg.width = options.width
    cfg.height = options.height
    cfg.scalesToFit = false
    cfg.preservesAspectRatio = true
    cfg.queueDepth = 6

    // Capture at native refresh. We post-process to CFR 60 fps by default in the CLI.
    cfg.minimumFrameInterval = .zero

    cfg.captureDynamicRange = .SDR

    // Capture in RGB and let the encoder handle Y'CbCr conversion + tagging.
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.colorSpaceName = CGColorSpace.sRGB

    cfg.capturesAudio = options.includeSystemAudio
    cfg.captureMicrophone = options.includeMicrophone
    cfg.microphoneCaptureDeviceID = options.microphoneDeviceID

    let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: nil)
    if options.includeSystemAudio {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: nil)
    }
    if options.includeMicrophone {
      try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: nil)
    }

    self.stream = stream
    self.writer = nil
    self.videoIn = nil
    self.videoAdaptor = nil
    self.micAudioIn = nil
    self.systemAudioIn = nil
    self.micQueue = []
    self.micQueueReadIndex = 0
    self.systemQueue = []
    self.systemQueueReadIndex = 0
    self.failure = nil
    self.isStopping = false
    self.lastPTS = .zero
    self.sessionStartPTS = nil
    return stream
  }

  private func handleLocked(sample: UnsafeSample) {
    precondition(!Thread.isMainThread)
    if isStopping { return }
    if failure != nil { return }

    switch sample.type {
    case .screen:
      handleScreenLocked(sample: sample.buffer)
    case .audio:
      handleSystemAudioLocked(sample: sample.buffer)
    case .microphone:
      handleMicrophoneLocked(sample: sample.buffer)
    default:
      break
    }
  }

  private func frameStatus(_ sample: CMSampleBuffer) -> SCFrameStatus? {
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let attachment = attachments.first,
      let statusRaw = attachment[.status] as? Int
    else { return nil }
    return SCFrameStatus(rawValue: statusRaw)
  }

  private func handleScreenLocked(sample: CMSampleBuffer) {
    guard CMSampleBufferDataIsReady(sample) else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

    if let status = frameStatus(sample) {
      switch status {
      case .complete, .started, .idle:
        break
      default:
        // Drop blank/suspended/stopped frames to avoid poisoning the encoder.
        return
      }
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)

    do {
      if writer == nil {
        try startWriterLocked(firstScreenSample: sample)
      }

      guard let writer, let videoIn, let videoAdaptor else { return }
      guard writer.status == .writing else { return }
      guard videoIn.isReadyForMoreMediaData else { return }

      if !videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
        throw writer.error ?? NSError(domain: "ScreenRecorder", code: 11, userInfo: [NSLocalizedDescriptionKey: "Video append failed (status: \(writer.status))"])
      }

      lastPTS = pts
      // Drain buffered audio opportunistically to keep A/V tightly synchronized.
      drainAudioLocked()
    } catch {
      failure = error
    }
  }

  private func handleMicrophoneLocked(sample: CMSampleBuffer) {
    guard options.includeMicrophone else { return }
    guard CMSampleBufferDataIsReady(sample) else { return }

    enqueueAudio(sample: sample, into: &micQueue, readIndex: &micQueueReadIndex)
    drainAudioLocked()
  }

  private func handleSystemAudioLocked(sample: CMSampleBuffer) {
    guard options.includeSystemAudio else { return }
    guard CMSampleBufferDataIsReady(sample) else { return }

    enqueueAudio(sample: sample, into: &systemQueue, readIndex: &systemQueueReadIndex)
    drainAudioLocked()
  }

  private func enqueueAudio(sample: CMSampleBuffer, into queue: inout [CMSampleBuffer], readIndex: inout Int) {
    // Cap memory growth in pathological backpressure scenarios.
    let maxQueued = 2000
    queue.append(sample)
    if queue.count > maxQueued {
      let removeCount = queue.count - maxQueued
      queue.removeFirst(removeCount)
      readIndex = max(0, readIndex - removeCount)
    }
  }

  private func drainAudioLocked() {
    precondition(!Thread.isMainThread)
    guard failure == nil else { return }
    guard let writer, writer.status == .writing else { return }
    guard let sessionStartPTS else { return }

    func drain(queue: inout [CMSampleBuffer], readIndex: inout Int, input: AVAssetWriterInput) {
      while readIndex < queue.count && input.isReadyForMoreMediaData {
        let s = queue[readIndex]
        readIndex += 1
        if CMSampleBufferGetPresentationTimeStamp(s) < sessionStartPTS { continue }
        if !input.append(s) {
          failure = writer.error ?? NSError(domain: "ScreenRecorder", code: 21, userInfo: [NSLocalizedDescriptionKey: "Audio append failed (status: \(writer.status))"])
          return
        }
      }

      // Compact occasionally to keep the array small without O(n) per sample.
      if readIndex > 256 {
        queue.removeFirst(readIndex)
        readIndex = 0
      } else if readIndex == queue.count {
        queue.removeAll(keepingCapacity: true)
        readIndex = 0
      }
    }

    if let micAudioIn {
      drain(queue: &micQueue, readIndex: &micQueueReadIndex, input: micAudioIn)
    }
    if let systemAudioIn {
      drain(queue: &systemQueue, readIndex: &systemQueueReadIndex, input: systemAudioIn)
    }
  }

  private func startWriterLocked(firstScreenSample: CMSampleBuffer) throws {
    precondition(!Thread.isMainThread)
    guard let fmt = CMSampleBufferGetFormatDescription(firstScreenSample) else {
      throw NSError(domain: "ScreenRecorder", code: 30, userInfo: [NSLocalizedDescriptionKey: "Missing format description"])
    }
    guard let firstPixelBuffer = CMSampleBufferGetImageBuffer(firstScreenSample) else {
      throw NSError(domain: "ScreenRecorder", code: 30, userInfo: [NSLocalizedDescriptionKey: "Missing image buffer"])
    }

    let writer = try AVAssetWriter(outputURL: options.outputURL, fileType: .mov)

    // Base on Apple's recommended presets, then remove bitrate caps so the encoder can "breathe"
    // on high-frequency UI edges (where washed-out chroma is most noticeable).
    let preset: AVOutputSettingsPreset = (options.videoCodec == .hevc) ? .hevc3840x2160 : .preset3840x2160
    guard let assistant = AVOutputSettingsAssistant(preset: preset) else {
      throw NSError(domain: "ScreenRecorder", code: 31, userInfo: [NSLocalizedDescriptionKey: "AVOutputSettingsAssistant unavailable for preset \(preset)"])
    }

    // Improves assistant recommendations (avoids upscaling, matches source characteristics).
    assistant.sourceVideoFormat = fmt

    guard var videoSettings = assistant.videoSettings else {
      throw NSError(domain: "ScreenRecorder", code: 32, userInfo: [NSLocalizedDescriptionKey: "AVOutputSettingsAssistant.videoSettings missing"])
    }

    videoSettings[AVVideoWidthKey] = options.width
    videoSettings[AVVideoHeightKey] = options.height
    videoSettings[AVVideoCodecKey] = options.videoCodec

    if var compression = videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any] {
      // Live capture knobs.
      compression[kVTCompressionPropertyKey_RealTime as String] = true
      compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false

      // Keep editing-friendly GOPs without hard-coding a capture framerate.
      compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2.0
      compression[AVVideoAllowFrameReorderingKey] = false

      // Avoid artificially restricting quality. Let the encoder allocate bits as needed.
      compression.removeValue(forKey: AVVideoAverageBitRateKey)
      compression.removeValue(forKey: kVTCompressionPropertyKey_AverageBitRate as String)
      compression.removeValue(forKey: kVTCompressionPropertyKey_DataRateLimits as String)
      compression.removeValue(forKey: kVTCompressionPropertyKey_ConstantBitRate as String)

      // "As many bits as needed" within the encoder's normal constraints.
      compression[kVTCompressionPropertyKey_Quality as String] = 1.0

      videoSettings[AVVideoCompressionPropertiesKey] = compression
    }

    let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: fmt)
    videoIn.expectsMediaDataInRealTime = true
    guard writer.canAdd(videoIn) else {
      throw NSError(domain: "ScreenRecorder", code: 33, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
    }
    writer.add(videoIn)

    let adaptorAttrs: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(CVPixelBufferGetPixelFormatType(firstPixelBuffer)),
      kCVPixelBufferWidthKey as String: options.width,
      kCVPixelBufferHeightKey as String: options.height,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: adaptorAttrs)

    var micAudioIn: AVAssetWriterInput?
    var systemAudioIn: AVAssetWriterInput?
    let audioSettings = assistant.audioSettings ?? [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVNumberOfChannelsKey: 2,
      AVSampleRateKey: 48_000,
      AVEncoderBitRateKey: 128_000,
    ]

    if options.includeMicrophone {
      let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aIn.expectsMediaDataInRealTime = true
      aIn.metadata = [trackTitle("Microphone")]
      aIn.languageCode = "qac"
      aIn.extendedLanguageTag = "qac-x-capa-mic"
      if writer.canAdd(aIn) {
        writer.add(aIn)
        micAudioIn = aIn
      }
    }

    if options.includeSystemAudio {
      let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      aIn.expectsMediaDataInRealTime = true
      aIn.metadata = [trackTitle("System Audio")]
      // Use distinct language tags so editors/players can differentiate tracks.
      // qaa/qab/qac are reserved for local use (ISO 639-2).
      aIn.languageCode = "qab"
      aIn.extendedLanguageTag = "qab-x-capa-system"
      if writer.canAdd(aIn) {
        writer.add(aIn)
        systemAudioIn = aIn
      }
    }

    guard writer.startWriting() else {
      throw writer.error ?? NSError(domain: "ScreenRecorder", code: 34, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
    }
    let startPTS = CMSampleBufferGetPresentationTimeStamp(firstScreenSample)
    writer.startSession(atSourceTime: startPTS)

    self.writer = writer
    self.videoIn = videoIn
    self.videoAdaptor = adaptor
    self.micAudioIn = micAudioIn
    self.systemAudioIn = systemAudioIn
    self.sessionStartPTS = startPTS

    // Flush any audio samples that arrived before video started.
    drainAudioLocked()
  }

  private func finishLocked() throws {
    precondition(!Thread.isMainThread)

    if let failure { throw failure }
    guard let writer else {
      throw NSError(domain: "ScreenRecorder", code: 40, userInfo: [NSLocalizedDescriptionKey: "No frames captured (writer never started)"])
    }

    if writer.status == .writing {
      writer.endSession(atSourceTime: lastPTS)
    }

    videoIn?.markAsFinished()
    micAudioIn?.markAsFinished()
    systemAudioIn?.markAsFinished()

    let sema = DispatchSemaphore(value: 0)
    writer.finishWriting { sema.signal() }
    sema.wait()

    if writer.status == .failed {
      throw writer.error ?? NSError(domain: "ScreenRecorder", code: 41, userInfo: [NSLocalizedDescriptionKey: "Writer failed"])
    }
  }

  private func trackTitle(_ title: String) -> AVMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = .quickTimeUserDataTrackName
    item.value = title as NSString
    item.dataType = kCMMetadataBaseDataType_UTF8 as String
    return item
  }
}
