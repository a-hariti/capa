import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit
import Darwin

@main
struct ScreencapWizard {
  static func main() async {
    let argv = CommandLine.arguments
    let exe = (argv.first as NSString?)?.lastPathComponent ?? "capa"

    let opts: CLIOptions
    do {
      opts = try CLIOptions.parse(argv)
    } catch {
      print("Error: \(error)")
      print("")
      print(CLIOptions.usage(exe: exe))
      return
    }

    if opts.help {
      print(CLIOptions.usage(exe: exe))
      return
    }

    print("capa (Native macOS Screen Capture)")

    if opts.listMicrophones {
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

    if !requestScreenRecordingAccess() {
      print("Screen recording permission not granted.")
      print("System Settings -> Privacy & Security -> Screen Recording -> allow this binary.")
      return
    }

    let content: SCShareableContent
    do {
      content = try loadShareableContentSync()
    } catch {
      print("Failed to load shareable content: \(error)")
      return
    }

    guard !content.displays.isEmpty else {
      print("No displays found.")
      return
    }

    if opts.listDisplays {
      for (i, d) in content.displays.enumerated() {
        print("[\(i)] \(displayLabel(d))")
      }
      return
    }

    let display: SCDisplay
    if let idx = opts.displayIndex {
      guard idx >= 0 && idx < content.displays.count else {
        print("Error: --display-index out of range (0...\(content.displays.count - 1))")
        return
      }
      display = content.displays[idx]
    } else if let id = opts.displayID {
      guard let d = content.displays.first(where: { $0.displayID == id }) else {
        print("Error: no display with id \(id)")
        return
      }
      display = d
    } else if opts.nonInteractive {
      print("Error: missing display selection; use --display-index or --display-id (or omit --non-interactive).")
      return
    } else {
      let displayOptions = content.displays.map(displayLabel)
      let displayIdx = selectOption(title: "Display", options: displayOptions, defaultIndex: 0)
      display = content.displays[displayIdx]
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])

    let audioDevices = AVCaptureDevice.DiscoverySession(
      deviceTypes: [.microphone, .external],
      mediaType: .audio,
      position: .unspecified
    ).devices

    let includeSystemAudio: Bool
    if opts.nonInteractive {
      includeSystemAudio = opts.includeSystemAudio
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
    if opts.noMicrophone {
      includeMic = false
    } else if let idx = opts.microphoneIndex {
      guard idx >= 0 && idx < audioDevices.count else {
        print("Error: --mic-index out of range (0...\(max(0, audioDevices.count - 1)))")
        return
      }
      audioDevice = audioDevices[idx]
      includeMic = true
    } else if let id = opts.microphoneID {
      guard let d = audioDevices.first(where: { $0.uniqueID == id }) else {
        print("Error: no microphone with id \(id)")
        return
      }
      audioDevice = d
      includeMic = true
    } else if opts.nonInteractive {
      includeMic = false
    } else if !audioDevices.isEmpty {
      let audioOptions = ["No microphone"] + audioDevices.map(microphoneLabel)
      let title = includeSystemAudio
        ? "Microphone (optional; can sound echoey if it picks up speakers)"
        : "Microphone"
      let audioIdx = selectOption(title: title, options: audioOptions, defaultIndex: 0)
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

    let codec: AVVideoCodecType
    if let c = opts.codec {
      codec = c
    } else if opts.nonInteractive {
      codec = .h264
    } else {
      let codecOptions = ["H.264", "H.265/HEVC"]
      // QuickTime screen recordings default to H.264; keep that as our default as well.
      let codecIdx = selectOption(title: "Video Codec", options: codecOptions, defaultIndex: 0)
      codec = (codecIdx == 0) ? .h264 : .hevc
    }

    let logicalWidth = Int(display.width)
    let logicalHeight = Int(display.height)
    let geometry = captureGeometry(filter: filter, fallbackLogicalSize: (logicalWidth, logicalHeight))
    let scaleStr = String(format: "%.2f", geometry.pointPixelScale)
    print("Capture: \(Int(geometry.sourceRect.width))x\(Int(geometry.sourceRect.height)) pt @ \(scaleStr)x => \(geometry.pixelWidth)x\(geometry.pixelHeight) px")

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let ts = formatter.string(from: Date())

    let recsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("recs")
    try? FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)

    let outFile: URL
    if let outputPath = opts.outputPath {
      let u = URL(fileURLWithPath: outputPath)
      if u.pathExtension.isEmpty {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        outFile = u.appendingPathComponent("screen-\(ts).mov")
      } else {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        outFile = u
      }
    } else {
      outFile = recsDir.appendingPathComponent("screen-\(ts).mov")
    }
    let recorderOptions = ScreenRecorder.Options(
      outputURL: outFile,
      videoCodec: codec,
      includeMicrophone: includeMic,
      microphoneDeviceID: includeMic ? audioDevice?.uniqueID : nil,
      includeSystemAudio: includeSystemAudio,
      width: geometry.pixelWidth,
      height: geometry.pixelHeight,
      fps: opts.fps
    )
    let recorder = ScreenRecorder(filter: filter, options: recorderOptions)

    let codecName = (codec == .hevc) ? "H.265/HEVC" : "H.264"
    print("Settings:")
    if opts.fps == 0 {
      print("  Video: \(codecName) \(geometry.pixelWidth)x\(geometry.pixelHeight) @ native refresh")
    } else {
      print("  Video: \(codecName) \(geometry.pixelWidth)x\(geometry.pixelHeight) @ \(opts.fps) fps")
    }
    if includeMic, let audioDevice {
      print("  Microphone: \(audioDevice.localizedName)")
    } else {
      print("  Microphone: none")
    }
    print("  System audio: \(includeSystemAudio ? "on" : "off")")
    print("Output file: \(outFile.path)")
    let canReadKeys = Terminal.isTTY(STDIN_FILENO)
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

    let duration = opts.durationSeconds
      ?? (ProcessInfo.processInfo.environment["SCREENCAP_AUTOSTOP_SECONDS"].flatMap { Int($0) })
    if let seconds = duration, seconds > 0 {
      print("Auto-stop: \(seconds)s")
      DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) { stopSignal.signal() }
    }

    let ticker = ElapsedTicker()

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
      try PostProcess.addMasterAudioTrackIfNeeded(
        url: outFile,
        includeSystemAudio: includeSystemAudio,
        includeMicrophone: includeMic
      )
    } catch {
      print("Warning: failed to post-process audio tracks: \(error)")
    }

    print("Saved.")
    if includeSystemAudio || includeMic {
      var parts: [String] = []
      parts.append("qaa=Master (mixed)")
      if includeSystemAudio { parts.append("qab=System") }
      if includeMic { parts.append("qac=Mic") }
      print("Audio tracks (language tags): " + parts.joined(separator: ", "))
    }
    let shouldOpen: Bool
    if let openWhenDone = opts.openWhenDone {
      shouldOpen = openWhenDone
    } else if opts.nonInteractive {
      shouldOpen = false
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

private func loadShareableContentSync() throws -> SCShareableContent {
  final class Box: @unchecked Sendable {
    var content: SCShareableContent?
    var error: Error?
  }
  let box = Box()
  let sema = DispatchSemaphore(value: 0)

  SCShareableContent.getWithCompletionHandler { content, error in
    box.content = content
    box.error = error
    sema.signal()
  }

  sema.wait()
  if let err = box.error { throw err }
  guard let result = box.content else {
    throw NSError(domain: "ScreencapWizard", code: 1, userInfo: [NSLocalizedDescriptionKey: "No SCShareableContent returned"])
  }
  return result
}
