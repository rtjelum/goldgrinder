import SpriteKit

/// 2D overlay drawn on top of the 3D view. Coordinates are view points, origin bottom-left.
final class Hud: SKScene {
    let coinIcon = SKShapeNode(circleOfRadius: 17)
    let coinLabel = SKLabelNode(fontNamed: hudFont)
    let loadIcon = SKShapeNode(circleOfRadius: 11)
    let loadLabel = SKLabelNode(fontNamed: hudFont)
    let hint = SKLabelNode(fontNamed: hudFont)
    let tag = SKLabelNode(fontNamed: hudFont)
    let joyBase = SKShapeNode(circleOfRadius: 60)
    let joyKnob = SKShapeNode(circleOfRadius: 26)
    var topInset: CGFloat = 0      // safe area (notch / Dynamic Island) on iPhone
    var bottomInset: CGFloat = 0   // safe area (home indicator) on iPhone
    enum Control: Int, CaseIterable { case forward, reverse, left, right }
    var controls: [Control: SKShapeNode] = [:]
    let newGameButton = SKShapeNode(rectOf: CGSize(width: 128, height: 40), cornerRadius: 14)
    let newGameLabel = SKLabelNode(fontNamed: hudFont)
    let winPanel = SKNode()
    // counters for the nearest button: coins on it and coins it needs
    let counters = SKNode()
    let counterTitle = SKLabelNode(fontNamed: hudFont)
    let counterShadow = SKLabelNode(fontNamed: hudFont)
    var counterCaptions: [SKLabelNode] = []
    let haveLabel = SKLabelNode(fontNamed: hudFont)
    let needLabel = SKLabelNode(fontNamed: hudFont)
    private var shownCounters = ""
    let fade = SKSpriteNode(color: .black, size: CGSize(width: 6000, height: 6000))
    private var confirming = false

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        coinIcon.fillColor = rgb(1, 0.7, 0.16); coinIcon.strokeColor = rgb(0.6, 0.32, 0.04); coinIcon.lineWidth = 4
        loadIcon.fillColor = rgb(1, 0.64, 0.14); loadIcon.strokeColor = rgb(0.6, 0.32, 0.04); loadIcon.lineWidth = 3
        for l in [coinLabel, loadLabel] {
            l.horizontalAlignmentMode = .left
            l.verticalAlignmentMode = .center
            l.fontColor = .white
        }
        coinLabel.fontSize = 32
        loadLabel.fontSize = 22
        loadIcon.isHidden = true
        hint.text = "Drag (or WASD) to drive"
        hint.fontSize = 20
        hint.fontColor = .white
        tag.fontSize = 24
        joyBase.fillColor = SKColor(white: 0, alpha: 0.25); joyBase.strokeColor = SKColor(white: 1, alpha: 0.5); joyBase.lineWidth = 3
        joyKnob.fillColor = SKColor(white: 1, alpha: 0.75); joyKnob.strokeColor = .clear
        joyBase.isHidden = true; joyKnob.isHidden = true
        for n in [coinIcon, coinLabel, loadIcon, loadLabel, hint, tag, joyBase, joyKnob] as [SKNode] { addChild(n) }

        newGameButton.fillColor = SKColor(red: 0.17, green: 0.15, blue: 0.16, alpha: 0.7)
        newGameButton.strokeColor = SKColor(red: 0.62, green: 0.64, blue: 0.7, alpha: 1)
        newGameButton.lineWidth = 2.5
        newGameLabel.fontSize = 16; newGameLabel.fontColor = .white
        newGameLabel.verticalAlignmentMode = .center
        newGameLabel.text = "NEW GAME"
        newGameButton.addChild(newGameLabel)
        newGameButton.zPosition = 10
        addChild(newGameButton)

        let shade = SKShapeNode(rectOf: CGSize(width: 4000, height: 260))
        shade.fillColor = SKColor(white: 0, alpha: 0.55); shade.strokeColor = .clear
        winPanel.addChild(shade)
        for (text, size, y, color) in [("YOU WIN!", 56.0, 40.0, SKColor(red: 1, green: 0.82, blue: 0.3, alpha: 1)),
                                       ("You melted the golden pile", 20.0, -14.0, SKColor.white),
                                       ("Next: a harder round, back up in the quarry", 17.0, -50.0, SKColor(white: 0.85, alpha: 1))]
            as [(String, CGFloat, CGFloat, SKColor)] {
            let l = SKLabelNode(fontNamed: hudFont)
            l.text = text; l.fontSize = size; l.fontColor = color; l.position = CGPoint(x: 0, y: y)
            winPanel.addChild(l)
        }
        #if os(iOS)
        // on-screen drive buttons: forward / reverse on the left, turn left / right on the right
        for c in Control.allCases {
            let b = SKShapeNode(circleOfRadius: 44)
            b.fillColor = SKColor(red: 0.17, green: 0.15, blue: 0.16, alpha: 0.4)
            b.strokeColor = SKColor(red: 1, green: 0.94, blue: 0.84, alpha: 0.85)
            b.lineWidth = 3
            b.zPosition = 10
            let arrow = SKShapeNode(path: Hud.arrowPath(c))
            arrow.fillColor = SKColor(white: 1, alpha: 0.95); arrow.strokeColor = .clear
            b.addChild(arrow)
            addChild(b)
            controls[c] = b
        }
        #endif
        counterTitle.fontSize = 15
        counterTitle.fontColor = SKColor(red: 1, green: 0.82, blue: 0.4, alpha: 1)
        counterTitle.verticalAlignmentMode = .center
        counterTitle.position = CGPoint(x: 0, y: 34)
        counterShadow.fontSize = 15
        counterShadow.fontColor = SKColor(white: 0, alpha: 0.75)
        counterShadow.verticalAlignmentMode = .center
        counterShadow.position = CGPoint(x: 1.5, y: 32.5)
        counters.addChild(counterShadow)
        counters.addChild(counterTitle)
        for (i, caption) in ["COLLECTED", "NEEDED"].enumerated() {
            let box = SKShapeNode(rectOf: CGSize(width: 116, height: 50), cornerRadius: 12)
            box.fillColor = SKColor(red: 0.17, green: 0.15, blue: 0.16, alpha: 0.7)
            box.strokeColor = SKColor(red: 1, green: 0.78, blue: 0.25, alpha: 1)
            box.lineWidth = 2.5
            box.position = CGPoint(x: i == 0 ? -64 : 64, y: 0)
            let cap = SKLabelNode(fontNamed: hudFont)
            cap.text = caption; cap.fontSize = 11; cap.fontColor = SKColor(white: 0.85, alpha: 1)
            cap.verticalAlignmentMode = .center
            cap.position = CGPoint(x: 0, y: 13)
            box.addChild(cap)
            counterCaptions.append(cap)
            let num = i == 0 ? haveLabel : needLabel
            num.fontSize = 24; num.fontColor = .white
            num.verticalAlignmentMode = .center
            num.position = CGPoint(x: 0, y: -8)
            box.addChild(num)
            counters.addChild(box)
        }
        counters.zPosition = 10
        counters.isHidden = true
        addChild(counters)
        fade.alpha = 0
        fade.zPosition = 40
        addChild(fade)
        winPanel.zPosition = 20
        winPanel.isHidden = true
        addChild(winPanel)
        layout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func didChangeSize(_ oldSize: CGSize) { layout() }

    func layout() {
        let h = size.height - topInset
        coinIcon.position = CGPoint(x: 36, y: h - 44)
        coinLabel.position = CGPoint(x: 62, y: h - 44)
        loadIcon.position = CGPoint(x: 36, y: h - 86)
        loadLabel.position = CGPoint(x: 24, y: h - 44)
        newGameButton.position = CGPoint(x: size.width - 80, y: h - 44)
        counters.position = CGPoint(x: size.width / 2, y: h - 118)
        loadLabel.fontSize = size.width < 460 ? 16 : 22   // leave room for the NEW GAME button on phones
        winPanel.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        let by = bottomInset + 70
        controls[.forward]?.position = CGPoint(x: 72, y: by + 104)
        controls[.reverse]?.position = CGPoint(x: 72, y: by)
        controls[.left]?.position = CGPoint(x: size.width - 176, y: by + 30)
        controls[.right]?.position = CGPoint(x: size.width - 72, y: by + 30)
        hint.position = CGPoint(x: size.width / 2, y: controls.isEmpty ? 60 : by + 190)
        hint.setScale(1)
        let w = hint.frame.width
        if w > size.width - 32 { hint.setScale((size.width - 32) / w) }   // fit narrow screens
    }

    /// Returns true when a tap should start a new game (the second tap within 3 seconds).
    func tapNewGame(_ p: CGPoint) -> Bool? {
        guard newGameButton.frame.insetBy(dx: -8, dy: -8).contains(p) else { return nil }   // not on the button
        if confirming {
            confirming = false
            newGameLabel.text = "NEW GAME"
            newGameButton.removeAction(forKey: "confirm")
            return true
        }
        confirming = true
        newGameLabel.text = "TAP AGAIN"
        newGameButton.run(.sequence([.wait(forDuration: 3), .run { [weak self] in
            self?.confirming = false
            self?.newGameLabel.text = "NEW GAME"
        }]), withKey: "confirm")
        return false
    }

    /// Show coins collected / needed for a button, or hide the counters (nil).
    func showCounters(_ c: (name: String, have: Int, need: Int)?, haveCaption: String = "COLLECTED") {
        let key = c.map { "\($0.name)|\($0.have)|\($0.need)|\(haveCaption)" } ?? ""
        guard key != shownCounters else { return }
        shownCounters = key
        guard let c = c else { counters.isHidden = true; return }
        counters.isHidden = false
        counterTitle.text = c.name
        counterShadow.text = c.name
        counterCaptions.first?.text = haveCaption
        haveLabel.text = "\(c.have)"
        needLabel.text = "\(c.need)"
        haveLabel.fontColor = c.have >= c.need ? SKColor(red: 0.5, green: 1, blue: 0.5, alpha: 1) : .white
    }

    /// Fade to black and back (used when heading down from the quarry to the mines).
    func fadeThrough() {
        fade.removeAllActions()
        fade.run(.sequence([.fadeAlpha(to: 1, duration: 0.5), .wait(forDuration: 0.4), .fadeAlpha(to: 0, duration: 0.7)]))
    }

    /// Big "ROUND n" banner when a new, harder round starts.
    func roundBanner(_ n: Int) {
        let banner = SKNode()
        banner.position = CGPoint(x: size.width / 2, y: size.height * 0.6)
        banner.zPosition = 30
        for (text, fs, y, color) in [("ROUND \(n)", 60.0, 18.0, SKColor(red: 1, green: 0.82, blue: 0.3, alpha: 1)),
                                     ("HARDER!", 28.0, -30.0, SKColor.white)] as [(String, CGFloat, CGFloat, SKColor)] {
            let shadow = SKLabelNode(fontNamed: hudFont)
            shadow.text = text; shadow.fontSize = fs; shadow.fontColor = SKColor(white: 0, alpha: 0.6)
            shadow.position = CGPoint(x: 3, y: y - 4)
            banner.addChild(shadow)
            let l = SKLabelNode(fontNamed: hudFont)
            l.text = text; l.fontSize = fs; l.fontColor = color
            l.position = CGPoint(x: 0, y: y)
            banner.addChild(l)
        }
        addChild(banner)
        banner.setScale(0.3)
        banner.alpha = 0
        banner.run(.sequence([
            .wait(forDuration: 0.6),
            .group([.fadeIn(withDuration: 0.25), .scale(to: 1.1, duration: 0.25)]),
            .scale(to: 1, duration: 0.12),
            .wait(forDuration: 1.8),
            .fadeOut(withDuration: 0.5),
            .removeFromParent(),
        ]))
    }

    func showWin() {
        winPanel.isHidden = false
        winPanel.setScale(0.3)
        winPanel.run(.sequence([.scale(to: 1.1, duration: 0.25), .scale(to: 1, duration: 0.12)]))
    }

    static func arrowPath(_ c: Control) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: 20)); p.addLine(to: CGPoint(x: 18, y: -12)); p.addLine(to: CGPoint(x: -18, y: -12)); p.closeSubpath()
        let angle: CGFloat = [Control.forward: 0, .reverse: .pi, .left: .pi / 2, .right: -.pi / 2][c]!
        var t = CGAffineTransform(rotationAngle: angle)
        return p.copy(using: &t)!
    }

    /// Which drive button (if any) is at this point.
    func control(at p: CGPoint) -> Control? {
        controls.first { $0.value.position.dist(p) < 58 }?.key
    }

    func showPressed(_ held: Set<Control>) {
        for (c, b) in controls {
            b.fillColor = held.contains(c) ? SKColor(red: 1, green: 0.7, blue: 0.15, alpha: 0.85)
                                           : SKColor(red: 0.17, green: 0.15, blue: 0.16, alpha: 0.4)
            b.setScale(held.contains(c) ? 0.92 : 1)
        }
    }

    func floatText(_ s: String, at p: CGPoint, color: SKColor, size fs: CGFloat) {
        let l = SKLabelNode(fontNamed: hudFont)
        l.text = s; l.fontSize = fs; l.fontColor = color
        l.position = p
        let shadow = SKLabelNode(fontNamed: hudFont)
        shadow.text = s; shadow.fontSize = fs; shadow.fontColor = SKColor(white: 0, alpha: 0.6)
        shadow.position = CGPoint(x: 2, y: -3); shadow.zPosition = -1
        l.addChild(shadow)
        addChild(l)
        l.setScale(0.5)
        l.run(.sequence([
            .group([.scale(to: 1, duration: 0.12), .moveBy(x: 0, y: 70, duration: 0.8)]),
            .fadeOut(withDuration: 0.25),
            .removeFromParent(),
        ]))
    }
}
