import FlutterMacOS

final class FileAccessPlugin: NSObject, FlutterPlugin {
  private let store = FileAccessStore()
  private let reader = CoordinatedFileReader()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "podofo/file_access", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(FileAccessPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "acquire":
        guard let path = args["path"] as? String else { throw invalidArguments() }
        let access = try store.acquire(path, selected: args["selected"] as? Bool ?? false)
        var response: [String: Any] = ["path": access.path]
        if let token = access.token { response["token"] = token }
        result(response)
      case "release":
        guard let token = args["token"] as? String else { throw invalidArguments() }
        store.release(token)
        result(nil)
      case "read":
        guard let path = args["path"] as? String else { throw invalidArguments() }
        reader.read(path) { outcome in
          // Flutter replies and bookmark lease operations stay on the platform
          // thread. Dart releases the lease only after this reply is delivered.
          DispatchQueue.main.async {
            switch outcome {
            case .success(let contents):
              result([
                "path": contents.path,
                "bytes": FlutterStandardTypedData(bytes: contents.data),
              ])
            case .failure(let error):
              let native = error as NSError
              let cloudUnavailable = CoordinatedFileReader.isCloudUnavailable(error)
              result(FlutterError(
                code: cloudUnavailable ? "cloud_file_unavailable" : "file_read",
                message: cloudUnavailable
                  ? "This cloud PDF could not be downloaded. Check your connection and cloud sync, or mark it Available offline in Finder, then retry."
                  : native.localizedDescription,
                details: ["domain": native.domain, "nativeCode": native.code,
                          "reason": native.localizedDescription, "path": path]))
            }
          }
        }
      case "remember":
        guard let path = args["path"] as? String else { throw invalidArguments() }
        try store.remember(path)
        result(nil)
      case "stagingDirectory":
        guard let path = args["path"] as? String else { throw invalidArguments() }
        result(try store.stagingDirectory(for: path))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "file_access", message: error.localizedDescription, details: nil))
    }
  }

  private func invalidArguments() -> NSError {
    NSError(domain: "PoDoFo.FileAccess", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Invalid file access request."])
  }
}
