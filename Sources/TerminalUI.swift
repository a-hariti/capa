import Foundation
import Darwin

enum Key {
  case up
  case down
  case enter
  case char(Character)
  case unknown
}

final class Terminal {
  nonisolated(unsafe) private static var original = termios()
  nonisolated(unsafe) private static var rawEnabled = false

  static func enableRawMode() {
    guard !rawEnabled else { return }
    var raw = termios()
    tcgetattr(STDIN_FILENO, &original)
    raw = original
    raw.c_lflag &= ~(UInt(ECHO | ICANON))
    withUnsafeMutablePointer(to: &raw.c_cc) { ccPtr in
      ccPtr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
        cc[Int(VMIN)] = 1
        cc[Int(VTIME)] = 0
      }
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    rawEnabled = true
  }

  static func disableRawMode() {
    guard rawEnabled else { return }
    var orig = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
    rawEnabled = false
  }

  static func readKey() -> Key {
    var buffer = [UInt8](repeating: 0, count: 3)
    let n = read(STDIN_FILENO, &buffer, 1)
    if n <= 0 { return .unknown }

    if buffer[0] == 0x1b {
      let n2 = read(STDIN_FILENO, &buffer, 2)
      if n2 == 2 && buffer[0] == 0x5b {
        if buffer[1] == 0x41 { return .up }
        if buffer[1] == 0x42 { return .down }
      }
      return .unknown
    }

    if buffer[0] == 0x0a || buffer[0] == 0x0d { return .enter }
    if let scalar = UnicodeScalar(UInt32(buffer[0])) {
      return .char(Character(scalar))
    }
    return .unknown
  }
}

func selectOption(title: String, options: [String], defaultIndex: Int) -> Int {
  var index = min(max(defaultIndex, 0), options.count - 1)
  let lines = options.count + 2

  func render() {
    print("\(title):")
    for i in 0..<options.count {
      if i == index { print("  > \(options[i])") }
      else { print("    \(options[i])") }
    }
    print("Use up/down and Enter")
  }

  Terminal.enableRawMode()
  defer { Terminal.disableRawMode() }

  render()
  while true {
    switch Terminal.readKey() {
    case .up:
      if index > 0 { index -= 1 }
    case .down:
      if index < options.count - 1 { index += 1 }
    case .enter:
      print("")
      return index
    default:
      break
    }

    // Move cursor up to redraw.
    print("\u{001B}[\(lines)A", terminator: "")
    render()
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
