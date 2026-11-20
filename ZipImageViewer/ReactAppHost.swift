import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

/// One runtime for the app's single scene, retained across scene reconnects.
@MainActor
final class ReactAppHost {
    static let shared = ReactAppHost()
    private let delegate: ReactAppDelegate
    private let factory: RCTReactNativeFactory
    private var root: UIViewController?

    private init() {
        #if DEBUG
        // Bundled runs need no Metro probe, including RN's dev-tool startup.
        // A failed probe otherwise raises a LogBox banner over reader controls.
        if ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_USE_BUNDLED_JS"] == "1" {
            RCTBundleURLProviderAllowPackagerServerAccess(false)
        }
        #endif
        delegate = ReactAppDelegate()
        delegate.dependencyProvider = RCTAppDependencyProvider()
        factory = RCTReactNativeFactory(delegate: delegate)
    }

    func readerControlsView() -> UIView {
        let view = factory.rootViewFactory.view(withModuleName: "ZipImageReader", initialProperties: nil, launchOptions: nil)
        view.backgroundColor = .clear
        return ReaderChromeContainer(root: view)
    }

    func start(in window: UIWindow) {
        if let root { window.rootViewController = root; window.makeKeyAndVisible() }
        else {
            factory.startReactNative(withModuleName: "ZipImageViewer", in: window, launchOptions: nil)
            root = window.rootViewController
        }
        if let root { NativeAppService.shared.attach(presenter: root) }
    }
}

private final class ReactAppDelegate: RCTDefaultReactNativeFactoryDelegate {
    override func createRootViewController() -> UIViewController { ReactRootViewController() }
    override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }
    override func bundleURL() -> URL? {
        // Simulator CI can exercise the actual RN screen without a Metro process.
        // Release always uses a bundled asset and has no network dependency.
        #if DEBUG
        if ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_USE_BUNDLED_JS"] != "1" {
            return RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
        }
        #endif
        return Bundle.main.url(forResource: "main", withExtension: "jsbundle")
    }
}

/// UIKit retains status-bar ownership while the complete native reader is used.
/// RN's global StatusBar API would require disabling controller-based appearance,
/// which would also disable ImageViewerViewController's fullscreen preference.
final class ReactRootViewController: UIViewController {
    override var preferredStatusBarStyle: UIStatusBarStyle {
        traitCollection.userInterfaceStyle == .dark ? .lightContent : .darkContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: ReactRootViewController, _) in
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }
}

/// Fabric's hosting views can claim an empty hit after the box-none JS tree.
/// Only native hosting layers pass through; React controls retain their hits.
final class ReaderChromeContainer: UIView {
    private let root: UIView
    init(root: UIView) {
        self.root = root
        super.init(frame: root.frame)
        backgroundColor = .clear
        root.frame = bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(root)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self || hit === root { return nil }
        let typeName = NSStringFromClass(type(of: hit))
        if typeName == "RCTSurfaceView" || typeName == "RCTSurfaceHostingView" || typeName == "RCTRootComponentView" { return nil }
        return hit
    }
}
