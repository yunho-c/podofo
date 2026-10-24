// Run with FileAccessStore.swift using swiftc; see docs/macos-file-access.md.
import Foundation

@main
struct AliasTest {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "podofo-file-access-test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FileAccessStore(defaults: defaults)
    let old = root.appendingPathComponent("original.pdf")
    let moved = root.appendingPathComponent("moved.pdf")
    try Data("old document".utf8).write(to: old)
    try store.remember(old.path)
    try FileManager.default.moveItem(at: old, to: moved)
    // Resolve the moved file so both paths share a bookmark, then select a
    // different file at its old path. The moved entry must keep its identity.
    let access = try store.acquire(old.path)
    if let token = access.token { store.release(token) }
    try Data("new document".utf8).write(to: old)
    try store.remember(old.path)
    let bookmarks = defaults.dictionary(forKey: "podofo.securityScopedBookmarks.v1") as! [String: Data]
    var stale = false
    let resolved = try URL(resolvingBookmarkData: bookmarks[access.path]!, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    precondition(resolved.path == access.path, "Selecting a new file redirected the moved file's bookmark")
    print("PASS: selecting a new document at an old path preserves the moved document bookmark")
  }
}
