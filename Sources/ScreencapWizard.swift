import ArgumentParser
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Darwin

@main
struct Capa: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Native macOS screen recorder (QuickTime-like output).",
    usage: "capa <options> or simply run interactively without any flags",
    version: "0.1.1"
  )

  @Option(
    name: [.short, .customLong("project-name")],
    help: ArgumentHelp("Project folder name (default: capa-<timestamp>)", valueName: "name")
  )
  var projectName: String?

  @Option(name: .customLong("display"), help: "Select display by index (from --list-displays) or displayID")
  var displaySelection: DisplaySelection?

  @Option(name: .customLong("cursor"), help: "Show cursor: on|off")
  var cursorMode: OnOffMode?

  @Option(name: .customLong("menubar"), help: "Show menu bar: on|off")
  var menuBarMode: OnOffMode?

  @Option(name: .customLong("audio"), help: "Audio sources: (none, mic, system, mic+system)")
  var audioRouting: AudioRouting?

  @Option(name: .customLong("mic"), help: "Select microphone by index (from --list-mics) or AVCaptureDevice.uniqueID")
  var microphoneSelection: MicrophoneSelection?

  @Option(name: .customLong("camera"), help: "Record camera by index (from --list-cameras) or AVCaptureDevice.uniqueID")
  var cameraSelection: CameraSelection?

  @Option(name: .customLong("fps"), help: "Screen timing mode: integer CFR fps or 'vfr' (default: vfr, prompts if interactive)")
  var fpsSelection: FPSSelection?

  @Option(name: .customLong("codec"), help: "Video codec (h264|hevc)")
  var codecString: String?

  @Option(name: .customLong("safe-mix"), help: "Safe master limiter: on|off")
  var safeMixMode: OnOffMode = .on

  @Option(name: .customLong("duration"), help: "Auto-stop after N seconds (non-interactive friendly)")
  var durationSeconds: Int?

  @Flag(name: [.customLong("list-displays")], help: "List available displays and exit")
  var listDisplays = false

  @Flag(name: [.customLong("list-mics")], help: "List available microphones and exit")
  var listMicrophones = false

  @Flag(name: [.customLong("list-cameras")], help: "List available cameras and exit")
  var listCameras = false

  @Flag(name: .customLong("no-open"), help: "Do not open file when done")
  var noOpenFlag = false

  @Flag(name: .customLong("non-interactive"), help: "Error instead of prompting for missing options")
  var nonInteractive = false

  @Flag(name: [.short, .customLong("verbose")], help: "Show detailed capture settings/debug output")
  var verbose = false

  mutating func validate() throws {
    if let displaySelection {
      if case .index(let displayIndex) = displaySelection, displayIndex < 0 {
        throw ValidationError("--display must be >= 0 when using an index")
      }
    }
    if let microphoneSelection {
      if case .index(let microphoneIndex) = microphoneSelection, microphoneIndex < 0 {
        throw ValidationError("--mic must be >= 0 when using an index")
      }
    }
    if let cameraSelection {
      if case .index(let cameraIndex) = cameraSelection, cameraIndex < 0 {
        throw ValidationError("--camera must be >= 0 when using an index")
      }
    }
    if let durationSeconds, durationSeconds < 1 {
      throw ValidationError("--duration must be >= 1")
    }
    if let codecString, parseCodec(codecString) == nil {
      throw ValidationError("Invalid --codec: \(codecString) (expected: h264|hevc)")
    }
    if let fpsSelection {
      if case .cfr(let fps) = fpsSelection, fps < 1 {
        throw ValidationError("--fps must be >= 1 when using an integer")
      }
    }
    if let projectName, projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ValidationError("--project-name must not be empty")
    }
    if let routing = audioRouting {
      if !routing.includeMicrophone, microphoneSelection != nil {
        throw ValidationError("--audio does not include microphone; remove --mic or include mic")
      }
    }
  }

  mutating func run() async throws {
    let terminal = TerminalController()
    let isTTYOut = TerminalController.isTTY(STDOUT_FILENO)
    let banner = isTTYOut
      ? "Capa \(TUITheme.label("(native macOS screen capture)"))"
      : "Capa (native macOS screen capture)"
    print(banner)
    print("")

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
      case cursor
      case menuBar
      case audio
      case microphone
      case camera
      case codec
    }

    var selectedDisplayIndex: Int?
    var selectedProjectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
    var selectedCursorMode: OnOffMode? = cursorMode
    var selectedMenuBarMode: OnOffMode? = menuBarMode
    var audioRouting: AudioRouting? = self.audioRouting
    var audioDevice: AVCaptureDevice?
    var includeMic = false
    var cameraDevice: AVCaptureDevice?
    var includeCamera = false
    var codec: AVVideoCodecType?

    var displayDefaultIndex = 0
    var cursorDefaultIndex = 0
    var menuBarDefaultIndex = 0
    var audioDefaultIndex = 1
    var microphoneDefaultIndex = 0
    var cameraDefaultIndex = 0
    var codecDefaultIndex = 0

    if let selection = displaySelection {
      switch selection {
      case .index(let idx):
        if idx >= 0 && idx < content.displays.count {
          selectedDisplayIndex = idx
          displayDefaultIndex = idx
        } else if let id = UInt32(exactly: idx), let resolvedIndex = content.displays.firstIndex(where: { $0.displayID == id }) {
          selectedDisplayIndex = resolvedIndex
          displayDefaultIndex = resolvedIndex
        } else {
          print("Error: --display index out of range (0...\(content.displays.count - 1))")
          return
        }
      case .id(let id):
        guard let resolvedIndex = content.displays.firstIndex(where: { $0.displayID == id }) else {
          print("Error: no display with id \(id)")
          return
        }
        selectedDisplayIndex = resolvedIndex
        displayDefaultIndex = resolvedIndex
      }
    } else if content.displays.count == 1 {
      selectedDisplayIndex = 0
      displayDefaultIndex = 0
    } else if nonInteractive {
      print("Error: missing display selection; use --display (or omit --non-interactive).")
      return
    }

    if nonInteractive && audioRouting == nil {
      audioRouting = AudioRouting.none
    }

    if let routing = audioRouting {
      includeMic = routing.includeMicrophone
    }

    if !includeMic {
      includeMic = false
      audioDevice = nil
    } else if let selection = microphoneSelection {
      switch selection {
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

    if let selection = cameraSelection {
      includeCamera = true
      switch selection {
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
    if displaySelection == nil && !nonInteractive { steps.append(.display) }
    if selectedCursorMode == nil && !nonInteractive { steps.append(.cursor) }
    if selectedMenuBarMode == nil && !nonInteractive { steps.append(.menuBar) }
    if audioRouting == nil { steps.append(.audio) }
    if microphoneSelection == nil && !nonInteractive && !audioDevices.isEmpty {
      steps.append(.microphone)
    }
    if cameraSelection == nil && !nonInteractive && !videoDevices.isEmpty {
      steps.append(.camera)
    }
    if codec == nil { steps.append(.codec) }

    let firstRewindableStepIndex: Int = {
      guard let first = steps.first else { return 0 }
      return first == .display ? 1 : 0
    }()
    func isStepActiveForBackNavigation(_ step: WizardStep) -> Bool {
      switch step {
      case .microphone:
        return includeMic && !audioDevices.isEmpty
      default:
        return true
      }
    }
    func previousRewindableStepIndex(from index: Int) -> Int? {
      guard index > firstRewindableStepIndex else { return nil }
      var i = index - 1
      while i >= firstRewindableStepIndex {
        let candidate = steps[i]
        if candidate != .display, isStepActiveForBackNavigation(candidate) { return i }
        i -= 1
      }
      return nil
    }

    var displaySummaryVisible = false
    var isDisplayCollapsed = false
    var cursorSummaryVisible = false
    var menuBarSummaryVisible = false
    var stepCursor = 0

    func rewind(to backIdx: Int) {
      if isDisplayCollapsed && (steps[backIdx] == .cursor || steps[backIdx] == .menuBar) {
        clearLines(1, isTTY: isTTYOut)
        _ = printDisplaySummary(selectedDisplayIndex: selectedDisplayIndex, content: content, cursor: nil, menuBar: nil, isTTY: isTTYOut)
        cursorSummaryVisible = false
        menuBarSummaryVisible = false

        if steps[backIdx] == .menuBar, let selectedCursorMode {
          let val = selectedCursorMode.enabled ? "Yes" : "No"
          print(renderWizardSummary(label: "Cursor", value: val, isTTY: isTTYOut, indent: 2))
          cursorSummaryVisible = true
        }

        isDisplayCollapsed = false
        stepCursor = backIdx
        return
      }

      clearLines(1, isTTY: isTTYOut)
      if steps[backIdx] == .projectName {
        clearLines(2, isTTY: isTTYOut)
        displaySummaryVisible = false
        cursorSummaryVisible = false
        menuBarSummaryVisible = false
      } else if steps[backIdx] == .display {
        displaySummaryVisible = false
        cursorSummaryVisible = false
        menuBarSummaryVisible = false
      } else if steps[backIdx] == .cursor {
        cursorSummaryVisible = false
        menuBarSummaryVisible = false
      } else if steps[backIdx] == .menuBar {
        menuBarSummaryVisible = false
      }
      stepCursor = backIdx
    }

    while stepCursor < steps.count {
      let currentStep = steps[stepCursor]

      if (currentStep == .cursor || currentStep == .menuBar) && !displaySummaryVisible {
        displaySummaryVisible = printDisplaySummary(selectedDisplayIndex: selectedDisplayIndex, content: content, cursor: selectedCursorMode, menuBar: selectedMenuBarMode, isTTY: isTTYOut)
      }

      let isDisplayGroup = (currentStep == .display || currentStep == .cursor || currentStep == .menuBar)
      if !isDisplayCollapsed && !isDisplayGroup && displaySummaryVisible {
        if isTTYOut {
          if menuBarSummaryVisible { clearLines(1, isTTY: isTTYOut) }
          if cursorSummaryVisible { clearLines(1, isTTY: isTTYOut) }
          clearLines(1, isTTY: isTTYOut)
          _ = printDisplaySummary(selectedDisplayIndex: selectedDisplayIndex, content: content, cursor: selectedCursorMode, menuBar: selectedMenuBarMode, isTTY: isTTYOut)
        }
        cursorSummaryVisible = false
        menuBarSummaryVisible = false
        isDisplayCollapsed = true
      }

      let allowBack = previousRewindableStepIndex(from: stepCursor) != nil
      switch currentStep {
      case .projectName:
        if let next = try await handleProjectNameStep(terminal: terminal, defaultProjectName: defaultProjectName) {
          selectedProjectName = next
          stepCursor += 1
        } else {
          return
        }

      case .display:
        if isSingleDisplay {
          selectedDisplayIndex = 0
          if !displaySummaryVisible {
            displaySummaryVisible = printDisplaySummary(selectedDisplayIndex: selectedDisplayIndex, content: content, cursor: selectedCursorMode, menuBar: selectedMenuBarMode, isTTY: isTTYOut)
          }
          isDisplayCollapsed = false
          stepCursor += 1
        } else {
          let result = selectOptionWithBack(
            terminal: terminal,
            title: "Display",
            options: content.displays.map(displayLabel),
            defaultIndex: displayDefaultIndex,
            allowBack: allowBack
          )
          switch result {
          case .selected(let idx):
            displayDefaultIndex = idx
            selectedDisplayIndex = idx
            displaySummaryVisible = true
            isDisplayCollapsed = false
            cursorSummaryVisible = false
            menuBarSummaryVisible = false
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

      case .cursor:
        let result = selectOptionWithBack(
          terminal: terminal,
          title: "Show Cursor",
          summaryLabel: "Cursor",
          options: ["Yes", "No"],
          defaultIndex: cursorDefaultIndex,
          allowBack: allowBack,
          summaryIndent: 2
        )
        switch result {
        case .selected(let idx):
          cursorDefaultIndex = idx
          selectedCursorMode = (idx == 0) ? .on : .off
          cursorSummaryVisible = true
          isDisplayCollapsed = false
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }

      case .menuBar:
        let result = selectOptionWithBack(
          terminal: terminal,
          title: "Show Menu Bar",
          summaryLabel: "Menu Bar",
          options: ["Yes", "No"],
          defaultIndex: menuBarDefaultIndex,
          allowBack: allowBack,
          summaryIndent: 2
        )
        switch result {
        case .selected(let idx):
          menuBarDefaultIndex = idx
          selectedMenuBarMode = (idx == 0) ? .on : .off
          menuBarSummaryVisible = true
          isDisplayCollapsed = false
          stepCursor += 1
        case .back:
          if let backIdx = previousRewindableStepIndex(from: stepCursor) {
            rewind(to: backIdx)
          }
        case .cancel:
          print("Canceled.")
          return
        }

      case .audio:
        let result = selectOptionWithBack(
          terminal: terminal,
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
        let result = selectOptionWithBack(
          terminal: terminal,
          title: "Microphone",
          options: audioDevices.map(microphoneLabel),
          defaultIndex: min(microphoneDefaultIndex, max(0, audioDevices.count - 1)),
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
          terminal: terminal,
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
        let result = selectOptionWithBack(
          terminal: terminal,
          title: "Video Codec",
          options: ["H.264", "H.265/HEVC"],
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
    filter.includeMenuBar = selectedMenuBarMode?.enabled ?? true
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
    if let selection = fpsSelection {
      switch selection {
      case .vfr:
        cfrFPS = nil
      case .cfr(let fps):
        cfrFPS = max(1, min(240, fps))
      }
    } else {
      // Default to VFR (nil). In interactive mode, we will ask after recording.
      cfrFPS = nil
    }
    let timecodeSync: TimecodeSyncContext? = includeCamera ? TimecodeSyncContext(fps: cfrFPS ?? 60) : nil

    let scaleStr = String(format: "%.2f", geometry.pointPixelScale)

    let recsDir: URL = {
#if DEBUG
      return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("recs", isDirectory: true)
#else
      return URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Desktop", isDirectory: true)
        .appendingPathComponent("capa", isDirectory: true)
#endif
    }()
    try? FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)

    var finalProjectName = projectName

    let outFile: URL
    let cameraOutFile: URL?
    let cameraFilename: String? = {
      guard includeCamera else { return nil }
      if let cameraDevice { return "\(Utils.slugifyFilenameStem(cameraDevice.localizedName)).mov" }
      return "camera.mov"
    }()
    let expected = ["screen.mov"] + (cameraFilename.map { [$0] } ?? [])
    let (uniqueName, projectDir) = Utils.ensureUniqueProjectDir(parent: recsDir, name: finalProjectName, expectedFilenames: expected)
    finalProjectName = uniqueName
    try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    outFile = projectDir.appendingPathComponent("screen.mov")
    if includeCamera, let cameraDevice {
      cameraOutFile = projectDir.appendingPathComponent("\(Utils.slugifyFilenameStem(cameraDevice.localizedName)).mov")
    } else {
      cameraOutFile = includeCamera ? projectDir.appendingPathComponent("camera.mov") : nil
    }

    let hasMic = includeMic
    let hasSystemAudio = audioRouting.includeSystemAudio

    let meters = LiveMeters()
    let showMeters = TerminalController.isTTY(fileno(stderr)) && (hasMic || hasSystemAudio)
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
      showsCursor: selectedCursorMode?.enabled ?? true,
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
      print(sectionTitle("Settings:", isTTY: isTTYOut))
      print(muted("  Capture: \(Int(geometry.sourceRect.width))x\(Int(geometry.sourceRect.height)) pt @ \(scaleStr)x => \(geometry.pixelWidth)x\(geometry.pixelHeight) px", isTTY: isTTYOut))
      print(muted("  Video: \(codecName) \(geometry.pixelWidth)x\(geometry.pixelHeight) @ native refresh", isTTY: isTTYOut))
      if cfrFPS == nil {
        print(muted("  Screen timing: VFR", isTTY: isTTYOut))
      } else {
        print(muted("  Screen timing: CFR \(cfrFPS ?? 60) fps", isTTY: isTTYOut))
      }
      if includeCamera {
        print(muted("  Camera timing: native (no CFR)", isTTY: isTTYOut))
      }
      if includeMic, let audioDevice {
        print(muted("  Microphone: \(audioDevice.localizedName)", isTTY: isTTYOut))
      } else {
        print(muted("  Microphone: none", isTTY: isTTYOut))
      }
      if includeCamera, let cameraDevice {
        print(muted("  Camera: \(cameraDevice.localizedName)", isTTY: isTTYOut))
      } else {
        print(muted("  Camera: none", isTTY: isTTYOut))
      }
      print(muted("  System audio: \(audioRouting.includeSystemAudio ? "on" : "off")", isTTY: isTTYOut))
      print("")
    }
    let canReadKeys = TerminalController.isTTY(STDIN_FILENO)
    if !verbose {
      print("")
    }
    if canReadKeys {
      print("Recording... press 'q' to stop.")
    } else {
      print("Recording...")
    }

    let stopStream = AsyncStream<Void> { continuation in
      let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())

      let keyTask: Task<Void, Never>?
      if canReadKeys {
        keyTask = Task.detached {
          terminal.enableRawMode()
          defer { terminal.disableRawMode() }
          for await key in terminal.keys {
            if case .char(let c) = key, (c == "q" || c == "Q") {
              continuation.yield()
              break
            }
            if case .ctrlC = key {
              continuation.yield()
              break
            }
          }
        }
      } else {
        keyTask = nil
      }

      signal(SIGINT, SIG_IGN)
      sigintSource.setEventHandler { continuation.yield() }
      sigintSource.resume()

      let duration = durationSeconds
        ?? (ProcessInfo.processInfo.environment["SCREENCAP_AUTOSTOP_SECONDS"].flatMap { Int($0) })
      let autoStopTask: Task<Void, Never>?
      if let seconds = duration, seconds > 0 {
        print("Auto-stop: \(seconds)s")
        autoStopTask = Task.detached {
          try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
          continuation.yield()
        }
      } else {
        autoStopTask = nil
      }

      continuation.onTermination = { _ in
        keyTask?.cancel()
        sigintSource.cancel()
        autoStopTask?.cancel()
        signal(SIGINT, SIG_DFL)
      }
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

    for await _ in stopStream {
      break
    }

    do {
      meters.zero()
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
        try await AlignmentMux.addMasterAlignmentTrack(cameraURL: cameraOutFile, screenURL: outFile)
      } catch {
        print("Warning: failed to add alignment track to camera recording: \(error)")
      }
    }

    var finalCFRFPS = cfrFPS
    if finalCFRFPS == nil && !nonInteractive && fpsSelection == nil {
      print("")
      let promptTitle = "Post-process to constant fps? " + (isTTYOut ? TUITheme.label("(Better for video editors, might take a while)") : "(Better for video editors, might take a while)")
      let result = selectOptionWithBack(
        terminal: terminal,
        title: promptTitle,
        options: ["Yes", "No (keep VFR)"],
        defaultIndex: 0,
        allowBack: false,
        printSummary: false
      )
      if case .selected(let idx) = result, idx == 0 {
        let fpsResult = selectOptionWithBack(
          terminal: terminal,
          title: "Select Target FPS",
          options: ["30 fps", "60 fps", "120 fps"],
          defaultIndex: 1, // Default to 60
          allowBack: false,
          printSummary: false
        )
        if case .selected(let fpsIdx) = fpsResult {
          switch fpsIdx {
          case 0: finalCFRFPS = 30
          case 1: finalCFRFPS = 60
          case 2: finalCFRFPS = 120
          default: finalCFRFPS = 60
          }
        }
      }
    }

    var didSkipCFR = false
    if let targetFPS = finalCFRFPS {
      print("")
      print("Post-processing screen video to \(targetFPS) fps...")

      let skipTranscode = SharedFlag(false)
      let transcodeFinished = SharedFlag(false)
      signal(SIGINT, SIG_IGN)
      let transcodeSigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      transcodeSigintSource.setEventHandler { skipTranscode.set() }
      transcodeSigintSource.resume()
      defer {
        transcodeSigintSource.cancel()
        signal(SIGINT, SIG_DFL)
      }

      let transcodeTask = Task {
        defer { transcodeFinished.set() }
        try await VideoCFR.rewriteInPlace(
          url: outFile,
          fps: targetFPS,
          shouldCancel: { skipTranscode.get() },
          cancelHint: "Escape to skip transcoding"
        )
      }

      if TerminalController.isTTY(STDIN_FILENO) {
        terminal.enableRawMode(disableSignals: true)
        defer { terminal.disableRawMode() }
        while true {
          let finished = transcodeFinished.get()
          let skipped = skipTranscode.get()
          if finished || skipped { break }
          if Utils.readTranscodeSkipKey(timeoutMs: 80) {
            skipTranscode.set()
            break
          }
        }
      }

      do {
        try await transcodeTask.value
      } catch is VideoCFR.Cancelled {
        didSkipCFR = true
        if !TerminalController.isTTY(STDERR_FILENO) {
          print("Skipped CFR post-process. Kept the original screen recording timing.")
        }
      } catch {
        print("Warning: CFR post-process failed: \(error)")
      }
    }

    if !didSkipCFR {
      print("")
    }
    if let cameraOutFile {
      print(sectionTitle("Files:", isTTY: isTTYOut))
      print("\(isTTYOut ? TUITheme.label("  Screen:") : "  Screen:") \(Utils.abbreviateHomePath(outFile.path))")
      print("\(isTTYOut ? TUITheme.label("  Camera:") : "  Camera:") \(Utils.abbreviateHomePath(cameraOutFile.path))")
    } else {
      let savedLabel = isTTYOut ? TUITheme.label("Saved to:") : "Saved to:"
      print("\(savedLabel) \(Utils.abbreviateHomePath(outFile.path))")
    }

    if verbose, audioRouting.includeSystemAudio || includeMic {
      let screenHasMaster = (audioRouting.includeSystemAudio || includeMic) && (includeCamera || (audioRouting.includeSystemAudio && includeMic))
      var parts: [String] = []
      if screenHasMaster { parts.append("qaa=Master (mixed)") }
      if includeMic { parts.append("qac=Mic") }
      if audioRouting.includeSystemAudio { parts.append("qab=System") }
      print(muted("  Audio tracks (language tags): " + parts.joined(separator: ", "), isTTY: isTTYOut))
    }
    if verbose, includeCamera, cameraOutFile != nil {
      print(muted("  Video files: screen=\(outFile.lastPathComponent), camera=\(cameraOutFile!.lastPathComponent)", isTTY: isTTYOut))
      print(muted("  Camera file audio: a0=Mic (if enabled), a1=Master (mixed, for alignment)", isTTY: isTTYOut))
    }
    print("")
    let shouldOpen = !noOpenFlag

    if shouldOpen {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      p.arguments = [outFile.deletingLastPathComponent().path]
      try? p.run()
    }
  }

  private func handleProjectNameStep(terminal: TerminalController, defaultProjectName: String) async throws -> String? {
    switch promptEditableDefault(terminal: terminal, title: "Project Name", defaultValue: defaultProjectName) {
    case .submitted(let value):
      let sanitized = Utils.sanitizeProjectName(value)
      print("")
      return sanitized
    case .cancel:
      print("Canceled.")
      return nil
    }
  }

  private func sectionTitle(_ s: String, isTTY: Bool) -> String { isTTY ? TUITheme.title(s) : s }
  private func muted(_ s: String, isTTY: Bool) -> String { isTTY ? TUITheme.muted(s) : s }
  private func optionText(_ s: String, isTTY: Bool) -> String { isTTY ? TUITheme.option(s) : s }

  private func clearPreviousAnswerLine(isTTY: Bool) {
    guard isTTY else { return }
    print("\u{001B}[1A\u{001B}[2K\r", terminator: "")
  }

  private func clearLines(_ count: Int, isTTY: Bool) {
    guard count > 0 else { return }
    for _ in 0..<count { clearPreviousAnswerLine(isTTY: isTTY) }
  }

  private func displayConfigurationDescription(geometry: CaptureGeometry, cursor: OnOffMode?, menuBar: OnOffMode?) -> String {
    let base = "\(geometry.pixelWidth)x\(geometry.pixelHeight)px"
    let c = cursor?.enabled ?? true
    let m = menuBar?.enabled ?? true

    if c && m {
      if cursor == nil && menuBar == nil {
        return base
      }
      return "\(base) (full)"
    }
    if !c && !m {
      return "\(base) (no cursor & menu bar)"
    }
    if !c {
      return "\(base) (no cursor)"
    }
    return "\(base) (no menu bar)"
  }

  private func selectedDisplayGeometry(selectedDisplayIndex: Int?, content: SCShareableContent) -> CaptureGeometry? {
    guard let idx = selectedDisplayIndex else { return nil }
    let d = content.displays[idx]
    let f = SCContentFilter(display: d, excludingWindows: [])
    return captureGeometry(filter: f, fallbackLogicalSize: (Int(d.width), Int(d.height)))
  }

  private func printDisplaySummary(selectedDisplayIndex: Int?, content: SCShareableContent, cursor: OnOffMode?, menuBar: OnOffMode?, isTTY: Bool) -> Bool {
    guard let geometry = selectedDisplayGeometry(selectedDisplayIndex: selectedDisplayIndex, content: content) else { return false }
    let desc = displayConfigurationDescription(geometry: geometry, cursor: cursor, menuBar: menuBar)
    print(renderWizardSummary(label: "Display", value: desc, isTTY: isTTY))
    return true
  }
}
