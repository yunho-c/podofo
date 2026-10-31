import Foundation

/// Reads cloud-backed documents while File Provider coordinates materialization.
/// The caller must hold its security-scoped lease until completion. The callback
/// runs on a worker queue, and the returned bytes no longer depend on the file.
final class CoordinatedFileReader {
  struct Contents {
    let path: String
    let data: Data
  }

  private let queue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "PoDoFo.document-reads"
    queue.qualityOfService = .userInitiated
    return queue
  }()

  func read(_ path: String, completion: @escaping (Result<Contents, Error>) -> Void) {
    let intent = NSFileAccessIntent.readingIntent(
      with: URL(fileURLWithPath: path), options: [])
    // Each request needs its own coordinator and an ordinary read intent so
    // File Provider can download a dataless file before we read its contents.
    let coordinator = NSFileCoordinator()
    coordinator.coordinate(with: [intent], queue: queue) { error in
      withExtendedLifetime(coordinator) {
        if let error = error {
          completion(.failure(error))
          return
        }
        do {
          // Use the coordinated URL, which can differ if the item moved. Avoid
          // memory mapping: PDFium must remain independent of the source file.
          let data = try Data(contentsOf: intent.url, options: [])
          let path = intent.url.resolvingSymlinksInPath().path
          completion(.success(Contents(path: path, data: data)))
        } catch {
          completion(.failure(error))
        }
      }
    }
  }

  static func isCloudUnavailable(_ error: Error) -> Bool {
    var current: NSError? = error as NSError
    // Foundation often wraps a POSIX error in NSCocoaErrorDomain. Bound the
    // traversal so even a malformed underlying-error chain cannot loop forever.
    for _ in 0..<8 {
      guard let cause = current else { return false }
      if cause.domain == "NSFileProviderErrorDomain"
        || (cause.domain == NSPOSIXErrorDomain && cause.code == Int(EDEADLK)) {
        return true
      }
      current = cause.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return false
  }
}

/// Owns the sandbox grants; document/history records can continue storing paths.
/// Access is leased only around file I/O (the PDF itself is detached in memory).
final class FileAccessStore {
  private let defaults: UserDefaults
  private let storageKey = "podofo.securityScopedBookmarks.v1"
  private var active: [String: URL] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  private var bookmarks: [String: Data] {
    get { defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:] }
    set {
      defaults.set(newValue, forKey: storageKey)
      // Finish persisting before reporting a successful grant to Dart.
      defaults.synchronize()
    }
  }

  private func canonical(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
  }

  func remember(_ path: String) throws {
    let url = canonical(URL(fileURLWithPath: path))
    try remember(url, aliases: [path])
  }

  private func remember(_ url: URL, aliases: [String]) throws {
    let data = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    var stored = bookmarks
    let keys = Set(aliases + [url.path])
    let previous = keys.compactMap { stored[$0] }.filter { bookmark in
      var stale = false
      let oldURL = try? URL(
        resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
        relativeTo: nil, bookmarkDataIsStale: &stale)
      // Selecting a new file at a moved file's old path must not redirect the
      // moved file's canonical entry to this different document.
      return oldURL?.standardizedFileURL.path == url.standardizedFileURL.path
    }
    // Keep old paths/symlinks usable in recent history after a move or replacement.
    for (key, value) in stored where previous.contains(value) {
      stored[key] = data
    }
    for key in keys { stored[key] = data }
    bookmarks = stored
  }

  func acquire(_ path: String, selected: Bool = false) throws -> (path: String, token: String?) {
    if selected { try remember(path) }
    guard let data = bookmarks[path] else {
      // Legacy records and files inside the app container may already be accessible.
      // An inaccessible legacy record fails at the read and offers Locate PDF.
      return (path, nil)
    }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(
        domain: "PoDoFo.FileAccess", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Access to this PDF has expired. Use Locate PDF to grant access again."])
    }
    do {
      if stale || url.path != path { try remember(url, aliases: [path]) }
      let token = UUID().uuidString
      active[token] = url
      return (url.path, token)
    } catch {
      url.stopAccessingSecurityScopedResource()
      throw error
    }
  }

  func release(_ token: String) {
    active.removeValue(forKey: token)?.stopAccessingSecurityScopedResource()
  }

  func releaseAll() {
    for url in active.values { url.stopAccessingSecurityScopedResource() }
    active.removeAll()
  }

  /// A grant to a PDF does not grant permission to create arbitrary siblings.
  /// Foundation supplies a writable staging directory on the target volume.
  func stagingDirectory(for path: String) throws -> String {
    try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask,
      appropriateFor: URL(fileURLWithPath: path), create: true).path
  }

  deinit { releaseAll() }
}
