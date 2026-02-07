import Foundation
import Darwin

enum Ansi {
  static let escape = "\u{001B}"
  static let reset = "\u{001B}[0m"
  static let hideCursor = "\u{001B}[?25l"
  static let showCursor = "\u{001B}[?25h"
  static let bold = "\u{001B}[1m"
  static let dim = "\u{001B}[2m"
  static let clearLine = "\u{001B}[2K"
  static let carriageReturn = "\r"

  static func fg256(_ n: Int) -> String { "\u{001B}[38;5;\(n)m" }
  static func bg256(_ n: Int) -> String { "\u{001B}[48;5;\(n)m" }
  static func cursorUp(_ lines: Int) -> String { "\(escape)[\(max(0, lines))A" }
  static func cursorDown(_ lines: Int) -> String { "\(escape)[\(max(0, lines))B" }

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

struct TUITheme: Sendable, Codable {
  let isTTY: Bool

  enum Color {
    static let title = 255
    static let label = 252
    static let option = 250
    static let muted = 244
    static let accent = 39
    static let progressFill = 244
    static let track = 236
    static let meterLow = 46
    static let meterMid = 226
    static let meterHot = 196
    static let meterIdle = 245
    static let recordingDot = 196
  }

  enum Glyph {
    static let pickerCaret = "▸"
    static let pickerHintSep = " • "
  }

  init(isTTY: Bool) {
    self.isTTY = isTTY
  }

  func title(_ s: String) -> String {
    ansi(s, seq: "\(Ansi.bold)\(Ansi.fg256(Color.title))")
  }

  func primary(_ s: String) -> String {
    ansi(s, seq: Ansi.fg256(Color.title))
  }

  func label(_ s: String) -> String {
    ansi(s, seq: Ansi.fg256(Color.label))
  }

  func option(_ s: String) -> String {
    ansi(s, seq: Ansi.fg256(Color.option))
  }

  func muted(_ s: String) -> String {
    ansi(s, seq: "\(Ansi.dim)\(Ansi.fg256(Color.muted))")
  }

  func accent(_ s: String, bold: Bool = false) -> String {
    ansi(s, seq: (bold ? Ansi.bold : "") + Ansi.fg256(Color.accent))
  }

  func recordingDot(_ s: String) -> String {
    ansi(s, seq: "\(Ansi.bold)\(Ansi.fg256(Color.recordingDot))")
  }

  /// Apply ANSI sequence if isTTY, otherwise return unstyled string.
  private func ansi(_ s: String, seq: String) -> String {
    isTTY ? "\(seq)\(s)\(Ansi.reset)" : s
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
  private let theme: TUITheme
  private let prefix: String
  private let total: Int64
  private let subtitle: String?
  private var lastVisibleLen = 0
  private var lastUnits: Int = -1
  private var active = false
  private var subtitleRendered = false

  init(prefix: String, total: Int64, subtitle: String? = nil) {
    self.theme = TUITheme(isTTY: TerminalController.isTTY(fileno(stderr)))
    self.prefix = prefix
    self.total = max(1, total)
    self.subtitle = Self.normalized(subtitle)
  }

  func startIfTTY() {
    guard theme.isTTY else { return }
    active = true
    write(Ansi.hideCursor)
    if let subtitle {
      // Reserve two lines under the bar so there's a blank separator line.
      write("\n\n")
      write(theme.label(subtitle))
      write(Ansi.cursorUp(2) + Ansi.carriageReturn)
      subtitleRendered = true
    }
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
    let bar = Bar.renderColoredSmooth(
      fraction: frac,
      width: width,
      fillFG: TUITheme.Color.progressFill,
      trackFG: TUITheme.Color.track,
      trackBG: TUITheme.Color.track
    )
    let lead = prefix.isEmpty ? "" : "\(prefix) "
    let s = "\(lead)\(bar)\(Ansi.reset) \(theme.label("\(pct)%"))"

    let visibleLen = Ansi.visibleWidth(s)
    let pad = max(0, lastVisibleLen - visibleLen)
    lastVisibleLen = visibleLen
    write(Ansi.carriageReturn + s + String(repeating: " ", count: pad))
  }

  func stop(finalSubtitle: String? = nil) {
    guard active else { return }
    active = false
    update(completed: total)
    let finalLine = Self.normalized(finalSubtitle)
    if subtitleRendered {
      write(Ansi.cursorDown(2) + Ansi.carriageReturn)
      if let finalLine {
        write(Ansi.clearLine + Ansi.carriageReturn)
        write(theme.label(finalLine))
      }
      write("\n")
      subtitleRendered = false
    } else {
      if let finalLine {
        write("\n")
        write(theme.label(finalLine))
      }
      write("\n")
    }
    write(Ansi.showCursor)
  }

  private func write(_ s: String) {
    s.withCString { cstr in
      fputs(cstr, fd)
      fflush(fd)
    }
  }

  private static func normalized(_ line: String?) -> String? {
    guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return line
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

  static func colorCode(db: Float) -> Int {
    if db >= -6 { return TUITheme.Color.meterHot } // red
    if db >= -18 { return TUITheme.Color.meterMid } // yellow
    return TUITheme.Color.meterLow // green
  }

  static func color(db: Float) -> String {
    Ansi.fg256(colorCode(db: db))
  }

  static func render(label: String, db: Float?, holdDB: Float? = nil, clipped: Bool = false, width: Int = 12, style: Bar.Style = .smooth, theme: TUITheme) -> String {
    let reset = Ansi.reset
    guard let db else {
      let c = Ansi.fg256(TUITheme.Color.meterIdle)
      let bar: String
      switch style {
      case .smooth:
        bar = Bar.renderColoredSmooth(
          fraction: 0,
          width: width,
          fillFG: TUITheme.Color.meterIdle,
          trackFG: TUITheme.Color.track,
          trackBG: TUITheme.Color.track
        )
      case .steps:
        bar = c + Bar.render(fraction: 0, width: width, style: .steps)
      }
      return "\(theme.label(label)) \(c)--dB \(bar)\(reset)"
    }

    let c = color(db: db)
    let frac = fraction(db: db)
    let clipMark = clipped ? (Ansi.fg256(TUITheme.Color.meterHot) + "!" + reset) : " "
    let dbStr = String(format: "%@%3.0fdB%@%@", c, db, reset, clipMark)
    let bar: String
    switch style {
    case .smooth:
      // For meters, use the db-driven color as the fill, and a fixed dark track.
      let fillFG = colorCode(db: db)
      let holdFrac = holdDB.map { fraction(db: $0) }
      bar = Bar.renderMeterSmooth(
        fraction: frac,
        holdFraction: holdFrac,
        width: width,
        fillFG: fillFG,
        trackFG: TUITheme.Color.track,
        trackBG: TUITheme.Color.track,
        holdFG: TUITheme.Color.label
      )
    case .steps:
      bar = c + Bar.render(fraction: frac, width: width, style: .steps)
    }

    return "\(theme.label(label)) \(dbStr) \(bar)\(reset)"
  }
}

extension Bar {
  static func renderMeterSmooth(
    fraction: Double,
    holdFraction: Double?,
    width: Int,
    fillFG: Int,
    trackFG: Int,
    trackBG: Int,
    holdFG: Int
  ) -> String {
    let w = max(1, width)
    let t = max(0.0, min(1.0, fraction))
    let units = Int((Double(w) * 8.0 * t).rounded(.toNearestOrAwayFromZero))
    let full = min(w, units / 8)
    let rem = units % 8
    let hasPartial = rem > 0 && full < w
    let partial = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    let holdPos: Int? = holdFraction.map { hf in
      let c = max(0.0, min(1.0, hf))
      return min(w - 1, max(0, Int(floor(c * Double(w)))))
    }

    var s = Ansi.bg256(trackBG)
    for i in 0..<w {
      var fg = trackFG
      var glyph = "█"
      if i < full {
        fg = fillFG
        glyph = "█"
      } else if i == full, hasPartial {
        fg = fillFG
        glyph = partial[rem]
      }
      if let holdPos, i == holdPos {
        fg = holdFG
        glyph = "▏"
      }
      s += Ansi.fg256(fg) + glyph
    }
    return s
  }

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