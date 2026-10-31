// Compile with Runner/FileAccessStore.swift; see docs/macos-file-access.md.
import CryptoKit
import Foundation
import PDFKit

@main
struct CoordinatedReadTest {
  static func read(_ path: String) async throws -> CoordinatedFileReader.Contents {
    let reader = CoordinatedFileReader()
    return try await withCheckedThrowingContinuation { continuation in
      reader.read(path) { outcome in
        precondition(!Thread.isMainThread, "File I/O ran on the main thread")
        withExtendedLifetime(reader) { continuation.resume(with: outcome) }
      }
    }
  }

  static func main() async throws {
    // Bound the probe only. Production grants stay alive until native I/O ends.
    DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
      fputs("FAIL: coordinated-read probe timed out after 45 seconds\n", stderr)
      exit(1)
    }
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--read" {
      let path = CommandLine.arguments[2]
      let before = try FileManager.default.attributesOfItem(atPath: path)
      print("Before read: size=\(before[.size] ?? "unknown")")
      let contents = try await read(path)
      guard let pdf = PDFDocument(data: contents.data), pdf.pageCount > 0 else {
        fatalError("The coordinated bytes are not a readable PDF")
      }
      let hash = SHA256.hash(data: contents.data).map { String(format: "%02x", $0) }.joined()
      print("PASS: coordinated PDF read; bytes=\(contents.data.count), pages=\(pdf.pageCount), sha256=\(hash)")
      return
    }

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("document.pdf")
    let link = root.appendingPathComponent("link.pdf")
    let expected = Data(repeating: 0x42, count: 2 * 1024 * 1024)
    try expected.write(to: original)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    async let directRead = read(original.path)
    async let linkRead = read(link.path)
    let (direct, linked) = try await (directRead, linkRead)
    precondition(direct.data == expected && linked.data == expected)
    precondition(direct.path == original.resolvingSymlinksInPath().path)
    precondition(linked.path == direct.path)
    // Retained document bytes must survive a source change after coordination.
    try Data("replacement".utf8).write(to: original)
    precondition(direct.data == expected && linked.data == expected)
    print("PASS: concurrent background reads, symlink path, and detached bytes")

    do {
      _ = try await read(root.appendingPathComponent("missing.pdf").path)
      fatalError("Reading a missing file unexpectedly succeeded")
    } catch {
      precondition(!CoordinatedFileReader.isCloudUnavailable(error))
    }
    let deadlock = NSError(domain: NSPOSIXErrorDomain, code: Int(EDEADLK))
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                          userInfo: [NSUnderlyingErrorKey: deadlock])
    precondition(CoordinatedFileReader.isCloudUnavailable(deadlock))
    precondition(CoordinatedFileReader.isCloudUnavailable(wrapped))
    precondition(CoordinatedFileReader.isCloudUnavailable(
      NSError(domain: "NSFileProviderErrorDomain", code: -1000)))
    precondition(!CoordinatedFileReader.isCloudUnavailable(
      NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
    print("PASS: missing-file failure and cloud errors distinguished from permission errors")
  }
}
