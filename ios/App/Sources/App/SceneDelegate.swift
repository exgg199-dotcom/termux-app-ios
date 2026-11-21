import UIKit

/// Creates the window with the `TerminalViewController`. The sessions live in the
/// `SessionManager` of `TermuxEnvironment.shared`, so they survive the scene being disconnected
/// (as long as the process lives), like the Android `TermuxService` outlives `TermuxActivity`.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let environment = TermuxEnvironment.shared
        environment.bootstrapIfNeeded()

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = TerminalViewController(environment: environment)
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Pick up changes to ~/.termux made while in the background (e.g. via the Files app).
        TermuxEnvironment.shared.reloadSettings()
    }
}
