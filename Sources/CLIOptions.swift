import AVFoundation
import Foundation

struct CLIOptions: Sendable {
  var help = false
  var nonInteractive = false

  var listDisplays = false
  var listMicrophones = false

  var displayIndex: Int?
  var displayID: UInt32?

  var noMicrophone = false
  var microphoneIndex: Int?
  var microphoneID: String?

  /// Capture system audio to a separate track.
  var includeSystemAudio = false

  var codec: AVVideoCodecType?
  /// `0` means "native refresh rate" (passes `kCMTimeZero` to ScreenCaptureKit).
  var fps: Int = 60
  var durationSeconds: Int?

  var outputPath: String?
  var openWhenDone: Bool? // nil => prompt in interactive mode

  static func parse(_ argv: [String]) throws -> CLIOptions {
    var out = CLIOptions()

    func takeValue(_ argv: [String], _ i: inout Int) throws -> String {
      i += 1
      guard i < argv.count else {
        throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing value for \(argv[i - 1])"])
      }
      return argv[i]
    }

    var i = 1
    while i < argv.count {
      let a = argv[i]

      func parseInt(_ s: String, _ flag: String) throws -> Int {
        guard let v = Int(s) else {
          throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid \(flag): \(s)"])
        }
        return v
      }

      func parseUInt32(_ s: String, _ flag: String) throws -> UInt32 {
        guard let v = UInt32(s) else {
          throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid \(flag): \(s)"])
        }
        return v
      }

      if a == "--help" || a == "-h" {
        out.help = true
        i += 1
        continue
      }

      if a == "--non-interactive" {
        out.nonInteractive = true
        i += 1
        continue
      }

      if a == "--list-displays" {
        out.listDisplays = true
        i += 1
        continue
      }

      if a == "--list-mics" || a == "--list-microphones" {
        out.listMicrophones = true
        i += 1
        continue
      }

      if a == "--display-index" {
        let v = try parseInt(try takeValue(argv, &i), a)
        out.displayIndex = v
        i += 1
        continue
      }
      if a.hasPrefix("--display-index=") {
        let v = String(a.split(separator: "=", maxSplits: 1)[1])
        out.displayIndex = try parseInt(v, "--display-index")
        i += 1
        continue
      }

      if a == "--display-id" {
        let v = try parseUInt32(try takeValue(argv, &i), a)
        out.displayID = v
        i += 1
        continue
      }
      if a.hasPrefix("--display-id=") {
        let v = String(a.split(separator: "=", maxSplits: 1)[1])
        out.displayID = try parseUInt32(v, "--display-id")
        i += 1
        continue
      }

      if a == "--no-mic" || a == "--no-microphone" {
        out.noMicrophone = true
        i += 1
        continue
      }

      if a == "--system-audio" {
        out.includeSystemAudio = true
        i += 1
        continue
      }

      if a == "--mic-index" || a == "--microphone-index" {
        let v = try parseInt(try takeValue(argv, &i), a)
        out.microphoneIndex = v
        i += 1
        continue
      }
      if a.hasPrefix("--mic-index=") {
        let v = String(a.split(separator: "=", maxSplits: 1)[1])
        out.microphoneIndex = try parseInt(v, "--mic-index")
        i += 1
        continue
      }

      if a == "--mic-id" || a == "--microphone-id" {
        out.microphoneID = try takeValue(argv, &i)
        i += 1
        continue
      }
      if a.hasPrefix("--mic-id=") {
        out.microphoneID = String(a.split(separator: "=", maxSplits: 1)[1])
        i += 1
        continue
      }

      if a == "--codec" {
        let v = try takeValue(argv, &i).lowercased()
        out.codec = try parseCodec(v)
        i += 1
        continue
      }
      if a.hasPrefix("--codec=") {
        let v = String(a.split(separator: "=", maxSplits: 1)[1]).lowercased()
        out.codec = try parseCodec(v)
        i += 1
        continue
      }

      if a == "--fps" {
        let v = try parseInt(try takeValue(argv, &i), a)
        out.fps = max(0, min(240, v))
        i += 1
        continue
      }
      if a.hasPrefix("--fps=") {
        let v = try parseInt(String(a.split(separator: "=", maxSplits: 1)[1]), "--fps")
        out.fps = max(0, min(240, v))
        i += 1
        continue
      }

      if a == "--duration" {
        let v = try parseInt(try takeValue(argv, &i), a)
        out.durationSeconds = max(1, v)
        i += 1
        continue
      }
      if a.hasPrefix("--duration=") {
        let v = try parseInt(String(a.split(separator: "=", maxSplits: 1)[1]), "--duration")
        out.durationSeconds = max(1, v)
        i += 1
        continue
      }

      if a == "--out" || a == "--output" {
        out.outputPath = try takeValue(argv, &i)
        i += 1
        continue
      }
      if a.hasPrefix("--out=") {
        out.outputPath = String(a.split(separator: "=", maxSplits: 1)[1])
        i += 1
        continue
      }

      if a == "--open" {
        out.openWhenDone = true
        i += 1
        continue
      }
      if a == "--no-open" {
        out.openWhenDone = false
        i += 1
        continue
      }

      throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(a)"])
    }

    return out
  }

  private static func parseCodec(_ s: String) throws -> AVVideoCodecType {
    switch s {
    case "h264", "avc", "avc1":
      return .h264
    case "hevc", "h265", "hvc", "hvc1":
      return .hevc
    default:
      throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid --codec: \(s) (expected: h264|hevc)"])
    }
  }

  static func usage(exe: String) -> String {
    """
    Usage:
      \(exe) [options]

    Options:
      --list-displays                 List available displays and exit
      --list-mics                     List available microphones and exit
      --display-index N               Select display by index (from --list-displays)
      --display-id ID                 Select display by CGDirectDisplayID
      --no-mic                        Disable microphone
      --mic-index N                   Select microphone by index (from --list-mics)
      --mic-id ID                     Select microphone by AVCaptureDevice.uniqueID
      --system-audio                  Capture system audio to a separate track
      --codec h264|hevc               Video codec (default: prompt / h264)
      --fps N                         Capture update rate hint (0=native refresh, default: 60)
      --duration SECONDS              Auto-stop after N seconds (non-interactive friendly)
      --out PATH                      Output file path (default: recs/screen-<ts>.mov)
      --open | --no-open              Open file when done (default: prompt in interactive mode)
      --non-interactive               Error instead of prompting for missing options
      -h, --help                      Show help
    """
  }
}
