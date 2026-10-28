import AppKit
import SceneKit

/// macOS host window. The game lives in Game.swift / Art.swift / Hud.swift (shared with iOS).
final class GameView: SCNView {
    var game: Game!
    override var acceptsFirstResponder: Bool { true }
    func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with e: NSEvent) { game.touchBegan(0, point(e)) }
    override func mouseDragged(with e: NSEvent) { game.touchMoved(0, point(e)) }
    override func mouseUp(with e: NSEvent) { game.touchEnded(0) }
    override func keyDown(with e: NSEvent) { game.keys.insert(e.keyCode) }
    override func keyUp(with e: NSEvent) { game.keys.remove(e.keyCode) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var game: Game!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 500, height: 860)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Gold Grinder"
        let view = GameView(frame: rect, options: [
            SCNView.Option.preferredRenderingAPI.rawValue: NSNumber(value: SCNRenderingAPI.metal.rawValue)
        ])
        game = Game(view: view)
        view.game = game
        print("Renderer:", view.renderingAPI == .metal ? "Metal" : "other")
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
