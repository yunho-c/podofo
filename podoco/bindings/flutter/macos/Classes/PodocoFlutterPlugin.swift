import FlutterMacOS
import Foundation

/// Only resource locations cross the channel. Native SDK verification and model
/// loading run away from the UI thread. No writable model store is created.
public final class PodocoFlutterPlugin: NSObject, FlutterPlugin {
    private let registrar: FlutterPluginRegistrar
    private let io = DispatchQueue(label: "dev.podoco.flutter.model-resources", qos: .userInitiated)

    private init(registrar: FlutterPluginRegistrar) { self.registrar = registrar }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "dev.podoco.flutter/models", binaryMessenger: registrar.messenger)
        registrar.addMethodCallDelegate(PodocoFlutterPlugin(registrar: registrar), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "platform":
            #if arch(arm64)
            result("macos-arm64")
            #else
            result("macos-x64")
            #endif
        case "locate":
            guard let args = call.arguments as? [String: String],
                  let package = args["package"], let root = args["assetRoot"],
                  package.range(of: "^[a-z][a-z0-9_]{0,79}$", options: .regularExpression) != nil,
                  Self.relative(root) else {
                result(FlutterError(code: "invalid_asset", message: "Invalid bundled pack descriptor", details: nil))
                return
            }
            let key = registrar.lookupKey(forAsset: "\(root)/pack.json", fromPackage: package)
            let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let resource = Bundle.main.path(forResource: key, ofType: nil).map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: key, relativeTo: Bundle.main.bundleURL)
            io.async {
                let resolved = resource.resolvingSymlinksInPath().standardizedFileURL
                // Framework resource aliases may be internal symlinks, but the
                // resulting model directory must stay inside this application.
                guard resolved.path.hasPrefix(bundle.path + "/") else {
                    DispatchQueue.main.async { result(FlutterError(code: "invalid_asset", message: "Model resources escape the application bundle", details: nil)) }
                    return
                }
                let exists = FileManager.default.fileExists(atPath: resolved.path)
                DispatchQueue.main.async { result(exists ? resolved.deletingLastPathComponent().path : nil) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func relative(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 &&
            !value.contains("\\") && !value.contains(":") && !value.contains("\0") &&
            value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
