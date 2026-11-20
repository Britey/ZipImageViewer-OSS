import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        self.window = window
        #if DEBUG && targetEnvironment(simulator)
        // Existing native UI regression coverage remains an explicitly selected
        // harness while equivalent RN UI tests are added. Never a Release route.
        if ProcessInfo.processInfo.environment["ZIPIMAGEVIEWER_LEGACY_UI_TESTS"] == "1" {
            window.rootViewController = UINavigationController(rootViewController: ViewController())
            window.makeKeyAndVisible()
            return
        }
        #endif
        ReactAppHost.shared.start(in: window)
        openArchives(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openArchives(URLContexts)
    }

    private func openArchives(_ contexts: Set<UIOpenURLContext>) {
        NativeAppService.shared.openExternalArchives(contexts.sorted(by: { $0.url.absoluteString < $1.url.absoluteString })
            .map { (url: $0.url, openInPlace: $0.options.openInPlace) })
    }
}
