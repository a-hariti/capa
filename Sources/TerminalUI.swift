import Foundation
import Darwin

final class SharedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool

  init(_ initialValue: Bool = false) {
    self.value = initialValue
  }

  func get() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func set(_ newValue: Bool = true) {
    lock.lock()
    value = newValue
    lock.unlock()
  }
}

private let wizardSummaryLabels = [
  "Project Name",
  "Display",
  "Cursor",
  "Menu Bar",
  "Audio",
  "Microphone",
  "Camera",
  "Video Codec",
]

private let wizardSummaryLabelWidth = wizardSummaryLabels
  .map { Ansi.visibleWidth($0) }
  .max() ?? 0

func renderWizardSummary(label: String, value: String, isTTY: Bool, indent: Int = 0) -> String {
  let pad = max(0, wizardSummaryLabelWidth - Ansi.visibleWidth(label))
  let paddedLabel = label + String(repeating: " ", count: pad)
  let prefix = String(repeating: " ", count: indent)
  if isTTY {
    return "\(prefix)\(TUITheme.primary(paddedLabel)) \(TUITheme.label(":")) \(TUITheme.option(value))"
  }
  return "\(prefix)\(paddedLabel) : \(value)"
}

func fitTickerLine(base: String, suffix: String?, maxColumns: Int?) -> String {
  guard let suffix, !suffix.isEmpty else { return base }
  let withSuffix = "\(base)  \(suffix)"
  guard let maxColumns, maxColumns > 0 else { return withSuffix }
  return Ansi.visibleWidth(withSuffix) <= maxColumns ? withSuffix : base
}

enum Key {
  case up
  case down
  case enter
  case escape
  case backspace
  case ctrlC
  case ctrlD
  case char(Character)
  case unknown
}

final class TerminalController: @unchecked Sendable {
  private var original = termios()
  private var rawEnabled = false

  static func isTTY(_ fd: Int32) -> Bool {
    isatty(fd) != 0
  }

  static func columns(_ fd: Int32) -> Int? {
    var ws = winsize()
    if ioctl(fd, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
      return Int(ws.ws_col)
    }
    return nil
  }

  func enableRawMode(disableSignals: Bool = false) {
    guard !rawEnabled else { return }
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~(UInt(ECHO | ICANON))
    if disableSignals {
      raw.c_lflag &= ~UInt(ISIG)
    }
    withUnsafeMutablePointer(to: &raw.c_cc) { ccPtr in
      ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 0
      }
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    rawEnabled = true
  }

  func disableRawMode() {
    guard rawEnabled else { return }
    var orig = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
    rawEnabled = false
  }

  func readKey(timeoutMs: Int32 = -1) -> Key? {
    guard let firstByte = readByte(timeoutMs: timeoutMs) else {
      return nil
    }

    if firstByte == 0x1b {
      guard let b1 = readByte(timeoutMs: 20) else {
        return .escape
      }
      if b1 == 0x5b, let b2 = readByte(timeoutMs: 20) {
        if b2 == 0x41 { return .up }
        if b2 == 0x42 { return .down }
      }
      return .unknown
    }

    if firstByte == 0x0a || firstByte == 0x0d { return .enter }
    if firstByte == 0x08 || firstByte == 0x7f { return .backspace }
    if firstByte == 0x03 { return .ctrlC }
    if firstByte == 0x04 { return .ctrlD }
    if let c = TerminalController.decodeUTF8Character(startByte: firstByte, readNextByte: { _ in readByte(timeoutMs: 20) }) {
      return .char(c)
    }
    return .unknown
  }

  var keys: AsyncStream<Key> {
    AsyncStream { continuation in
      let isRunning = SharedFlag(true)
      continuation.onTermination = { _ in
        isRunning.set(false)
      }
      let t = Thread { [weak self] in
        guard let self else { return }
        while isRunning.get() {
          if let key = self.readKey(timeoutMs: 100) {
            continuation.yield(key)
            if case .ctrlC = key { break }
            if case .ctrlD = key { break }
          }
        }
        continuation.finish()
      }
      t.start()
    }
  }

  static func decodeUTF8Character(startByte: UInt8, readNextByte: (_ timeoutMs: Int32) -> UInt8?) -> Character? {
    let expectedContinuationCount: Int
    switch startByte {
    case 0x00...0x7F:
      expectedContinuationCount = 0
    case 0xC2...0xDF:
      expectedContinuationCount = 1
    case 0xE0...0xEF:
      expectedContinuationCount = 2
    case 0xF0...0xF4:
      expectedContinuationCount = 3
    default:
      return nil
    }

    var bytes: [UInt8] = [startByte]
    if expectedContinuationCount > 0 {
      for _ in 0..<expectedContinuationCount {
        guard let next = readNextByte(20), (next & 0b1100_0000) == 0b1000_0000 else {
          return nil
        }
        bytes.append(next)
      }
    }

    guard let s = String(bytes: bytes, encoding: .utf8), s.count == 1, let c = s.first else {
      return nil
    }
    return c
  }

  private func readByte(timeoutMs: Int32) -> UInt8? {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&fds, 1, timeoutMs)
    guard ready > 0, (fds.revents & Int16(POLLIN)) != 0 else {
      return nil
    }
    var b: UInt8 = 0
    let n = read(STDIN_FILENO, &b, 1)
    return n == 1 ? b : nil
  }

  func discardPendingInput(maxBytes: Int = 128) {
    guard maxBytes > 0 else { return }
    var remaining = maxBytes
    while remaining > 0 {
      var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let ready = poll(&fds, 1, 0)
      guard ready > 0, (fds.revents & Int16(POLLIN)) != 0 else { break }
      var b: UInt8 = 0
      let n = read(STDIN_FILENO, &b, 1)
      if n != 1 { break }
      remaining -= 1
    }
  }
}

enum SelectionResult {
  case selected(Int)
  case back
  case cancel
}

enum TextInputResult {
  case submitted(String)
  case cancel
}

func selectOption(terminal: TerminalController, title: String, options: [String], defaultIndex: Int) -> Int {
  switch selectOptionWithBack(terminal: terminal, title: title, options: options, defaultIndex: defaultIndex, allowBack: false) {
  case .selected(let idx):
    return idx
  case .back:
    return min(max(defaultIndex, 0), options.count - 1)
  case .cancel:
    return min(max(defaultIndex, 0), options.count - 1)
  }
}

func selectOptionWithBack(
  terminal: TerminalController,
  title: String,
  summaryLabel: String? = nil,
  options: [String],
  defaultIndex: Int,
  allowBack: Bool,
  summaryIndent: Int = 0,
  printSummary: Bool = true
) -> SelectionResult {
  guard TerminalController.isTTY(STDIN_FILENO) else {
    return .selected(min(max(defaultIndex, 0), options.count - 1))
  }
  var index = min(max(defaultIndex, 0), options.count - 1)
  let lines = options.count + 2

  func splitPrimarySecondary(_ text: String) -> (primary: String, secondary: String?) {
    guard let open = text.lastIndex(of: "("), open > text.startIndex, text.hasSuffix(")") else {
      return (text, nil)
    }
    let before = text[..<open]
    guard before.last == " " else { return (text, nil) }
    let primary = String(before.dropLast())
    let secondary = String(text[open...])
    return (primary, secondary)
  }

  func render() {
    print(TUITheme.primary("\(title):"))
    for i in 0..<options.count {
      let parts = splitPrimarySecondary(options[i])
      let secondary = parts.secondary.map { " " + TUITheme.muted($0) } ?? ""
      if i == index {
        print("  \(TUITheme.accent(TUITheme.Glyph.pickerCaret, bold: true)) \(Ansi.bold)\(TUITheme.accent(parts.primary, bold: true))\(Ansi.reset)\(secondary)")
      } else {
        print("    \(TUITheme.option(parts.primary))\(secondary)")
      }
    }
    let hint = allowBack
      ? "↑/↓ move\(TUITheme.Glyph.pickerHintSep)Enter select\(TUITheme.Glyph.pickerHintSep)Esc back"
      : "↑/↓ move\(TUITheme.Glyph.pickerHintSep)Enter select"
    print(TUITheme.muted(hint))
  }

  terminal.enableRawMode(disableSignals: true)
  defer { terminal.disableRawMode() }

  render()
  while true {
    guard let key = terminal.readKey() else { continue }
    switch key {
    case .up:
      if index > 0 { index -= 1 }
    case .down:
      if index < options.count - 1 { index += 1 }
    case .enter:
      // Collapse the menu into a single summary line.
      print("\u{001B}[\(lines)A", terminator: "")
      for n in 0..<lines {
        print("\u{001B}[2K\r", terminator: "")
        if n < lines - 1 {
          print("\u{001B}[1B", terminator: "")
        }
      }
      print("\u{001B}[\(lines - 1)A", terminator: "")
      if printSummary {
        let picked = splitPrimarySecondary(options[index]).primary
        print(renderWizardSummary(label: summaryLabel ?? title, value: picked, isTTY: true, indent: summaryIndent))
      }
      return .selected(index)
    case .escape:
      guard allowBack else { continue }
      // Remove current prompt block completely before navigating back.
      print("\u{001B}[\(lines)A", terminator: "")
      for n in 0..<lines {
        print("\u{001B}[2K\r", terminator: "")
        if n < lines - 1 {
          print("\u{001B}[1B", terminator: "")
        }
      }
      print("\u{001B}[\(lines - 1)A", terminator: "")
      // Prevent key-repeat Esc from cascading through multiple previous steps.
      terminal.discardPendingInput()
      return .back
    case .ctrlC, .ctrlD:
      // Remove prompt block and cancel the whole interaction gracefully.
      print("\u{001B}[\(lines)A", terminator: "")
      for n in 0..<lines {
        print("\u{001B}[2K\r", terminator: "")
        if n < lines - 1 {
          print("\u{001B}[1B", terminator: "")
        }
      }
      print("\u{001B}[\(lines - 1)A", terminator: "")
      return .cancel
    default:
      break
    }

    // Move cursor up to redraw.
    print("\u{001B}[\(lines)A", terminator: "")
    render()
  }
}

func promptEditableDefault(terminal: TerminalController, title: String, defaultValue: String) -> TextInputResult {
  guard TerminalController.isTTY(STDIN_FILENO) else {
    return .submitted(defaultValue)
  }

  var value = defaultValue
  var untouched = true

  func render() {
    let line = renderWizardSummary(label: title, value: value, isTTY: true)
    print("\r\u{001B}[2K\(line)", terminator: "")
    fflush(stdout)
  }

  terminal.enableRawMode(disableSignals: true)
  defer { terminal.disableRawMode() }

  render()
  while true {
    guard let key = terminal.readKey() else { continue }
    switch key {
    case .enter:
      print("")
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return .submitted(trimmed.isEmpty ? defaultValue : trimmed)
    case .ctrlC, .ctrlD, .escape:
      print("\r\u{001B}[2K", terminator: "")
      print("")
      return .cancel
    case .backspace:
      if untouched {
        untouched = false
      }
      if !value.isEmpty {
        value.removeLast()
      }
      render()
    case .char(let c):
      if c.isNewline { continue }
      if untouched {
        value = ""
        untouched = false
      }
      value.append(c)
      render()
    default:
      continue
    }
  }
}

func promptString(_ prompt: String, defaultValue: String) -> String {
  print("\(prompt) [default \(defaultValue)]: ", terminator: "")
  if let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty {
    return line.trimmingCharacters(in: .whitespaces)
  }
  return defaultValue
}

func promptYesNo(_ prompt: String, defaultYes: Bool) -> Bool {
  let def = defaultYes ? "Y/n" : "y/N"
  print("\(prompt) [\(def)]: ", terminator: "")
  if let line = readLine(), !line.trimmingCharacters(in: .whitespaces).isEmpty {
    let c = line.lowercased()
    return c == "y" || c == "yes"
  }
  return defaultYes
}

final class ElapsedTicker {
  private let fd: UnsafeMutablePointer<FILE>
  private let prefix: String
  private let tickInterval: DispatchTimeInterval
  private let suffix: (@Sendable () -> String)?
  private let queue = DispatchQueue(label: "capa.elapsed-ticker")
  private var timer: DispatchSourceTimer?
  private var startTime: DispatchTime?
  private var lastPrintedVisibleLen: Int = 0
  private var cursorHidden = false

  init(
    prefix: String = "⏺︎",
    toStderr: Bool = true,
    tickInterval: DispatchTimeInterval = .seconds(1),
    suffix: (@Sendable () -> String)? = nil
  ) {
    self.prefix = prefix
    self.fd = toStderr ? stderr : stdout
    self.tickInterval = tickInterval
    self.suffix = suffix
  }

  func startIfTTY() {
    // Only render the live-updating line when attached to a terminal.
    let isTTY = TerminalController.isTTY(fileno(fd))
    guard isTTY else { return }
    start()
  }

  func start() {
    guard timer == nil else { return }
    startTime = .now()
    hideCursor()

    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: tickInterval, leeway: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.tick() }
    timer = t
    t.resume()
  }

  func stop() {
    guard let t = timer else { return }
    // Force one last update to ensure final state (e.g. zeroed meters) is rendered.
    queue.sync { self.tick() }

    timer = nil
    t.cancel()
    // Drain any enqueued timer callbacks so no stale redraw can print after stop.
    queue.sync {}
    showCursor()
    writeLine("\n")
  }

  private func tick() {
    guard timer != nil, let startTime else { return }
    let elapsed = max(0, Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000))
    let timerText = TUITheme.title(format(elapsedSeconds: elapsed))
    let base = "\(TUITheme.recordingDot(prefix)) \(timerText)"
    let extra = suffix?()
    let columns = TerminalController.columns(fileno(fd))
    let s = fitTickerLine(base: base, suffix: extra, maxColumns: columns)

    // Re-write the same line, padding any leftover characters.
    let visibleLen = Ansi.visibleWidth(s)
    let pad = max(0, lastPrintedVisibleLen - visibleLen)
    lastPrintedVisibleLen = visibleLen
    writeLine("\r" + s + String(repeating: " ", count: pad))
  }

  private func format(elapsedSeconds: Int) -> String {
    let h = elapsedSeconds / 3600
    let m = (elapsedSeconds % 3600) / 60
    let s = elapsedSeconds % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%02d:%02d", m, s)
  }

  private func writeLine(_ s: String) {
    s.withCString { cstr in
      fputs(cstr, fd)
      fflush(fd)
    }
  }

  private func hideCursor() {
    guard !cursorHidden else { return }
    cursorHidden = true
    // ANSI: hide cursor
    writeLine(Ansi.hideCursor)
  }

  private func showCursor() {
    guard cursorHidden else { return }
    cursorHidden = false
    // ANSI: show cursor
    writeLine(Ansi.showCursor)
  }
}