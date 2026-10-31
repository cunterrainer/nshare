import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var folderAccess: FolderAccess?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NshareFiles") {
      folderAccess = FolderAccess(messenger: registrar.messenger(), presenter: window?.rootViewController)
    }
  }
}

final class FolderAccess: NSObject, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var exporting = false
  private weak var presenter: UIViewController?
  init(messenger: FlutterBinaryMessenger, presenter: UIViewController?) {
    self.presenter = presenter
    super.init()
    let channel = FlutterMethodChannel(name: "dev.nshare/files", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      guard self.pending == nil else { result(FlutterError(code: "busy", message: "A folder operation is active", details: nil)); return }
      if call.method == "importFolder" {
        self.pending = result; self.exporting = false
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self; self.presenter?.present(picker, animated: true)
      } else if call.method == "exportFolder", let args = call.arguments as? [String: Any], let path = args["path"] as? String {
        self.pending = result; self.exporting = true
        // Export a snapshot without internal resume receipts or keys.
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
            let root = URL(fileURLWithPath: path)
            for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where item.lastPathComponent != ".nshare-state" {
              try FileManager.default.copyItem(at: item, to: snapshot.appendingPathComponent(item.lastPathComponent))
            }
            DispatchQueue.main.async {
              let picker = UIDocumentPickerViewController(forExporting: [snapshot], asCopy: true)
              picker.delegate = self; self.presenter?.present(picker, animated: true)
            }
          } catch { DispatchQueue.main.async { self.complete(FlutterError(code: "folder", message: error.localizedDescription, details: nil)) } }
        }
      } else { result(FlutterMethodNotImplemented) }
    }
  }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { complete(nil) }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let root = urls.first else { complete(nil); return }
    if exporting { complete(root.absoluteString); return }
    DispatchQueue.global(qos: .userInitiated).async {
      let scoped = root.startAccessingSecurityScopedResource()
      defer { if scoped { root.stopAccessingSecurityScopedResource() } }
      var staging: URL?
      do {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let container = support.appendingPathComponent("nshare-imports/\(UUID().uuidString)")
        staging = container
        try manager.createDirectory(at: container, withIntermediateDirectories: true)
        let destination = container.appendingPathComponent(root.lastPathComponent)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let items = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in false }) else { throw CocoaError(.fileReadUnknown) }
        var count = 0
        for case let item as URL in items {
          count += 1
          if count > 1_000_000 { throw CocoaError(.fileReadTooLarge) }
          let values = try item.resourceValues(forKeys: Set(keys))
          if values.isSymbolicLink == true { throw CocoaError(.fileReadUnsupportedScheme) }
          let relative = String(item.path.dropFirst(root.path.count + 1))
          if relative.split(separator: "/").count > 128 { throw CocoaError(.fileReadTooLarge) }
          let target = destination.appendingPathComponent(relative)
          if values.isDirectory == true { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
          else if values.isRegularFile == true { try manager.copyItem(at: item, to: target) }
          else { throw CocoaError(.fileReadUnknown) }
        }
        DispatchQueue.main.async { self.complete(destination.path) }
      } catch {
        if let path = staging { try? FileManager.default.removeItem(at: path) }
        DispatchQueue.main.async { self.complete(FlutterError(code: "folder", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  private func complete(_ value: Any?) { let callback = pending; pending = nil; callback?(value) }
}
