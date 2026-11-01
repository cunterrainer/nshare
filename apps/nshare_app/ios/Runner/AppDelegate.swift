import Flutter
import UIKit
import Darwin
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var folderAccess: FolderAccess?
  private var localBonjour: LocalBonjour?
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
      localBonjour = LocalBonjour(messenger: registrar.messenger())
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
        picker.delegate = self; self.presentPicker(picker)
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
              picker.delegate = self; self.presentPicker(picker)
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
        var enumerationError: Error?
        guard let items = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, error in
          enumerationError = error
          return false
        }) else { throw CocoaError(.fileReadUnknown) }
        var count = 0
        for case let item as URL in items {
          count += 1
          if count > 1_000_000 { throw CocoaError(.fileReadTooLarge) }
          let values = try item.resourceValues(forKeys: Set(keys))
          if values.isSymbolicLink == true { throw CocoaError(.fileReadUnsupportedScheme) }
          let relative = item.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
          if relative.split(separator: "/").count > 128 { throw CocoaError(.fileReadTooLarge) }
          let target = destination.appendingPathComponent(relative)
          if values.isDirectory == true { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
          else if values.isRegularFile == true { try manager.copyItem(at: item, to: target) }
          else { throw CocoaError(.fileReadUnknown) }
        }
        if let error = enumerationError { throw error }
        DispatchQueue.main.async { self.complete(destination.path) }
      } catch {
        if let path = staging { try? FileManager.default.removeItem(at: path) }
        DispatchQueue.main.async { self.complete(FlutterError(code: "folder", message: error.localizedDescription, details: nil)) }
      }
    }
  }
  private func presentPicker(_ picker: UIViewController) {
    // Scene-based Flutter applications may not populate AppDelegate.window.
    var host = presenter ?? UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = host?.presentedViewController { host = presented }
    guard let host = host else {
      complete(FlutterError(code: "window", message: "No active window for folder selection", details: nil))
      return
    }
    host.present(picker, animated: true)
  }
  private func complete(_ value: Any?) { let callback = pending; pending = nil; callback?(value) }
}


// Use system Bonjour instead of raw multicast sockets on iOS. NSBonjourServices
// and NSLocalNetworkUsageDescription are declared in Runner/Info.plist.
final class LocalBonjour: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private var browser: NetServiceBrowser?
  private var services: [NetService] = []
  private var advertisement: NetService?
  private var pendingSearch: FlutterResult?
  private var pendingPublish: FlutterResult?
  private var searchTimer: Timer?
  private var publishTimer: Timer?
  private var found: [[String: Any]] = []

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(name: "dev.nshare/discovery", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "closed", message: "Discovery closed", details: nil)); return }
      switch call.method {
      case "search":
        guard self.pendingSearch == nil else { result(FlutterError(code: "busy", message: "Discovery active", details: nil)); return }
        self.found = []; self.services = []; self.pendingSearch = result
        let browser = NetServiceBrowser(); self.browser = browser; browser.delegate = self
        browser.searchForServices(ofType: "_nshare._tcp.", inDomain: "local.")
        self.searchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.finishSearch(nil) }
      case "publish":
        guard let args = call.arguments as? [String: Any], let name = args["name"] as? String,
          let fp = args["fingerprint"] as? String, fp.count == 64,
          let port = args["port"] as? Int, (1...65535).contains(port) else {
          result(FlutterError(code: "argument", message: "Invalid advertisement", details: nil)); return
        }
        self.stopPublishing()
        let service = NetService(domain: "local.", type: "_nshare._tcp.", name: String(fp.prefix(12)), port: Int32(port))
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: ["fp": Data(fp.utf8),
          "name": Data(String(name.prefix(60)).utf8), "version": Data("3".utf8)]))
        self.advertisement = service; self.pendingPublish = result; service.publish()
        self.publishTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
          self?.finishPublish(FlutterError(code: "network", message: "Bonjour publication timed out; check local-network permission", details: nil))
        }
      case "stop":
        self.finishSearch(nil); self.stopPublishing(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  private func finishSearch(_ error: FlutterError?) {
    searchTimer?.invalidate(); searchTimer = nil
    browser?.stop(); browser = nil
    for service in services { service.stop(); service.delegate = nil }
    services = []
    let result = pendingSearch; pendingSearch = nil
    if let error = error { result?(error) } else { result?(found) }
  }
  private func finishPublish(_ error: FlutterError?) {
    publishTimer?.invalidate(); publishTimer = nil
    let result = pendingPublish; pendingPublish = nil
    if let error = error { advertisement?.stop(); advertisement = nil; result?(error) }
    else { result?(nil) }
  }
  private func stopPublishing() {
    finishPublish(FlutterError(code: "cancelled", message: "Publication stopped", details: nil))
    advertisement?.stop(); advertisement = nil
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    guard services.count < 256 else { return }
    services.append(service); service.delegate = self; service.resolve(withTimeout: 2)
  }
  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    finishSearch(FlutterError(code: "permission", message: "Bonjour browsing unavailable; check local-network permission", details: nil))
  }
  func netServiceDidResolveAddress(_ sender: NetService) {
    guard pendingSearch != nil, let txtData = sender.txtRecordData() else { return }
    let txt = NetService.dictionary(fromTXTRecord: txtData)
    guard let fpData = txt["fp"], let fp = String(data: fpData, encoding: .utf8),
      let nameData = txt["name"], let name = String(data: nameData, encoding: .utf8),
      sender.port > 0, sender.port <= 65535 else { return }
    for data in sender.addresses ?? [] {
      let host: String? = data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress, data.count >= MemoryLayout<sockaddr>.size else { return nil }
        let address = base.assumingMemoryBound(to: sockaddr.self)
        let family = Int32(address.pointee.sa_family)
        guard (family == AF_INET && data.count >= MemoryLayout<sockaddr_in>.size) ||
          (family == AF_INET6 && data.count >= MemoryLayout<sockaddr_in6>.size) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(data.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
      }
      if let host = host, found.count < 256 {
        found.append(["name": name, "fingerprint": fp, "address": host, "port": sender.port])
      }
    }
  }
  func netServiceDidPublish(_ sender: NetService) { if sender === advertisement { finishPublish(nil) } }
  func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
    if sender === advertisement { finishPublish(FlutterError(code: "network", message: "Bonjour publication failed", details: nil)) }
  }
}
