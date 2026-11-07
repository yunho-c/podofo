// Compile with Runner/FileAccessStore.swift; see docs/macos-file-access.md.
import Foundation

@main
struct FileReplacementTest {
  static func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(condition, file: file, line: line)
  }

  static func main() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let store = FileAccessStore()
    let created = Date(timeIntervalSince1970: 1577836800)
    let modified = Date(timeIntervalSince1970: 1609459200)
    let target = root.appendingPathComponent("document.pdf")
    try Data("original".utf8).write(to: target)
    try fm.setAttributes([.creationDate: created, .modificationDate: modified,
                          .posixPermissions: 0o640], ofItemAtPath: target.path)
    var taggedTarget = target
    var values = URLResourceValues()
    values.labelNumber = 3
    try taggedTarget.setResourceValues(values)
    let label = try target.resourceValues(forKeys: [.labelNumberKey]).labelNumber

    // Use the production staging location, not a sibling tempfile approximation.
    for contents in ["first edit", "second edit"] {
      let staging = try store.stagingDirectory(for: target.path)
      defer { try? fm.removeItem(atPath: staging) }
      let staged = URL(fileURLWithPath: staging).appendingPathComponent("document.pdf")
      try Data(contents.utf8).write(to: staged)
      try DocumentFileReplacement.commit(
        stagedPath: staged.path, targetPath: target.path, replaceExisting: true)
      let attributes = try fm.attributesOfItem(atPath: target.path)
      check(attributes[.creationDate] as? Date == created)
      check((attributes[.modificationDate] as! Date) > modified)
      check((attributes[.posixPermissions] as! NSNumber).intValue == 0o640)
      check(try target.resourceValues(forKeys: [.labelNumberKey]).labelNumber == label)
      check(try Data(contentsOf: target) == Data(contents.utf8))
    }
    print("PASS: repeated saves retain creation date, permissions, and Finder label; contents and modified date update")

    let copy = root.appendingPathComponent("new-copy.pdf")
    let newStaging = try store.stagingDirectory(for: copy.path)
    defer { try? fm.removeItem(atPath: newStaging) }
    let stagedCopy = URL(fileURLWithPath: newStaging).appendingPathComponent("document.pdf")
    try Data(contentsOf: target).write(to: stagedCopy)
    let copyCreated = try fm.attributesOfItem(atPath: stagedCopy.path)[.creationDate] as! Date
    try DocumentFileReplacement.commit(
      stagedPath: stagedCopy.path, targetPath: copy.path, replaceExisting: false)
    let actualCreated = try fm.attributesOfItem(atPath: copy.path)[.creationDate] as! Date
    check(actualCreated == copyCreated && actualCreated > created)
    check(try Data(contentsOf: copy) == Data(contentsOf: target))
    print("PASS: Save As to a new path has a fresh creation date and exact contents")

    // An explicitly selected existing Save As destination keeps its own date,
    // not the source document's date or the freshly staged file's date.
    let destinationCreated = Date(timeIntervalSince1970: 1262304000)
    try fm.setAttributes([.creationDate: destinationCreated], ofItemAtPath: copy.path)
    try Data("overwritten copy".utf8).write(to: stagedCopy)
    try DocumentFileReplacement.commit(
      stagedPath: stagedCopy.path, targetPath: copy.path, replaceExisting: true)
    check(try fm.attributesOfItem(atPath: copy.path)[.creationDate] as? Date == destinationCreated)
    print("PASS: Save As overwriting an existing destination retains that destination's date")

    let beforeFailure = try Data(contentsOf: copy)
    // The first failure leaves the original intact; the second also leaves the
    // staged bytes intact when a new destination appears before publication.
    do {
      try DocumentFileReplacement.commit(
        stagedPath: stagedCopy.path, targetPath: copy.path, replaceExisting: true)
      fatalError("Missing staged file unexpectedly succeeded")
    } catch {}
    check(try Data(contentsOf: copy) == beforeFailure)
    try Data("pending copy".utf8).write(to: stagedCopy)
    do {
      try DocumentFileReplacement.commit(
        stagedPath: stagedCopy.path, targetPath: copy.path, replaceExisting: false)
      fatalError("New-file publication overwrote an existing destination")
    } catch {}
    check(try Data(contentsOf: copy) == beforeFailure)
    check(try Data(contentsOf: stagedCopy) == Data("pending copy".utf8))
    check(try fm.attributesOfItem(atPath: copy.path)[.creationDate] as? Date == destinationCreated)
    print("PASS: failed replacement and destination collision preserve existing data/metadata")
  }
}
