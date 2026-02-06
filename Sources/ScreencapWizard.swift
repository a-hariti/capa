import ArgumentParser
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Darwin

enum OnOffMode: String, ExpressibleByArgument, Sendable {
  case on
  case off

  var enabled: Bool { self == .on }
}

struct AudioRouting: Equatable, Sendable {
  var includeMicrophone: Bool
  var includeSystemAudio: Bool

  static let none = AudioRouting(includeMicrophone: false, includeSystemAudio: false)
  static let mic = AudioRouting(includeMicrophone: true, includeSystemAudio: false)
  static let system = AudioRouting(includeMicrophone: false, includeSystemAudio: true)
  static let micAndSystem = AudioRouting(includeMicrophone: true, includeSystemAudio: true)

  static func parse(_ raw: String) throws -> AudioRouting {
    let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
    if normalized.isEmpty {
      throw ValidationError("Invalid --audio value: empty")
    }
    if normalized == "none" {
      return .none
    }

    var includeMicrophone = false
    var includeSystemAudio = false
    var sawToken = false

    for tokenSub in normalized.split(separator: "+", omittingEmptySubsequences: true) {
      let token = String(tokenSub)
      sawToken = true
      switch token {
      case "mic", "microphone":
        includeMicrophone = true
      case "sys", "system":
        includeSystemAudio = true
      default:
        throw ValidationError("Invalid --audio token '\(token)'. Use only: none, mic, system, mic+system")
      }
    }

    if !sawToken {
      throw ValidationError("Invalid --audio value: '\(raw)'")
    }
    return AudioRouting(includeMicrophone: includeMicrophone, includeSystemAudio: includeSystemAudio)
  }
}

enum CameraSelection: Sendable {
  case index(Int)
  case id(String)
}

enum MicrophoneSelection: Sendable {
  case index(Int)
  case id(String)
}

func parseCameraSelection(_ raw: String) throws -> CameraSelection {
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty {
    throw ValidationError("Invalid --camera value: empty")
  }
  if let index = Int(value) {
    return .index(index)
  }
  return .id(value)
}

func parseMicrophoneSelection(_ raw: String) throws -> MicrophoneSelection {
  let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty {
    throw ValidationError("Invalid --mic value: empty")
  }
  if let index = Int(value) {
    return .index(index)
  }
  return .id(value)
}

@main
struct Capa: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Native macOS screen recorder (QuickTime-like output)."
  )

  @Flag(name: [.customLong("list-displays")], help: "List available displays and exit")
  var listDisplays = false

  @Flag(name: [.customLong("list-mics")], help: "List available microphones and exit")
  var listMicrophones = false

  @Flag(name: [.customLong("list-cameras")], help: "List available cameras and exit")
  var listCameras = false

  @Option(name: .customLong("display-index"), help: "Select display by index (from --list-displays)")
  var displayIndex: Int?

  @Option(name: .customLong("mic"), help: "Select microphone by index (from --list-mics) or AVCaptureDevice.uniqueID")
  var microphoneSelector: String?

  @Option(name: .customLong("camera"), help: "Record camera by index (from --list-cameras) or AVCaptureDevice.uniqueID")
  var cameraSelector: String?

  @Option(name: .customLong("audio"), help: "Audio sources: (none, mic, system, mic+system)")
  var audioSpec: String?

  @Option(name: .customLong("safe-mix"), help: "Safe master limiter: on|off")
  var safeMixMode: OnOffMode = .on

  @Flag(name: .customLong("vfr"), help: "Keep variable frame rate (skip CFR post-process)")
  var keepVFR = false

  @Option(name: .customLong("fps"), help: "Post-process SCREEN recording to constant frame rate (default: 60 fps)")
  var fps: Int?

  @Option(name: .customLong("codec"), help: "Video codec (h264|hevc)")
  var codecString: String?

  @Option(name: .customLong("duration"), help: "Auto-stop after N seconds (non-interactive friendly)")
  var durationSeconds: Int?

  @Option(name: .customLong("project-name"), help: "Project folder name (default: capa-<timestamp>)")
  var projectName: String?

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
    if let microphoneSelector {
      let parsed = try parseMicrophoneSelection(microphoneSelector)
      if case .index(let microphoneIndex) = parsed, microphoneIndex < 0 {
        throw ValidationError("--mic must be >= 0 when using an index")
      }
    }
    if let cameraSelector {
      let parsed = try parseCameraSelection(cameraSelector)
      if case .index(let cameraIndex) = parsed, cameraIndex < 0 {
        throw ValidationError("--camera must be >= 0 when using an index")
      }
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
    if let projectName, projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--project-name must not be empty")
    }
    if let audioSpec {
      let parsed = try AudioRouting.parse(audioSpec)
      if !parsed.includeMicrophone, microphoneSelector != nil {
        throw ValidationError("--audio \(audioSpec) does not include microphone; remove --mic or include mic")
      }
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
    func sanitizeProjectName(_ s: String) -> String {
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return "capa" }
      let forbidden = CharacterSet(charactersIn: "/:\\")
      let mapped = trimmed.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) }
      return String(mapped)
    }
    func slugifyFilenameStem(_ s: String) -> String {
      let lower = s.lowercased()
      let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
      var out = ""
      var prevDash = false
      for sc in lower.unicodeScalars {
        if allowed.contains(sc) {
          out.unicodeScalars.append(sc)
          prevDash = false
        } else if !prevDash {
          out.append("-")
          prevDash = true
        }
      }
      let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
      return trimmed.isEmpty ? "camera" : trimmed
    }
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

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let ts = formatter.string(from: Date())
    let defaultProjectName = "capa-\(ts)"

    let isSingleDisplay = (content.displays.count == 1)
    enum WizardStep {
      case projectName
      case display
      case audio
      case microphone
      case camera
      case codec
    }
    func clearPreviousAnswerLineIfTTY() {
      guard isTTYOut else { return }
      print("\u{001B}[1A\u{001B}[2K\r", terminator: "")
    }
    func clearLinesIfTTY(_ count: Int) {
      guard count > 0 else { return }
      for _ in 0..<count { clearPreviousAnswerLineIfTTY() }
    }

    var selectedDisplayIndex: Int?
    var selectedProjectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
    var audioRouting: AudioRouting?
    var audioDevice: AVCaptureDevice?
    var includeMic = false
    var cameraDevice: AVCaptureDevice?
    var includeCamera = false
    var codec: AVVideoCodecType?

    var displayDefaultIndex = 0
    var audioDefaultIndex = 1
    var microphoneDefaultIndex = 0
    var cameraDefaultIndex = 0
    var codecDefaultIndex = 0

    if let idx = displayIndex {
      guard idx >= 0 && idx < content.displays.count else {
        print("Error: --display-index out of range (0...\(content.displays.count - 1))")
        return
      }
      selectedDisplayIndex = idx
      displayDefaultIndex = idx
    } else if content.displays.count == 1 {
      selectedDisplayIndex = 0
      displayDefaultIndex = 0
    } else if nonInteractive {
      print("Error: missing display selection; use --display-index (or omit --non-interactive).")
      return
    }

    if let audioSpec {
      audioRouting = try AudioRouting.parse(audioSpec)
    } else if nonInteractive {
      audioRouting = AudioRouting.none
    }

    if let routing = audioRouting {
      includeMic = routing.includeMicrophone
    }

    let parsedMicrophoneSelection = try microphoneSelector.map(parseMicrophoneSelection)

    if !includeMic {
      includeMic = false
      audioDevice = nil
    } else if let parsedMicrophoneSelection {
      switch parsedMicrophoneSelection {
      case .index(let idx):
        guard idx >= 0 && idx < audioDevices.count else {
          print("Error: --mic index out of range (0...\(max(0, audioDevices.count - 1)))")
          return
        }
        audioDevice = audioDevices[idx]
        includeMic = true
      case .id(let id):
        guard let d = audioDevices.first(where: { $0.uniqueID == id }) else {
          print("Error: no microphone with id \(id)")
          return
        }
        audioDevice = d
        includeMic = true
      }
    } else if audioRouting?.includeMicrophone == true {
      guard !audioDevices.isEmpty else {
        print("Error: --audio requires a microphone but none were found")
        return
      }
      audioDevice = audioDevices.first
      includeMic = true
    } else if nonInteractive || audioDevices.isEmpty {
      includeMic = false
      audioDevice = nil
    }

    let parsedCameraSelection = try cameraSelector.map(parseCameraSelection)

    if let parsedCameraSelection {
      includeCamera = true
      switch parsedCameraSelection {
      case .index(let idx):
        guard idx >= 0 && idx < videoDevices.count else {
          print("Error: --camera index out of range (0...\(max(0, videoDevices.count - 1)))")
          return
        }
        cameraDevice = videoDevices[idx]
      case .id(let id):
        guard let d = videoDevices.first(where: { $0.uniqueID == id }) else {
          print("Error: no camera with id \(id)")
          return
        }
        cameraDevice = d
      }
    } else if nonInteractive || videoDevices.isEmpty {
      includeCamera = false
      cameraDevice = nil
    }

    if let c = codecString.flatMap(parseCodec) {
      codec = c
    } else if nonInteractive {
      codec = .h264
    }

    var steps: [WizardStep] = []
    if !nonInteractive && selectedProjectName == nil {
      steps.append(.projectName)
    }
    if !nonInteractive { steps.append(.display) }
    if audioRouting == nil { steps.append(.audio) }
    if parsedMicrophoneSelection == nil && !nonInteractive && !audioDevices.isEmpty {
      steps.append(.microphone)
    }
    if parsedCameraSelection == nil && !nonInteractive && !videoDevices.isEmpty {
      steps.append(.camera)
    }
    if codec == nil { steps.append(.codec) }

    let firstRewindableStepIndex: Int = {
      guard let first = steps.first else { return 0 }
      return first == .display ? 1 : 0
    }()
    func previousRewindableStepIndex(from index: Int) -> Int? {
      guard index > firstRewindableStepIndex else { return nil }
      var i = index - 1
      while i >= firstRewindableStepIndex {
        if steps[i] != .display { return i }
        i -= 1
      }
      return nil
    }

    var singleDisplayLinePrinted = false
    var stepCursor = 0
    func rewind(to backIdx: Int) {
      clearLinesIfTTY(1)
      if steps[backIdx] == .projectName {
        // Remove spacer + project summary so the editable line is re-rendered cleanly.
        clearLinesIfTTY(2)
        singleDisplayLinePrinted = false
      }
      stepCursor = backIdx
    }

    while stepCursor < steps.count {
      let allowBack = previousRewindableStepIndex(from: stepCursor) != nil
      switch steps[stepCursor] {
      case .projectName:
        switch promptEditableDefault(title: "Project Name", defaultValue: defaultProjectName) {
        case .submitted(let value):
          selectedProjectName = sanitizeProjectName(value)
          print("")
          stepCursor += 1
        case .cancel:
          print("Canceled.")
          return
        }

      case .display:
        if isSingleDisplay {
          selectedDisplayIndex = 0
          if !singleDisplayLinePrinted {
            let d = content.displays[0]
            let filter = SCContentFilter(display: d, excludingWindows: [])
            let geometry = captureGeometry(
              filter: filter,
              fallbackLogicalSize: (Int(d.width), Int(d.height))
            )
            let displayTitle = isTTYOut ? TUITheme.primary("Display:") : "Display:"
            print("\(displayTitle) \(optionText("\(geometry.pixelWidth)x\(geometry.pixelHeight)px"))")
            singleDisplayLinePrinted = true
          }
          stepCursor += 1
        } else {
          let displayOptions = content.displays.map(displayLabel)
          let result = selectOptionWithBack(
            title: "Display",
            options: displayOptions,
            defaultIndex: displayDefaultIndex,
            allowBack: allowBack
          )
          switch result {
          case .selected(let idx):
            displayDefaultIndex = idx
            selectedDisplayIndex = idx
            stepCursor += 1
          case .back:
            if let backIdx = previousRewindableStepIndex(from: stepCursor) {
              rewind(to: backIdx)
            }
          case .cancel:
            print("Canceled.")
            return
          }
        }

      case .audio:
        let result = selectOptionWithBack(
          title: "Audio",
          options: ["Mic", "System", "Mic + System", "None"],
          defaultIndex: audioDefaultIndex,
          allowBack: allowBack
        )
        switch result {
        case .selected(let idx):
          audioDefaultIndex = idx
          switch idx {
          case 0: audioRouting = .mic
          case 1: audioRouting = .system
          case 2: audioRouting = .micAndSystem
          default: audioRouting = AudioRouting.none
          }
          includeMic = audioRouting?.includeMicrophone == true
          if !includeMic {
            audioDevice = nil
          } else if audioDevice == nil, !audioDevices.isEmpty {
            audioDevice = audioDevices[min(microphoneDefaultIndex, max(0, audioDevices.count - 1))]
          }
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }

      case .microphone:
        guard includeMic else {
          stepCursor += 1
          continue
        }
        guard !audioDevices.isEmpty else {
          print("No microphones found. Continuing without microphone.")
          includeMic = false
          audioDevice = nil
          stepCursor += 1
          continue
        }
        let options = audioDevices.map(microphoneLabel)
        let result = selectOptionWithBack(
          title: "Microphone",
          options: options,
          defaultIndex: min(microphoneDefaultIndex, max(0, options.count - 1)),
          allowBack: allowBack
        )
        switch result {
        case .selected(let idx):
          microphoneDefaultIndex = idx
          includeMic = true
          audioDevice = audioDevices[idx]
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }

      case .camera:
        let options = ["No camera"] + videoDevices.map(cameraLabel)
        let result = selectOptionWithBack(
          title: "Camera",
          options: options,
          defaultIndex: cameraDefaultIndex,
          allowBack: allowBack
        )
        switch result {
        case .selected(let idx):
          cameraDefaultIndex = idx
          if idx > 0 {
            includeCamera = true
            cameraDevice = videoDevices[idx - 1]
          } else {
            includeCamera = false
            cameraDevice = nil
          }
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }

      case .codec:
        let codecOptions = ["H.264", "H.265/HEVC"]
        let result = selectOptionWithBack(
          title: "Video Codec",
          options: codecOptions,
          defaultIndex: codecDefaultIndex,
          allowBack: allowBack
        )
        switch result {
        case .selected(let idx):
          codecDefaultIndex = idx
          codec = (idx == 0) ? .h264 : .hevc
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }
      }
    }

    guard let selectedDisplayIndex else {
      print("Error: missing display selection.")
      return
    }
    if selectedProjectName == nil {
      selectedProjectName = defaultProjectName
    }
    guard let projectName = selectedProjectName else {
      print("Error: missing project name.")
      return
    }
    guard let audioRouting else {
      print("Error: missing audio selection.")
      return
    }
    guard let codec else {
      print("Error: missing video codec selection.")
      return
    }

    let display = content.displays[selectedDisplayIndex]
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let logicalWidth = Int(display.width)
    let logicalHeight = Int(display.height)
    let geometry = captureGeometry(filter: filter, fallbackLogicalSize: (logicalWidth, logicalHeight))

    if includeMic {
      let micGranted = await requestMicrophoneAccess()
      if !micGranted {
        print("Microphone permission not granted. Continuing without microphone.")
        print("System Settings -> Privacy & Security -> Microphone -> allow this binary.")
        includeMic = false
        audioDevice = nil
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
    let timecodeSync: TimecodeSyncContext? = includeCamera ? TimecodeSyncContext(fps: cfrFPS ?? 60) : nil

    let scaleStr = String(format: "%.2f", geometry.pointPixelScale)

    let recsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("recs")
    try? FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)

    var finalProjectName = projectName

    func directoryExists(_ url: URL) -> Bool {
      var isDir: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
    func directoryNonEmpty(_ url: URL) -> Bool {
      guard directoryExists(url) else { return false }
      let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
      return !contents.isEmpty
    }
    func fileExists(_ url: URL) -> Bool {
      FileManager.default.fileExists(atPath: url.path)
    }
    func ensureUniqueProjectDir(parent: URL, name: String, expectedFilenames: [String]) -> (name: String, dir: URL) {
      func conflicts(dir: URL) -> Bool {
        for f in expectedFilenames {
          if fileExists(dir.appendingPathComponent(f)) { return true }
        }
        return directoryNonEmpty(dir)
      }

      var candidateName = name
      var candidateDir = parent.appendingPathComponent(candidateName, isDirectory: true)
      if !conflicts(dir: candidateDir) { return (candidateName, candidateDir) }

      var i = 2
      while i < 10_000 {
        candidateName = "\(name)-\(i)"
        candidateDir = parent.appendingPathComponent(candidateName, isDirectory: true)
        if !conflicts(dir: candidateDir) { return (candidateName, candidateDir) }
        i += 1
      }
      return (name, parent.appendingPathComponent(name, isDirectory: true))
    }

    let outFile: URL
    let cameraOutFile: URL?
    let cameraFilename: String? = {
      guard includeCamera else { return nil }
      if let cameraDevice { return "\(slugifyFilenameStem(cameraDevice.localizedName)).mov" }
      return "camera.mov"
    }()
    let expected = ["screen.mov"] + (cameraFilename.map { [$0] } ?? [])
    let (uniqueName, projectDir) = ensureUniqueProjectDir(parent: recsDir, name: finalProjectName, expectedFilenames: expected)
    finalProjectName = uniqueName
    try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    outFile = projectDir.appendingPathComponent("screen.mov")
    if includeCamera, let cameraDevice {
      cameraOutFile = projectDir.appendingPathComponent("\(slugifyFilenameStem(cameraDevice.localizedName)).mov")
    } else {
      cameraOutFile = includeCamera ? projectDir.appendingPathComponent("camera.mov") : nil
    }

    let hasMic = includeMic
    let hasSystemAudio = audioRouting.includeSystemAudio

    let meters = LiveMeters()
    let showMeters = Terminal.isTTY(fileno(stderr)) && (hasMic || hasSystemAudio)
    var onAudioLevel: (@Sendable (ScreenRecorder.AudioSource, AudioPeak) -> Void)?
    if showMeters {
      onAudioLevel = { source, peak in meters.update(source: source, peak: peak) }
    }
    let recorderOptions = ScreenRecorder.Options(
      outputURL: outFile,
      videoCodec: codec,
      includeMicrophone: includeMic,
      microphoneDeviceID: includeMic ? audioDevice?.uniqueID : nil,
      includeSystemAudio: audioRouting.includeSystemAudio,
      width: geometry.pixelWidth,
      height: geometry.pixelHeight,
      includeCamera: includeCamera,
      cameraDeviceID: cameraDevice?.uniqueID,
      cameraOutputURL: cameraOutFile,
      onAudioLevel: onAudioLevel,
      timecodeSync: timecodeSync
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
      print(muted("  System audio: \(audioRouting.includeSystemAudio ? "on" : "off")"))
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
      let mixConfig = PostProcess.MixConfig(
        microphoneGainDB: 0,
        systemGainDB: 0,
        safeMixLimiter: safeMixMode.enabled
      )
      try await PostProcess.addMasterAudioTrackIfNeeded(
        url: outFile,
        includeSystemAudio: audioRouting.includeSystemAudio,
        includeMicrophone: includeMic,
        forceMaster: includeCamera,
        mixConfig: mixConfig,
        masterTrackPosition: .first
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
    if let cameraOutFile {
      print(sectionTitle("Files:"))
      print("\(isTTYOut ? TUITheme.label("  Screen:") : "  Screen:") \(abbreviateHomePath(outFile.path))")
      print("\(isTTYOut ? TUITheme.label("  Camera:") : "  Camera:") \(abbreviateHomePath(cameraOutFile.path))")
    } else {
      let savedLabel = isTTYOut ? TUITheme.label("Saved to:") : "Saved to:"
      print("\(savedLabel) \(abbreviateHomePath(outFile.path))")
    }

    if verbose, audioRouting.includeSystemAudio || includeMic {
      let screenHasMaster = (audioRouting.includeSystemAudio || includeMic) && (includeCamera || (audioRouting.includeSystemAudio && includeMic))
      var parts: [String] = []
      if screenHasMaster { parts.append("qaa=Master (mixed)") }
      if includeMic { parts.append("qac=Mic") }
      if audioRouting.includeSystemAudio { parts.append("qab=System") }
      print(muted("  Audio tracks (language tags): " + parts.joined(separator: ", ")))
    }
    if verbose, includeCamera, cameraOutFile != nil {
      print(muted("  Video files: screen=\(outFile.lastPathComponent), camera=\(cameraOutFile!.lastPathComponent)"))
      print(muted("  Camera file audio: a0=Mic (if enabled), a1=Master (mixed, for alignment)"))
    }
    print("")
    // CLI-driven default: open unless explicitly disabled.
    let shouldOpen = !noOpenFlag

    if shouldOpen {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      p.arguments = [outFile.deletingLastPathComponent().path]
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
