import UIKit
import SceneKit

/// iPhone host. The game itself is shared with the Mac build (Sources/GoldGrinder).

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = GameViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// SCNView that turns one-finger drags into the on-screen joystick.
final class TouchView: SCNView {
    weak var game: Game?

    /// UIKit has its origin top-left; the HUD (SpriteKit) has it bottom-left.
    private func hudPoint(_ t: UITouch) -> CGPoint {
        let p = t.location(in: self)
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { game?.joyBegin(hudPoint(t)) }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let t = touches.first { game?.joyMove(hudPoint(t)) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { game?.joyEnd() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { game?.joyEnd() }
}

final class GameViewController: UIViewController {
    private var game: Game!

    override func loadView() {
        let v = TouchView(frame: CGRect(x: 0, y: 0, width: 393, height: 852), options: [
            SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)
        ])
        v.isMultipleTouchEnabled = false
        game = Game(view: v)
        v.game = game
        view = v
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        game.hud.topInset = view.safeAreaInsets.top
        game.hud.layout()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}
