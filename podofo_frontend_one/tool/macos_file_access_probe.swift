// Compile with Runner/FileAccessStore.swift and run as a sandboxed .app.
// See docs/macos-file-access.md for the grant/relaunch/move validation recipe.
import Cocoa

@main
final class FileAccessProbe: NSObject, NSApplicationDelegate {
  private let store = FileAccessStore()
  private let defaults = UserDefaults.standard
  private var report: [String: Any] = [:]

  static func main() {
    let app = NSApplication.shared
    let delegate = FileAccessProbe()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    withExtendedLifetime(delegate) {}
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    do {
      let args = CommandLine.arguments
      if args.contains("--grant") {
        let path = args.last!
        report["deniedBeforeGrant"] = (try? Data(contentsOf: URL(fileURLWithPath: path))) == nil
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select the disposable file-access probe fixture."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
          throw NSError(domain: "Probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
        }
        let expected = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard url.standardizedFileURL.resolvingSymlinksInPath() == expected,
              try String(contentsOf: url, encoding: .utf8) == "persistent-access-before-save\n" else {
          throw NSError(domain: "Probe", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Select only the disposable probe fixture; no file was changed."])
        }
        defaults.set(url.path, forKey: "probe.path")
        let access = try store.acquire(url.path, selected: true)
        defer { if let token = access.token { store.release(token) } }
        report["selectedRead"] = try String(contentsOfFile: access.path, encoding: .utf8)
        // Mirror AtomicPdfFile: same-volume staging, rename, then bookmark refresh.
        let staging = try store.stagingDirectory(for: access.path)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let staged = URL(fileURLWithPath: staging).appendingPathComponent("document.pdf")
        try Data("persistent-access-after-save\n".utf8).write(to: staged)
        guard rename(staged.path, access.path) == 0 else {
          throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try store.remember(access.path)
        report["savedRead"] = try String(contentsOfFile: access.path, encoding: .utf8)
      } else {
        guard let path = defaults.string(forKey: "probe.path") else {
          throw NSError(domain: "Probe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Run --grant first"])
        }
        report["deniedBeforeRestore"] = (try? Data(contentsOf: URL(fileURLWithPath: path))) == nil
        let access = try store.acquire(path)
        defer { if let token = access.token { store.release(token) } }
        report["resolvedPath"] = access.path
        report["restoredRead"] = try String(contentsOfFile: access.path, encoding: .utf8)
        report["scopeStarted"] = access.token != nil
      }
      report["success"] = true
    } catch {
      report["success"] = false
      report["error"] = error.localizedDescription
    }
    let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("probe-result.json")
    try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    NSApp.terminate(nil)
  }
}
