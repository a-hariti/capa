import ArgumentParser
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Darwin

@main
struct Capa: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Native macOS screen recorder (QuickTime-like output)."
  )

  @Flag(name: [.customLong("list-displays")], help: "List available displays and exit")
  var listDisplays = false

  @Flag(name: [.customLong("list-mics"), .customLong("list-microphones")], help: "List available microphones and exit")
  var listMicrophones = false

  @Flag(name: [.customLong("list-cameras")], help: "List available cameras and exit")
  var listCameras = false

  @Option(name: .customLong("display-index"), help: "Select display by index (from --list-displays)")
  var displayIndex: Int?

  @Flag(name: .customLong("no-mic"), help: "Disable microphone")
  var noMicrophone = false

  @Option(name: .customLong("mic-index"), help: "Select microphone by index (from --list-mics)")
  var microphoneIndex: Int?

  @Option(name: .customLong("mic-id"), help: "Select microphone by AVCaptureDevice.uniqueID")
  var microphoneID: String?

  @Flag(name: .customLong("camera"), help: "Record a secondary camera video track")
  var cameraFlag = false

  @Option(name: .customLong("camera-index"), help: "Select camera by index (from --list-cameras)")
  var cameraIndex: Int?

  @Option(name: .customLong("camera-id"), help: "Select camera by AVCaptureDevice.uniqueID")
  var cameraID: String?

  @Flag(name: .customLong("system-audio"), help: "Capture system audio to a separate track")
  var systemAudioFlag = false

  @Flag(name: .customLong("vfr"), help: "Keep variable frame rate (skip CFR post-process)")
  var keepVFR = false

  @Option(name: .customLong("fps"), help: "Post-process SCREEN recording to constant frame rate (default: 60 fps)")
  var fps: Int?

  @Option(name: .customLong("codec"), help: "Video codec (h264|hevc)")
  var codecString: String?

  @Option(name: .customLong("duration"), help: "Auto-stop after N seconds (non-interactive friendly)")
  var durationSeconds: Int?

  @Option(name: [.customLong("out"), .customLong("output")], help: "Output file path (default: recs/screen-<ts>.mov)")
  var outputPath: String?

  @Flag(name: .customLong("open"), help: "Open file when done")
  var openFlag = false

  @Flag(name: .customLong("no-open"), help: "Do not open file when done")
  var noOpenFlag = false

  @Flag(name: .customLong("non-interactive"), help: "Error instead of prompting for missing options")
  var nonInteractive = false

  @Flag(name: [.short, .customLong("verbose")], help: "Show detailed capture settings/debug output")
  var verbose = false

  mutating func validate() throws {
    if let displayIndex, displayIndex < 0 {
      throw ValidationError("--display-index must be >= 0")
    }
    if let microphoneIndex, microphoneIndex < 0 {
      throw ValidationError("--mic-index must be >= 0")
    }
    if let cameraIndex, cameraIndex < 0 {
      throw ValidationError("--camera-index must be >= 0")
    }
    if openFlag && noOpenFlag {
      throw ValidationError("Cannot use --open and --no-open together.")
    }
    if let durationSeconds, durationSeconds < 1 {
      throw ValidationError("--duration must be >= 1")
    }
    if let codecString, parseCodec(codecString) == nil {
      throw ValidationError("Invalid --codec: \(codecString) (expected: h264|hevc)")
    }
    if let fps, fps < 1 {
      throw ValidationError("--fps must be >= 1")
    }
  }

  mutating func run() async throws {
    let isTTYOut = Terminal.isTTY(STDOUT_FILENO)
    let banner = isTTYOut
      ? "Capa \(TUITheme.label("(native macOS screen capture)"))"
      : "Capa (native macOS screen capture)"
    print(banner)
    print("")
    func sectionTitle(_ s: String) -> String { isTTYOut ? TUITheme.title(s) : s }
    func muted(_ s: String) -> String { isTTYOut ? TUITheme.muted(s) : s }
    func optionText(_ s: String) -> String { isTTYOut ? TUITheme.option(s) : s }
    func abbreviateHomePath(_ p: String) -> String {
      let home = NSHomeDirectory()
      if p == home { return "~" }
      if p.hasPrefix(home + "/") {
        return "~" + String(p.dropFirst(home.count))
      }
      return p
    }

    if listMicrophones {
      let audioDevices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
      ).devices

      if audioDevices.isEmpty {
        print("(no microphones)")
      } else {
        for (i, d) in audioDevices.enumerated() {
          print("[\(i)] \(microphoneLabel(d)) id=\(d.uniqueID)")
        }
      }
      return
    }

    if listCameras {
      let videoDevices = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
        mediaType: .video,
        position: .unspecified
      ).devices

      if videoDevices.isEmpty {
        print("(no cameras)")
      } else {
        for (i, d) in videoDevices.enumerated() {
          print("[\(i)] \(cameraLabel(d)) id=\(d.uniqueID)")
        }
      }
      return
    }

    if !requestScreenRecordingAccess() {
      print("Screen recording permission not granted.")
      print("System Settings -> Privacy & Security -> Screen Recording -> allow this binary.")
      return
    }

    let content = try await SCShareableContent.current

    guard !content.displays.isEmpty else {
      print("No displays found.")
      return
    }

    if listDisplays {
      for (i, d) in content.displays.enumerated() {
        print("[\(i)] \(displayLabel(d))")
      }
      return
    }

    let autoSelectedSingleDisplay = (displayIndex == nil && content.displays.count == 1)
    let display: SCDisplay
    if let idx = displayIndex {
      guard idx >= 0 && idx < content.displays.count else {
        print("Error: --display-index out of range (0...\(content.displays.count - 1))")
        return
      }
      display = content.displays[idx]
    } else if content.displays.count == 1 {
      display = content.displays[0]
    } else if nonInteractive {
      print("Error: missing display selection; use --display-index (or omit --non-interactive).")
      return
    } else {
      let displayOptions = content.displays.map(displayLabel)
      let displayIdx = selectOption(title: "Display", options: displayOptions, defaultIndex: 0)
      display = content.displays[displayIdx]
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let logicalWidth = Int(display.width)
    let logicalHeight = Int(display.height)
    let geometry = captureGeometry(filter: filter, fallbackLogicalSize: (logicalWidth, logicalHeight))

    if autoSelectedSingleDisplay && !nonInteractive {
      let displayLabel = isTTYOut ? TUITheme.primary("Display:") : "Display:"
      print("\(displayLabel) \(optionText("\(geometry.pixelWidth)x\(geometry.pixelHeight)px"))")
    }

    let audioDevices = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    ).devices

    let videoDevices = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
      mediaType: .video,
      position: .unspecified
    ).devices

    let includeSystemAudio: Bool
    if systemAudioFlag {
      includeSystemAudio = true
    } else if nonInteractive {
      includeSystemAudio = false
    } else {
      let idx = selectOption(
        title: "Record System Audio?",
        options: ["Yes", "No"],
        defaultIndex: 0
      )
      includeSystemAudio = (idx == 0)
    }

    var audioDevice: AVCaptureDevice?
    var includeMic = false
    if noMicrophone {
      includeMic = false
    } else if let idx = microphoneIndex {
      guard idx >= 0 && idx < audioDevices.count else {
        print("Error: --mic-index out of range (0...\(max(0, audioDevices.count - 1)))")
        return
      }
      audioDevice = audioDevices[idx]
      includeMic = true
    } else if let id = microphoneID {
      guard let d = audioDevices.first(where: { $0.uniqueID == id }) else {
        print("Error: no microphone with id \(id)")
        return
      }
      audioDevice = d
      includeMic = true
    } else if nonInteractive {
      includeMic = false
    } else if !audioDevices.isEmpty {
      let audioOptions = ["No microphone"] + audioDevices.map(microphoneLabel)
      let audioIdx = selectOption(title: "Microphone", options: audioOptions, defaultIndex: 0)
      if audioIdx > 0 {
        audioDevice = audioDevices[audioIdx - 1]
        includeMic = true
      }
    }

    if includeMic {
      let micGranted = await requestMicrophoneAccess()
      if !micGranted {
        print("Microphone permission not granted. Continuing without microphone.")
        print("System Settings -> Privacy & Security -> Microphone -> allow this binary.")
        includeMic = false
        audioDevice = nil
      }
    }

    var cameraDevice: AVCaptureDevice?
    var includeCamera = false
    if cameraFlag || cameraIndex != nil || cameraID != nil {
      includeCamera = true
    }
    if includeCamera {
      if let idx = cameraIndex {
        guard idx >= 0 && idx < videoDevices.count else {
          print("Error: --camera-index out of range (0...\(max(0, videoDevices.count - 1)))")
          return
        }
        cameraDevice = videoDevices[idx]
      } else if let id = cameraID {
        guard let d = videoDevices.first(where: { $0.uniqueID == id }) else {
          print("Error: no camera with id \(id)")
          return
        }
        cameraDevice = d
      } else {
        cameraDevice = videoDevices.first
      }
    } else if !nonInteractive, !videoDevices.isEmpty {
      let options = ["No camera"] + videoDevices.map(cameraLabel)
      let idx = selectOption(title: "Camera", options: options, defaultIndex: 0)
      if idx > 0 {
        includeCamera = true
        cameraDevice = videoDevices[idx - 1]
      }
    }

    if includeCamera {
      let camGranted = await requestCameraAccess()
      if !camGranted {
        print("Camera permission not granted. Continuing without camera.")
        print("System Settings -> Privacy & Security -> Camera -> allow this binary.")
        includeCamera = false
        cameraDevice = nil
      }
    }

    let codec: AVVideoCodecType
    if let c = codecString.flatMap(parseCodec) {
      codec = c
    } else if nonInteractive {
      codec = .h264
    } else {
      let codecOptions = ["H.264", "H.265/HEVC"]
      // QuickTime screen recordings default to H.264; keep that as our default as well.
      let codecIdx = selectOption(title: "Video Codec", options: codecOptions, defaultIndex: 0)
      codec = (codecIdx == 0) ? .h264 : .hevc
    }

    let cfrFPS: Int?
    if keepVFR {
      if fps != nil {
        print("Warning: --vfr overrides --fps; CFR post-processing is disabled.")
      }
      cfrFPS = nil
    } else if let v = fps {
      cfrFPS = max(1, min(240, v))
    } else {
      // Default to CFR 60; users can opt out with --vfr.
      cfrFPS = 60
    }

    let scaleStr = String(format: "%.2f", geometry.pointPixelScale)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let ts = formatter.string(from: Date())

    let recsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("recs")
    try? FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)

    let outFile: URL
    let cameraOutFile: URL?
    if let outputPath = outputPath {
      let u = URL(fileURLWithPath: outputPath)
      if u.pathExtension.isEmpty {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        outFile = u.appendingPathComponent("screen-\(ts).mov")
        cameraOutFile = includeCamera ? u.appendingPathComponent("camera-\(ts).mov") : nil
      } else {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        outFile = u
        if includeCamera {
          let base = u.deletingPathExtension().lastPathComponent
          cameraOutFile = u.deletingLastPathComponent().appendingPathComponent(base + "-camera.mov")
        } else {
          cameraOutFile = nil
        }
      }
    } else {
      outFile = recsDir.appendingPathComponent("screen-\(ts).mov")
      cameraOutFile = includeCamera ? recsDir.appendingPathComponent("camera-\(ts).mov") : nil
    }

    let hasMic = includeMic
    let hasSystemAudio = includeSystemAudio

    let meters = LiveMeters()
    let showMeters = Terminal.isTTY(fileno(stderr)) && (hasMic || hasSystemAudio)
    var onAudioLevel: (@Sendable (ScreenRecorder.AudioSource, Float) -> Void)?
    if showMeters {
      onAudioLevel = { source, db in meters.update(source: source, db: db) }
    }
    let recorderOptions = ScreenRecorder.Options(
      outputURL: outFile,
      videoCodec: codec,
      includeMicrophone: includeMic,
      microphoneDeviceID: includeMic ? audioDevice?.uniqueID : nil,
      includeSystemAudio: includeSystemAudio,
      width: geometry.pixelWidth,
      height: geometry.pixelHeight,
      includeCamera: includeCamera,
      cameraDeviceID: cameraDevice?.uniqueID,
      cameraOutputURL: cameraOutFile,
      onAudioLevel: onAudioLevel
    )
    let recorder = ScreenRecorder(filter: filter, options: recorderOptions)

    let codecName = (codec == .hevc) ? "H.265/HEVC" : "H.264"
    if verbose {
      print("")
      print(sectionTitle("Settings:"))
      print(muted("  Capture: \(Int(geometry.sourceRect.width))x\(Int(geometry.sourceRect.height)) pt @ \(scaleStr)x => \(geometry.pixelWidth)x\(geometry.pixelHeight) px"))
      print(muted("  Video: \(codecName) \(geometry.pixelWidth)x\(geometry.pixelHeight) @ native refresh"))
      if keepVFR {
        print(muted("  Screen timing: VFR"))
      } else {
        print(muted("  Screen timing: CFR \(cfrFPS ?? 60) fps"))
      }
      if includeCamera {
        print(muted("  Camera timing: native (no CFR)"))
      }
      if includeMic, let audioDevice {
        print(muted("  Microphone: \(audioDevice.localizedName)"))
      } else {
        print(muted("  Microphone: none"))
      }
      if includeCamera, let cameraDevice {
        print(muted("  Camera: \(cameraDevice.localizedName)"))
      } else {
        print(muted("  Camera: none"))
      }
      print(muted("  System audio: \(includeSystemAudio ? "on" : "off")"))
      print("")
    }
    let canReadKeys = Terminal.isTTY(STDIN_FILENO)
    if !verbose {
      print("")
    }
    if canReadKeys {
      print("Recording... press 'q' to stop.")
    } else {
      print("Recording...")
    }

    let stopSignal = DispatchSemaphore(value: 0)

    // Key listener.
    if canReadKeys {
      DispatchQueue.global().async {
        Terminal.enableRawMode()
        defer { Terminal.disableRawMode() }
        while true {
          let key = Terminal.readKey()
          if case .char(let c) = key, c == "q" || c == "Q" {
            stopSignal.signal()
            return
          }
        }
      }
    }

    // SIGINT listener.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler { stopSignal.signal() }
    sigintSource.resume()

    let duration = durationSeconds
      ?? (ProcessInfo.processInfo.environment["SCREENCAP_AUTOSTOP_SECONDS"].flatMap { Int($0) })
    if let seconds = duration, seconds > 0 {
      print("Auto-stop: \(seconds)s")
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { stopSignal.signal() }
    }

    var suffix: (@Sendable () -> String)?
    if showMeters {
      suffix = { meters.render(includeMicrophone: hasMic, includeSystemAudio: hasSystemAudio) }
    }
    let ticker = ElapsedTicker(
      tickInterval: showMeters ? .milliseconds(100) : .seconds(1),
      suffix: suffix
    )

    do {
      try await recorder.start()
      ticker.startIfTTY()
    } catch {
      ticker.stop()
      print("Failed to start capture: \(error)")
      return
    }

    await withCheckedContinuation { cont in
      DispatchQueue.global().async {
        stopSignal.wait()
        cont.resume()
      }
    }

    do {
      ticker.stop()
      try await recorder.stop()
    } catch {
      ticker.stop()
      print("Recording failed: \(error)")
      return
    }

    do {
      try await PostProcess.addMasterAudioTrackIfNeeded(
        url: outFile,
        includeSystemAudio: includeSystemAudio,
        includeMicrophone: includeMic,
        forceMaster: includeCamera
      )
    } catch {
      print("Warning: failed to post-process audio tracks: \(error)")
    }

    if includeCamera, let cameraOutFile {
      do {
        // Ensure the camera file has its own audio first, and the screen's "Master (Mixed)" as a secondary
        // alignment reference (perfect sync for multi-cam editing).
        try await AlignmentMux.addMasterAlignmentTrack(cameraURL: cameraOutFile, screenURL: outFile)
      } catch {
        print("Warning: failed to add alignment track to camera recording: \(error)")
      }
    }

    if let cfrFPS {
      print("")
      print("Post-processing screen video to \(cfrFPS) fps...")
      do {
        try await VideoCFR.rewriteInPlace(url: outFile, fps: cfrFPS)
      } catch {
        print("Warning: CFR post-process failed: \(error)")
      }
    }

    print("")
    print(sectionTitle("Files:"))
    print("\(isTTYOut ? TUITheme.label("  Screen:") : "  Screen:") \(abbreviateHomePath(outFile.path))")
    if let cameraOutFile {
      print("\(isTTYOut ? TUITheme.label("  Camera:") : "  Camera:") \(abbreviateHomePath(cameraOutFile.path))")
    }

    if verbose, includeSystemAudio || includeMic {
      let screenHasMaster = (includeSystemAudio || includeMic) && (includeCamera || (includeSystemAudio && includeMic))
      var parts: [String] = []
      if screenHasMaster { parts.append("qaa=Master (mixed)") }
      if includeMic { parts.append("qac=Mic") }
      if includeSystemAudio { parts.append("qab=System") }
      print(muted("  Audio tracks (language tags): " + parts.joined(separator: ", ")))
    }
    if verbose, includeCamera, cameraOutFile != nil {
      print(muted("  Video files: screen=\(outFile.lastPathComponent), camera=\(cameraOutFile!.lastPathComponent)"))
      print(muted("  Camera file audio: a0=Mic (if enabled), a1=Master (mixed, for alignment)"))
    }
    print("")
    let shouldOpen: Bool
    if openFlag {
      shouldOpen = true
    } else if noOpenFlag {
      shouldOpen = false
    } else if nonInteractive {
      shouldOpen = false
    } else if Terminal.isTTY(STDIN_FILENO) {
      let prompt = includeCamera ? "Open screen capture?" : "Open file now?"
      shouldOpen = (selectOption(title: prompt, options: ["Yes", "No"], defaultIndex: 0) == 0)
    } else {
      shouldOpen = promptYesNo("Open file now?", defaultYes: true)
    }

    if shouldOpen {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      p.arguments = [outFile.path]
      try? p.run()
    }
  }
}

private func parseCodec(_ s: String) -> AVVideoCodecType? {
  switch s.lowercased() {
  case "h264", "avc", "avc1":
    return .h264
  case "hevc", "h265", "hvc", "hvc1":
    return .hevc
  default:
    return nil
  }
}
