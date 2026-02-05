import Foundation
import Darwin

enum Ansi {
  static let reset = "\u{001B}[0m"
  static let hideCursor = "\u{001B}[?25l"
  static let showCursor = "\u{001B}[?25h"

  static func fg256(_ n: Int) -> String { "\u{001B}[38;5;\(n)m" }
  static func bg256(_ n: Int) -> String { "\u{001B}[48;5;\(n)m" }

  static func visibleWidth(_ s: String) -> Int {
    // Best-effort terminal "cell" width, ignoring ANSI escape sequences and common zero-width scalars.
    var count = 0
    var it = s.unicodeScalars.makeIterator()
    while let sc = it.next() {
      if sc.value == 0x1B { // ESC
        // Skip CSI: ESC [ ... <final-byte>
        if let next = it.next(), next.value == 0x5B { // '['
          while let c = it.next() {
            let v = c.value
            if (v >= 0x40 && v <= 0x7E) { break } // final byte
          }
        }
        continue
      }

      // Variation selectors / combining marks generally have zero width.
      if sc.value == 0xFE0E || sc.value == 0xFE0F { continue }
      if sc.properties.isGraphemeExtend { continue }

      count += 1
    }
    return count
  }
}

struct Bar {
  enum Style {
    /// A smooth bar with 1/8-cell partial blocks.
    case smooth
    /// A stepped meter (8 levels) using Unicode "height" blocks.
    case steps
  }

  static func render(fraction: Double, width: Int, style: Style) -> String {
    let w = max(1, width)
    let t = max(0.0, min(1.0, fraction))
    switch style {
    case .smooth:
      // Render in 1/8th-cell units.
      let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
      let units = Int((Double(w) * 8.0 * t).rounded(.toNearestOrAwayFromZero))
      let full = min(w, units / 8)
      let rem = units % 8
      let hasPartial = rem > 0 && full < w
      let rest = w - full - (hasPartial ? 1 : 0)

      // Use full blocks for both filled and unfilled; color determines meaning.
      return String(repeating: "█", count: full)
        + (hasPartial ? partial[rem] : "")
        + String(repeating: "█", count: max(0, rest))

    case .steps:
      let chars = Array("▁▂▃▄▅▆▇█")
      let idx = min(chars.count - 1, max(0, Int((Double(chars.count - 1) * t).rounded(.toNearestOrAwayFromZero))))
      return String(chars[idx])
    }
  }
}

final class ProgressBar: @unchecked Sendable {
  private let fd: UnsafeMutablePointer<FILE> = stderr
  private let prefix: String
  private let total: Int64
  private var lastVisibleLen = 0
  private var lastUnits: Int = -1
  private var active = false

  init(prefix: String, total: Int64) {
    self.prefix = prefix
    self.total = max(1, total)
  }

  func startIfTTY() {
    guard isatty(fileno(fd)) != 0 else { return }
    active = true
    write(Ansi.hideCursor)
  }

  func update(completed: Int64) {
    guard active else { return }
    let clamped = max(0, min(total, completed))

    let width = 24
    let units = Int((Double(clamped) / Double(total)) * Double(width * 8))
    if units == lastUnits { return }
    lastUnits = units

    let pct = Int((Double(clamped) / Double(total)) * 100.0)
    let frac = Double(clamped) / Double(total)

    // Track + fill colors. Use background on the partial cell to avoid "gaps" showing terminal background.
    let track = 236
    let fill = 255
    let bar = Bar.renderColoredSmooth(fraction: frac, width: width, fillFG: fill, trackFG: track, trackBG: track)
    let lead = prefix.isEmpty ? "" : "\(prefix) "
    let s = "\(lead)\(bar)\(Ansi.reset) \(pct)%"

    let visibleLen = Ansi.visibleWidth(s)
    let pad = max(0, lastVisibleLen - visibleLen)
    lastVisibleLen = visibleLen
    write("\r" + s + String(repeating: " ", count: pad))
  }

  func stop() {
    guard active else { return }
    active = false
    update(completed: total)
    write("\n")
    write(Ansi.showCursor)
  }

  private func write(_ s: String) {
    s.withCString { cstr in
      fputs(cstr, fd)
      fflush(fd)
    }
  }
}

struct LoudnessMeter {
  /// Map dBFS to a 0...1 fraction for bar fill.
  static func fraction(db: Float) -> Double {
    // Clamp to a range that makes sense for a visual meter.
    let floor: Float = -60
    let t = max(0, min(1, (db - floor) / (0 - floor)))
    return Double(t)
  }

  static func color(db: Float) -> String {
    // Rough levels for screen recording.
    if db >= -12 { return Ansi.fg256(196) } // red
    if db >= -24 { return Ansi.fg256(226) } // yellow
    return Ansi.fg256(46) // green
  }

  static func render(label: String, db: Float?, width: Int = 12, style: Bar.Style = .smooth) -> String {
    let reset = Ansi.reset
    guard let db else {
      let c = Ansi.fg256(245)
      let bar: String
      switch style {
      case .smooth:
        bar = Bar.renderColoredSmooth(fraction: 0, width: width, fillFG: 245, trackFG: 236, trackBG: 236)
      case .steps:
        bar = c + Bar.render(fraction: 0, width: width, style: .steps)
      }
      return "\(label) \(c)--dB \(bar)\(reset)"
    }

    let c = color(db: db)
    let frac = fraction(db: db)
    let dbStr = String(format: "%@%3.0fdB%@", c, db, reset)
    let bar: String
    switch style {
    case .smooth:
      // For meters, use the db-driven color as the fill, and a fixed dark track.
      // The color escape in `c` is a foreground; extract the 256 code where possible is not worth it.
      // Just use green/yellow/red as 46/226/196.
      let fillFG: Int = (db >= -12) ? 196 : (db >= -24) ? 226 : 46
      bar = Bar.renderColoredSmooth(fraction: frac, width: width, fillFG: fillFG, trackFG: 236, trackBG: 236)
    case .steps:
      bar = c + Bar.render(fraction: frac, width: width, style: .steps)
    }

    return "\(label) \(dbStr) \(bar)\(reset)"
  }
}

extension Bar {
  static func renderColoredSmooth(fraction: Double, width: Int, fillFG: Int, trackFG: Int, trackBG: Int) -> String {
    let w = max(1, width)
    let t = max(0.0, min(1.0, fraction))
    let units = Int((Double(w) * 8.0 * t).rounded(.toNearestOrAwayFromZero))
    let full = min(w, units / 8)
    let rem = units % 8
    let hasPartial = rem > 0 && full < w
    let rest = w - full - (hasPartial ? 1 : 0)

    let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    var s = Ansi.bg256(trackBG)
    if full > 0 {
      s += Ansi.fg256(fillFG) + String(repeating: "█", count: full)
    }
    if hasPartial {
      s += Ansi.fg256(fillFG) + partial[rem]
    }
    if rest > 0 {
      s += Ansi.fg256(trackFG) + String(repeating: "█", count: rest)
    }
    return s
  }
}
