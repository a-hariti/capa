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
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  enum AudioSource: Sendable {
    case microphone
    case system
  }

  struct Options: Sendable {
    var outputURL: URL
    var videoCodec: AVVideoCodecType
    var includeMicrophone: Bool
    var microphoneDeviceID: String?
    var includeSystemAudio: Bool

    var width: Int
    var height: Int

    /// Optional secondary video source (camera) written as a second video track.
    var includeCamera: Bool = false
    var cameraDeviceID: String?

    /// Called on the recorder's IO queue with a best-effort dBFS estimate.
    var onAudioLevel: (@Sendable (AudioSource, Float) -> Void)?
  }

  private struct UnsafeSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
    let type: SCStreamOutputType
  }

  private struct UnsafeCameraSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
  }

  private let filter: SCContentFilter
  private let options: Options
  private let ioQueue = DispatchQueue(label: "capa.screen-recorder.io")
  private let cameraCallbackQueue = DispatchQueue(label: "capa.camera.callbacks")

  private var stream: SCStream?

  private var cameraSession: AVCaptureSession?
  private var cameraFormatHint: CMFormatDescription?
  private var cameraDims: (w: Int, h: Int)?

  private var writer: AVAssetWriter?
  private var videoIn: AVAssetWriterInput?
  private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var cameraVideoIn: AVAssetWriterInput?
  private var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var micAudioIn: AVAssetWriterInput?
  private var systemAudioIn: AVAssetWriterInput?

  // We must not drop audio samples just because the writer input has backpressure.
  // Dropping can produce perceptual artifacts (metallic/echoey audio). Buffer and drain instead.
  private var micQueue: [CMSampleBuffer] = []
  private var micQueueReadIndex: Int = 0
  private var systemQueue: [CMSampleBuffer] = []
  private var systemQueueReadIndex: Int = 0

  // Buffer video samples until the writer session start time is known.
  private var preStartScreen: [CMSampleBuffer] = []
  private var preStartCamera: [CMSampleBuffer] = []
  private var firstScreenSample: CMSampleBuffer?
  private var firstCameraSample: CMSampleBuffer?

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
          try self.prepareCameraLockedIfNeeded()
          self.startCameraLockedIfNeeded()
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

    do {
      try await stream.stopCapture()
    } catch {
      ioQueue.async { self.failure = self.failure ?? error }
    }

    try await withCheckedThrowingContinuation { cont in
      ioQueue.async {
        do {
          self.stopCameraLockedIfNeeded()
          // After capture is stopped, prevent any late enqueued samples from being processed.
          self.isStopping = true
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
    self.cameraVideoIn = nil
    self.cameraAdaptor = nil
    self.micAudioIn = nil
    self.systemAudioIn = nil
    self.micQueue = []
    self.micQueueReadIndex = 0
    self.systemQueue = []
    self.systemQueueReadIndex = 0
    self.preStartScreen = []
    self.preStartCamera = []
    self.firstScreenSample = nil
    self.firstCameraSample = nil
    self.cameraFormatHint = nil
    self.cameraDims = nil
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

  // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let sample = UnsafeCameraSample(buffer: sampleBuffer)
    ioQueue.async { self.handleCameraLocked(sample: sample.buffer) }
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
      if sessionStartPTS == nil {
        // Buffer until we can start the writer session (need camera's first sample too, if enabled).
        enqueueVideoPreStart(sample: sample, into: &preStartScreen)
        if firstScreenSample == nil { firstScreenSample = sample }
        try startWriterIfReadyLocked()
        return
      }

      flushPreStartVideoLockedIfNeeded()

      guard let writer, let videoIn, let videoAdaptor else { return }
      guard writer.status == .writing else { return }
      guard videoIn.isReadyForMoreMediaData else { return }

      if !videoAdaptor.append(pixelBuffer, withPresentationTime: pts) {
        throw writer.error ?? NSError(domain: "ScreenRecorder", code: 11, userInfo: [NSLocalizedDescriptionKey: "Video append failed (status: \(writer.status))"])
      }

      lastPTS = max(lastPTS, pts)
      drainAudioLocked()
    } catch {
      failure = error
    }
  }

  private func handleCameraLocked(sample: CMSampleBuffer) {
    guard options.includeCamera else { return }
    guard !isStopping else { return }
    guard failure == nil else { return }
    guard CMSampleBufferDataIsReady(sample) else { return }
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { return }

    let pts = CMSampleBufferGetPresentationTimeStamp(sample)

    do {
      if sessionStartPTS == nil {
        enqueueVideoPreStart(sample: sample, into: &preStartCamera)
        if firstCameraSample == nil { firstCameraSample = sample }
        try startWriterIfReadyLocked()
        return
      }

      flushPreStartVideoLockedIfNeeded()

      guard let writer, let cameraVideoIn, let cameraAdaptor else { return }
      guard writer.status == .writing else { return }
      guard cameraVideoIn.isReadyForMoreMediaData else { return }

      if !cameraAdaptor.append(pixelBuffer, withPresentationTime: pts) {
        throw writer.error ?? NSError(domain: "ScreenRecorder", code: 12, userInfo: [NSLocalizedDescriptionKey: "Camera video append failed (status: \(writer.status))"])
      }

      lastPTS = max(lastPTS, pts)
    } catch {
      failure = error
    }
  }

  private func enqueueVideoPreStart(sample: CMSampleBuffer, into queue: inout [CMSampleBuffer]) {
    let maxQueued = 300
    queue.append(sample)
    if queue.count > maxQueued {
      queue.removeFirst(queue.count - maxQueued)
    }
  }

  private func prepareCameraLockedIfNeeded() throws {
    precondition(!Thread.isMainThread)
    guard options.includeCamera else {
      cameraSession = nil
      return
    }

    let session = AVCaptureSession()
    session.sessionPreset = .high

    let device: AVCaptureDevice? = {
      if let id = options.cameraDeviceID {
        return AVCaptureDevice(uniqueID: id)
      }
      return AVCaptureDevice.default(for: .video)
    }()

    guard let device else {
      throw NSError(domain: "ScreenRecorder", code: 80, userInfo: [NSLocalizedDescriptionKey: "Camera enabled but no camera device found"])
    }

    let fd = device.activeFormat.formatDescription
    let dims = CMVideoFormatDescriptionGetDimensions(fd)
    if dims.width > 0 && dims.height > 0 {
      cameraFormatHint = fd
      cameraDims = (w: Int(dims.width), h: Int(dims.height))
    } else {
      cameraFormatHint = fd
      cameraDims = nil
    }

    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else {
      throw NSError(domain: "ScreenRecorder", code: 81, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: cameraCallbackQueue)
    guard session.canAddOutput(output) else {
      throw NSError(domain: "ScreenRecorder", code: 82, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera output"])
    }
    session.addOutput(output)

    cameraSession = session
  }

  private func startCameraLockedIfNeeded() {
    precondition(!Thread.isMainThread)
    cameraSession?.startRunning()
  }

  private func stopCameraLockedIfNeeded() {
    precondition(!Thread.isMainThread)
    cameraSession?.stopRunning()
  }

  private func startWriterIfReadyLocked() throws {
    precondition(!Thread.isMainThread)
    guard sessionStartPTS == nil else { return }
    guard writer == nil else { return } // writer/session start happen together
    guard let firstScreenSample else { return }
    let startPTS: CMTime = {
      let s = CMSampleBufferGetPresentationTimeStamp(firstScreenSample)
      if let c = firstCameraSample {
        let cp = CMSampleBufferGetPresentationTimeStamp(c)
        return min(s, cp)
      }
      return s
    }()

    try startWriterLocked(startPTS: startPTS, firstScreenSample: firstScreenSample)
    flushPreStartVideoLockedIfNeeded()
  }

  private func flushPreStartVideoLockedIfNeeded() {
    precondition(!Thread.isMainThread)
    guard failure == nil else { return }
    guard let writer, writer.status == .writing else { return }
    guard let sessionStartPTS else { return }

    func drain(queue: inout [CMSampleBuffer], input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
      while !queue.isEmpty && input.isReadyForMoreMediaData {
        let s = queue.removeFirst()
        let pts = CMSampleBufferGetPresentationTimeStamp(s)
        if pts < sessionStartPTS { continue }
        guard let pb = CMSampleBufferGetImageBuffer(s) else { continue }
        if !adaptor.append(pb, withPresentationTime: pts) {
          failure = writer.error ?? NSError(domain: "ScreenRecorder", code: 13, userInfo: [NSLocalizedDescriptionKey: "Video append failed (prestart)"])
          return
        }
        lastPTS = max(lastPTS, pts)
      }
    }

    if let videoIn, let videoAdaptor, !preStartScreen.isEmpty {
      drain(queue: &preStartScreen, input: videoIn, adaptor: videoAdaptor)
    }
    if let cameraVideoIn, let cameraAdaptor, !preStartCamera.isEmpty {
      drain(queue: &preStartCamera, input: cameraVideoIn, adaptor: cameraAdaptor)
    }
  }

  private func handleMicrophoneLocked(sample: CMSampleBuffer) {
    guard options.includeMicrophone else { return }
    guard CMSampleBufferDataIsReady(sample) else { return }

    if let onAudioLevel = options.onAudioLevel, let db = AudioLevels.peakDBFS(from: sample) {
      onAudioLevel(.microphone, db)
    }

    enqueueAudio(sample: sample, into: &micQueue, readIndex: &micQueueReadIndex)
    drainAudioLocked()
  }

  private func handleSystemAudioLocked(sample: CMSampleBuffer) {
    guard options.includeSystemAudio else { return }
    guard CMSampleBufferDataIsReady(sample) else { return }

    if let onAudioLevel = options.onAudioLevel, let db = AudioLevels.peakDBFS(from: sample) {
      onAudioLevel(.system, db)
    }

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

  private func startWriterLocked(startPTS: CMTime, firstScreenSample: CMSampleBuffer) throws {
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

    var cameraVideoIn: AVAssetWriterInput?
    var cameraAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    if options.includeCamera {
      guard let cameraFormatHint else {
        throw NSError(domain: "ScreenRecorder", code: 35, userInfo: [NSLocalizedDescriptionKey: "Camera enabled but missing format hint"])
      }
      let (camW, camH): (Int, Int) = {
        if let cameraDims { return (cameraDims.w, cameraDims.h) }
        let d = CMVideoFormatDescriptionGetDimensions(cameraFormatHint)
        return (Int(d.width), Int(d.height))
      }()
      guard camW > 0 && camH > 0 else {
        throw NSError(domain: "ScreenRecorder", code: 36, userInfo: [NSLocalizedDescriptionKey: "Camera enabled but unknown dimensions"])
      }

      guard let assistant2 = AVOutputSettingsAssistant(preset: preset) else {
        throw NSError(domain: "ScreenRecorder", code: 37, userInfo: [NSLocalizedDescriptionKey: "AVOutputSettingsAssistant unavailable for camera preset \(preset)"])
      }
      assistant2.sourceVideoFormat = cameraFormatHint
      guard var camSettings = assistant2.videoSettings else {
        throw NSError(domain: "ScreenRecorder", code: 38, userInfo: [NSLocalizedDescriptionKey: "Missing camera video settings"])
      }

      camSettings[AVVideoWidthKey] = camW
      camSettings[AVVideoHeightKey] = camH
      camSettings[AVVideoCodecKey] = options.videoCodec
      if var compression = camSettings[AVVideoCompressionPropertiesKey] as? [String: Any] {
        compression[kVTCompressionPropertyKey_RealTime as String] = true
        compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = false
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2.0
        compression[AVVideoAllowFrameReorderingKey] = false
        compression.removeValue(forKey: AVVideoAverageBitRateKey)
        compression.removeValue(forKey: kVTCompressionPropertyKey_AverageBitRate as String)
        compression.removeValue(forKey: kVTCompressionPropertyKey_DataRateLimits as String)
        compression.removeValue(forKey: kVTCompressionPropertyKey_ConstantBitRate as String)
        compression[kVTCompressionPropertyKey_Quality as String] = 1.0
        camSettings[AVVideoCompressionPropertiesKey] = compression
      }

      let camIn = AVAssetWriterInput(mediaType: .video, outputSettings: camSettings, sourceFormatHint: cameraFormatHint)
      camIn.expectsMediaDataInRealTime = true
      guard writer.canAdd(camIn) else {
        throw NSError(domain: "ScreenRecorder", code: 39, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera video input"])
      }
      writer.add(camIn)

      let camAdaptorAttrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: camW,
        kCVPixelBufferHeightKey as String: camH,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
      let camAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: camIn, sourcePixelBufferAttributes: camAdaptorAttrs)
      cameraVideoIn = camIn
      cameraAdaptor = camAdaptor
    }

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
    writer.startSession(atSourceTime: startPTS)

    self.writer = writer
    self.videoIn = videoIn
    self.videoAdaptor = adaptor
    self.cameraVideoIn = cameraVideoIn
    self.cameraAdaptor = cameraAdaptor
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
    cameraVideoIn?.markAsFinished()
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
