import Flutter
import Network
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let pathMonitor = NWPathMonitor()
  private var netifs: FlutterMethodChannel?
  private var lastInterfaces: [String]?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TincanNetWatcher") else { return }
    netifs = FlutterMethodChannel(name: "tincan/netifs", binaryMessenger: registrar.messenger())
    watchNetwork()
  }

  // Same contract as Android's NetWatcher: Dart redials when the usable interfaces change.
  private func watchNetwork() {
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let names = path.status == .satisfied ? path.availableInterfaces.map(\.name) : []
      defer { self.lastInterfaces = names }
      guard let last = self.lastInterfaces, last != names, !names.isEmpty else { return }
      self.netifs?.invokeMethod("onNetworkChanged", arguments: nil)
    }
    pathMonitor.start(queue: .main)
  }
}
