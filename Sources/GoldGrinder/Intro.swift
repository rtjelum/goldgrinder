import SceneKit
import SpriteKit
import simd

/// The intro, played at the start of every new game: a taste of power with the biggest dozer and a flat blade.
/// Room 1 is a vault full of coins with a button that opens the gate; room 2 is full of gold and has a crusher.
/// Then it's on to the quarry, back in dozer 1.
final class Intro {
    static let dx: CGFloat = -130              // it sits far to the other side of the mines in the same scene
    static let need = 150                      // coins on the button to open the gate
    static let blockNeed = 50                  // gold into the crusher to finish
    /// 50 lumps of every size (worth 1 to 4 each, 124 gold in all)
    static let blocks = Array(repeating: 3, count: 10) + Array(repeating: 2, count: 12) + Array(repeating: 1, count: 14) + Array(repeating: 0, count: 14)
    let coinRoom = CGRect(x: Intro.dx - 20, y: -6, width: 40, height: 30)
    let goldRoom = CGRect(x: Intro.dx - 22, y: 24, width: 44, height: 34)
    let gate = Gate(y: 24, x: Intro.dx + 9, half: 4.5)   // wide enough for the biggest blade
    let button = CGPoint(x: Intro.dx + 8, y: 12)
    let buttonR: CGFloat = 3.2
    let pileCentre = CGPoint(x: Intro.dx - 8, y: 9)
    let pileR: CGFloat = 11
    let crusherY: CGFloat = 41
    /// The intro's coins are twice the size of the mines' coins.
    let coins = CoinField(minX: Float(Intro.dx) - 24, minY: -7, maxX: Float(Intro.dx) + 24, maxY: 60,
                          radius: Float(Art.coinRadius) * 2, thickness: Float(Art.coinThick) * 1.6)
    var opened = false
    var have = 0                               // coins on the button right now
    var drawn = -1                             // ring step last drawn
    var leaving: CGFloat = -1                  // >= 0 while heading on to the quarry
    let plateMat = Art.pbr(rgb(0.25, 0.75, 0.95), metal: 0.6, rough: 0.35, emit: rgb(0.05, 0.3, 0.45))
    let ringMat = SCNMaterial()
    var start: CGPoint { CGPoint(x: Intro.dx + 12, y: -1) }

}

extension Game {

    // MARK: Building

    func buildIntro() {
        let it = intro
        let hole = [(p: it.button, r: it.buttonR)]

        // floor: blue-grey vault cobbles, dark ground around
        let ground = floorShape(CGRect(x: Intro.dx - 60, y: -40, width: 120, height: 140), holes: hole,
                                mat: floorMat((0.07, 0.08, 0.13), seed: 9, repeats: 24))
        ground.position = v3(0, -0.03, 0)
        scene.rootNode.addChildNode(ground)
        let cobbles = Art.cobbleImage(seed: 11, stone: (0.36, 0.4, 0.5), grout: (0.13, 0.15, 0.22), count: 6)
        for (r, holes) in [(it.coinRoom, hole), (it.goldRoom, [])] {
            let mat = Art.pbr(cobbles, rough: 0.85)
            mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
            mat.diffuse.mipFilter = .linear
            #if os(macOS)
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(r.width / 4, r.height / 4, 1)
            #else
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(r.width / 4), Float(r.height / 4), 1)
            #endif
            scene.rootNode.addChildNode(floorShape(r, holes: holes, mat: mat))
        }

        // icy blue crystal walls
        let mats: [SCNMaterial] = [
            Art.pbr(rgb(0.2, 0.4, 0.75), metal: 0.15, rough: 0.2, emit: rgb(0.02, 0.06, 0.14)),
            Art.pbr(rgb(0.45, 0.7, 0.95), metal: 0.1, rough: 0.18, emit: rgb(0.05, 0.1, 0.18)),
            Art.pbr(rgb(0.12, 0.25, 0.5), metal: 0.2, rough: 0.3, emit: rgb(0.01, 0.03, 0.08)),
            Art.pbr(rgb(0.7, 0.88, 1.0), metal: 0.05, rough: 0.15, emit: rgb(0.1, 0.16, 0.26)),
        ]
        buildWalls(rects: [it.coinRoom, it.goldRoom], gates: [it.gate], openings: [-1000, it.crusherY], openingHalf: 1.9,
                   mats: mats, rockMat: Art.pbr(rgb(0.1, 0.12, 0.2), rough: 0.9), seed: 99)
        buildGates([it.gate], cap: rgb(1, 0.75, 0.2))

        // the button: a well with a glowing plate, its name on it, and a progress ring around it
        buildWell(it.button, it.buttonR)
        let bn = SCNNode()
        bn.position = world(it.button)
        let disc = SCNCylinder(radius: it.buttonR, height: 0.02); disc.radialSegmentCount = 64
        disc.materials = [it.plateMat]
        let dn = SCNNode(geometry: disc); dn.position = v3(0, discY, 0); bn.addChildNode(dn)
        let labelMat = SCNMaterial()
        labelMat.lightingModel = .constant
        labelMat.diffuse.contents = Art.buttonLabel("OPEN GATE")
        labelMat.writesToDepthBuffer = false
        let lp = SCNPlane(width: it.buttonR * 1.5, height: it.buttonR * 1.5 * 160 / 512 * 1.7)
        lp.materials = [labelMat]
        let ln = SCNNode(geometry: lp); ln.eulerAngles = v3(-.pi / 2, 0, 0); ln.renderingOrder = 5
        let turn = SCNNode(); turn.eulerAngles = v3(0, .pi / 4, 0); turn.position = v3(0, discY + 0.015, 0)
        turn.addChildNode(ln); bn.addChildNode(turn)
        let down = SCNAction.fadeOpacity(to: 0.25, duration: 0.9); down.timingMode = .easeInEaseOut
        let up = SCNAction.fadeOpacity(to: 1, duration: 0.9); up.timingMode = .easeInEaseOut
        ln.runAction(.repeatForever(.sequence([down, up])))
        it.ringMat.lightingModel = .constant
        it.ringMat.writesToDepthBuffer = false
        let ring = SCNPlane(width: (it.buttonR + 0.75) * 2, height: (it.buttonR + 0.75) * 2); ring.materials = [it.ringMat]
        let rn = SCNNode(geometry: ring); rn.eulerAngles = v3(-.pi / 2, 0, 0); rn.position = v3(0, 0.015, 0)
        bn.addChildNode(rn)
        scene.rootNode.addChildNode(bn)

        // the vault floor, covered in coins
        it.coins.wells = [SIMD3<Float>(Float(it.button.x), Float(it.button.y), Float(it.buttonR))]
        it.coins.wellDepth = Float(wellDepth)
        scene.rootNode.addChildNode(it.coins.root)
        it.coins.render(material: Art.coinMat)

        // the gold room: one crusher, lumps of every size (the big dozer can move them all)
        let q = introQuarry
        q.rects = [it.goldRoom]
        let c = Crusher(room: 0, x0: it.goldRoom.minX, y: it.crusherY, mouth: Quarry.sizes[3] + 0.55, need: Intro.blockNeed)
        q.crushers = [c]
        buildCrusher(c)
        q.dust.addParticleSystem(Art.particles(color: rgb(0.9, 0.8, 0.55), size: 0.35, life: 1.0, speed: 1.6,
                                               spread: 60, gravity: 0.6, additive: false))
        scene.rootNode.addChildNode(q.dust)
        fillIntro()
    }

    /// Put the coin pile and the gold lumps (back) in place and close the gate: the same layout every time.
    func fillIntro() {
        let it = intro
        let q = introQuarry
        let c = q.crushers[0]
        it.coins.reset()
        for b in q.blocks { b.node.removeFromParentNode() }
        q.blocks = []
        c.crushed = 0; c.pending = 0; c.busy = 0; c.done = false
        for r in c.riders { r.node.removeFromParentNode() }
        c.riders = []
        it.opened = false; it.have = 0; it.drawn = -1; it.leaving = -1
        it.gate.bars.removeAllActions()
        it.gate.bars.position = v3(it.gate.x, 0, -it.gate.y)
        it.gate.bars.isHidden = false
        var rng = SeededRNG(s: 4242)
        // one big pile of coins on the far side: a wide mound 2 coins deep (the same stacking rules as everywhere)
        let layer = it.coins.thick * 0.95
        let sp = CGFloat(it.coins.r) * 1.8   // tightly packed
        let room = it.coinRoom.insetBy(dx: 0.35, dy: 0.35)
        for k in 0..<2 {
            let rr = it.pileR * (1 - CGFloat(k) * 0.15)          // the top layer a bit smaller: a mound
            var row = 0
            var y = it.pileCentre.y - rr
            while y < it.pileCentre.y + rr {
                var x = it.pileCentre.x - rr + ((row + k) % 2 == 0 ? 0 : sp / 2)
                while x < it.pileCentre.x + rr {
                    let wobble = 1 + 0.12 * sin(atan2(y - it.pileCentre.y, x - it.pileCentre.x) * 3 + CGFloat(k))
                    let p = CGPoint(x: x + CGFloat.random(in: -0.03...0.03, using: &rng), y: y + CGFloat.random(in: -0.03...0.03, using: &rng))
                    if p.dist(it.pileCentre) < rr * wobble && room.contains(p) && CGFloat.random(in: 0...1, using: &rng) < 0.94 {
                        it.coins.add(Float(p.x), Float(p.y), h: layer * Float(k), value: 1, grow: false)
                    }
                    x += sp
                }
                y += sp * 0.866
                row += 1
            }
        }
        for cls in Intro.blocks {
            let r = Quarry.sizes[cls]
            var t = 0
            while t < 3000 {
                t += 1
                let room = it.goldRoom
                let p = CGPoint(x: CGFloat.random(in: room.minX + r + 1...room.maxX - r - 1, using: &rng),
                                y: CGFloat.random(in: room.minY + r + 1...room.maxY - r - 1, using: &rng))
                if p.x < c.x0 + c.feedLen + r + 1.6 && abs(p.y - c.y) < c.mouth + r + 1.4 { continue }
                if p.y < it.gate.y + r + 1.6 { continue }
                if q.blocks.contains(where: { $0.p.dist(p) < $0.r + r + 0.9 }) { continue }
                addBlock(to: q, room: 0, cls: cls, at: p, rng: &rng)
                break
            }
        }
        it.coins.render(material: Art.coinMat)
    }

    /// Begin the intro (every new game): biggest dozer, flat blade, in the coin vault.
    func startIntro() {
        fillIntro()
        stage = .intro
        tier = specs.count - 1
        applyTier()
        pos = intro.start; prevPos = pos; camTarget = pos
        heading = .pi / 2; prevHeading = heading
        camScale = baseZoom
        applyStageLook()
    }

    // MARK: Rules

    /// The intro's walls: the vault, the gold room, and the gate between them.
    func introBlocked(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Bool {
        let it = intro
        let a = y < it.gate.y ? it.coinRoom : it.goldRoom
        if x < a.minX + r || x > a.maxX - r { return true }
        if y < it.coinRoom.minY + r || y > it.goldRoom.maxY - r { return true }
        if abs(y - it.gate.y) < r + wallBand {
            if !it.opened || abs(x - it.gate.x) > it.gate.half - r { return true }
        }
        return false
    }

    // MARK: Loop

    func updateIntro(_ dt: CGFloat) {
        let it = intro
        let blade = makeBlade()
        it.coins.heapTop = dozer.plowTop
        let contacts = it.coins.step(dt: Float(dt), blade: blade, fillers: [],
                                     blocked: { [unowned self] x, y in self.introBlocked(CGFloat(x), CGFloat(y), 0.1) },
                                     sold: { _, _, _ in })
        let load = CGFloat(contacts) + updateQuarry(dt)
        pushLoad = lerp(pushLoad, load, 1 - exp(-10 * dt))
        updateIntroButton()
        updateVisuals(dt, pushing: load > 0)
        it.coins.render(material: Art.coinMat)
        updateTwinkles(dt)
        updateIntroLeaving(dt)

        hud.loadLabel.text = "INTRO  ·  DOZER \(tier + 1)"
        if pos.y < it.gate.y {
            hud.showCounters(("OPEN GATE", min(it.have, Intro.need), Intro.need))
        } else {
            let c = introQuarry.crushers[0]
            hud.showCounters(("CRUSHER", min(c.crushed, c.need), c.need), haveCaption: "GOLD IN")
        }
    }

    /// Count the coins in the button's well; enough of them sink in and the gate opens.
    func updateIntroButton() {
        let it = intro
        let f = it.coins
        var n = 0
        if !it.opened {
            let bx = Float(it.button.x), by = Float(it.button.y), r2 = Float(it.buttonR * it.buttonR)
            for i in 0..<f.count where f.state[i] == .asleep || f.state[i] == .awake {
                let dx = f.px[i] - bx, dy = f.py[i] - by
                if dx * dx + dy * dy < r2 { n += 1 }
            }
            it.have = n
            if n >= Intro.need {
                it.opened = true
                for i in 0..<f.count where f.state[i] != .dead {
                    let dx = f.px[i] - bx, dy = f.py[i] - by
                    if dx * dx + dy * dy < r2 { f.consume(i) }
                }
                burst.position = world(it.button, 0.3)
                burstTimer = 0.5
                it.gate.bars.runAction(.sequence([.move(by: v3(0, -1.9, 0), duration: 0.6), .hide()]))
                floatText("GATE OPEN!", at: CGPoint(x: it.gate.x, y: it.gate.y), h: 2, color: .white, size: 36)
                #if os(iOS)
                DispatchQueue.main.async { [weak self] in
                    self?.haptic.impactOccurred()
                    self?.haptic.prepare()
                }
                #endif
            }
        }
        let progress = it.opened ? 1 : min(1, CGFloat(it.have) / CGFloat(Intro.need))
        it.plateMat.emission.intensity = 0.4 + progress * 1.4
        let step = Int(progress * 40)
        if step != it.drawn {
            it.drawn = step
            it.ringMat.diffuse.contents = Art.ringImage(progress: CGFloat(step) / 40, color: CGColor(red: 0.4, green: 0.85, blue: 1, alpha: 1),
                                                        inner: (it.buttonR + 0.2) / (it.buttonR + 0.75))
        }
    }

    /// The gold room's crusher has had enough: on to the quarry.
    func finishIntro() {
        intro.leaving = 0
        floatText("TO THE QUARRY!", at: pos, h: 2.5, color: rgb(1, 0.85, 0.35), size: 40)
    }

    /// Fade out, start the quarry in dozer 1, fade in.
    func updateIntroLeaving(_ dt: CGFloat) {
        let it = intro
        guard it.leaving >= 0 else { return }
        let before = it.leaving
        it.leaving += dt
        if before < 1.6 && it.leaving >= 1.6 { DispatchQueue.main.async { [weak self] in self?.hud.fadeThrough() } }
        if before < 2.2 && it.leaving >= 2.2 {
            it.leaving = -1
            stage = .quarry
            applyStageLook()
            tier = 0
            applyTier()
            pos = mainQuarry.start; prevPos = pos; camTarget = pos
            heading = .pi / 2; prevHeading = heading
            velocity = 0; pushLoad = 0; pop = 0
            camScale = baseZoom
            hintShown = true
            hud.hint.removeAllActions()
            hud.hint.alpha = 1
        }
    }
}
