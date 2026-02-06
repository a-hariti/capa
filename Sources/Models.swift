import ArgumentParser
import AVFoundation
import Foundation

enum OnOffMode: String, ExpressibleByArgument, Sendable {
  case on
  case off

  var enabled: Bool { self == .on }
}

struct AudioRouting: Equatable, Sendable, ExpressibleByArgument {
  var includeMicrophone: Bool
  var includeSystemAudio: Bool

  static let none = AudioRouting(includeMicrophone: false, includeSystemAudio: false)
  static let mic = AudioRouting(includeMicrophone: true, includeSystemAudio: false)
  static let system = AudioRouting(includeMicrophone: false, includeSystemAudio: true)
  static let micAndSystem = AudioRouting(includeMicrophone: true, includeSystemAudio: true)

  init(includeMicrophone: Bool, includeSystemAudio: Bool) {
    self.includeMicrophone = includeMicrophone
    self.includeSystemAudio = includeSystemAudio
  }

  init?(argument raw: String) {
    let normalized = raw.lowercased().replacingOccurrences(of: " ", with: "")
    if normalized.isEmpty || normalized == "none" {
      self = .none
      return
    }

    var mic = false
    var sys = false
    var sawToken = false

    for tokenSub in normalized.split(separator: "+", omittingEmptySubsequences: true) {
      let token = String(tokenSub)
      sawToken = true
      switch token {
      case "mic", "microphone":
        mic = true
      case "sys", "system":
        sys = true
      default:
        return nil
      }
    }

    if !sawToken { return nil }
    self.init(includeMicrophone: mic, includeSystemAudio: sys)
  }
}

enum CameraSelection: Sendable, ExpressibleByArgument {
  case index(Int)
  case id(String)

  init?(argument: String) {
    let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    if let index = Int(value) {
      self = .index(index)
    } else {
      self = .id(value)
    }
  }
}

enum DisplaySelection: Sendable, ExpressibleByArgument {
  case index(Int)
  case id(UInt32)

  init?(argument: String) {
    let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    if let index = Int(value) {
      self = .index(index)
    } else if let id = UInt32(value) {
      self = .id(id)
    } else {
      return nil
    }
  }
}

enum FPSSelection: Sendable, ExpressibleByArgument {
  case cfr(Int)
  case vfr

  init?(argument: String) {
    let value = argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if value.isEmpty { return nil }
    if value == "vfr" {
      self = .vfr
    } else if let fps = Int(value) {
      self = .cfr(fps)
    } else {
      return nil
    }
  }
}

enum MicrophoneSelection: Sendable, ExpressibleByArgument {
  case index(Int)
  case id(String)

  init?(argument: String) {
    let value = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    if let index = Int(value) {
      self = .index(index)
    } else {
      self = .id(value)
    }
  }
}

func parseCodec(_ s: String) -> AVVideoCodecType? {
  switch s.lowercased() {
  case "h264", "avc", "avc1":
    return .h264
  case "hevc", "h265", "hvc", "hvc1":
    return .hevc
  default:
    return nil
  }
}