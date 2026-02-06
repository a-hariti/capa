import Foundation
import Darwin

enum Utils {
  static func readTranscodeSkipKey(timeoutMs: Int32) -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ready = poll(&fds, 1, timeoutMs)
    guard ready > 0, (fds.revents & Int16(POLLIN)) != 0 else { return false }

    var b: UInt8 = 0
    guard read(STDIN_FILENO, &b, 1) == 1 else { return false }
    if b == 0x03 { return true } // Ctrl+C
    guard b == 0x1b else { return false }

    // Bare Escape skips transcoding. Escape-prefixed key sequences (e.g. arrows) should not.
    var nextFDs = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let hasFollowup = poll(&nextFDs, 1, 0) > 0 && (nextFDs.revents & Int16(POLLIN)) != 0
    guard hasFollowup else { return true }

    var discard: UInt8 = 0
    _ = read(STDIN_FILENO, &discard, 1)
    while true {
      var pendingFDs = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      let pending = poll(&pendingFDs, 1, 0)
      if pending <= 0 || (pendingFDs.revents & Int16(POLLIN)) == 0 { break }
      _ = read(STDIN_FILENO, &discard, 1)
    }
    return false
  }

  static func sanitizeProjectName(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "capa" }
    let forbidden = CharacterSet(charactersIn: "/:")
    let mapped = trimmed.unicodeScalars.map { forbidden.contains($0) ? "-" : Character($0) }
    return String(mapped)
  }

  static func slugifyFilenameStem(_ s: String) -> String {
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

  static func abbreviateHomePath(_ p: String) -> String {
    let home = NSHomeDirectory()
    if p == home { return "~" }
    if p.hasPrefix(home + "/") {
      return "~" + String(p.dropFirst(home.count))
    }
    return p
  }

  static func directoryExists(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  static func directoryNonEmpty(_ url: URL) -> Bool {
    guard directoryExists(url) else { return false }
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return !contents.isEmpty
  }

  static func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  static func ensureUniqueProjectDir(parent: URL, name: String, expectedFilenames: [String]) -> (name: String, dir: URL) {
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
}
