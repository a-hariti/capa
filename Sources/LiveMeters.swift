import Foundation

final class LiveMeters: @unchecked Sendable {
  private let lock = NSLock()
  private struct State {
    var db: Float?
    var holdDB: Float?
    var holdUntil: Double = 0
    var clipUntil: Double = 0
  }

  private var mic = State()
  private var sys = State()

  // Simple EMA smoothing so the meter isn't too twitchy.
  private let alpha: Float = 0.20
  private let holdSeconds: Double = 1.0
  private let clipSeconds: Double = 0.8

  func update(source: ScreenRecorder.AudioSource, peak: AudioPeak) {
    lock.lock()
    defer { lock.unlock() }

    let now = CFAbsoluteTimeGetCurrent()
    let clamped = max(-80, min(0, peak.db))
    switch source {
    case .microphone:
      mic.db = smooth(old: mic.db, new: clamped)
      if mic.holdDB == nil || clamped >= (mic.holdDB ?? clamped) || now >= mic.holdUntil {
        mic.holdDB = clamped
        mic.holdUntil = now + holdSeconds
      }
      if peak.clipped {
        mic.clipUntil = now + clipSeconds
      }
    case .system:
      sys.db = smooth(old: sys.db, new: clamped)
      if sys.holdDB == nil || clamped >= (sys.holdDB ?? clamped) || now >= sys.holdUntil {
        sys.holdDB = clamped
        sys.holdUntil = now + holdSeconds
      }
      if peak.clipped {
        sys.clipUntil = now + clipSeconds
      }
    }
  }

  func zero() {
    lock.lock()
    defer { lock.unlock() }
    mic = State()
    sys = State()
  }

  func render(includeMicrophone: Bool, includeSystemAudio: Bool) -> String {
    let now = CFAbsoluteTimeGetCurrent()
    lock.lock()
    let micDB = mic.db
    let micHold = (now <= mic.holdUntil) ? mic.holdDB : nil
    let micClipped = now <= mic.clipUntil
    let sysDB = sys.db
    let sysHold = (now <= sys.holdUntil) ? sys.holdDB : nil
    let sysClipped = now <= sys.clipUntil
    lock.unlock()

    let theme = TUITheme(isTTY: TerminalController.isTTY(fileno(stderr)))
    var parts: [String] = []
    if includeMicrophone {
      parts.append(LoudnessMeter.render(label: "MIC", db: micDB, holdDB: micHold, clipped: micClipped, width: 12, style: .smooth, theme: theme))
    }
    if includeSystemAudio {
      parts.append(LoudnessMeter.render(label: "SYS", db: sysDB, holdDB: sysHold, clipped: sysClipped, width: 12, style: .smooth, theme: theme))
    }
    return parts.joined(separator: "  ")
  }

  private func smooth(old: Float?, new: Float) -> Float {
    guard let old else { return new }
    return old * (1 - alpha) + new * alpha
  }
}
