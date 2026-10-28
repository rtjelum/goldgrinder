import SceneKit
import SpriteKit
import simd
#if os(iOS)
import UIKit
#endif

// MARK: - 2D math (gameplay runs on the ground plane: game (x, y) = world (x, 0, -y))

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    var length: CGFloat { hypot(x, y) }
    var normalized: CGPoint { let l = length; return l > 0.0001 ? CGPoint(x: x / l, y: y / l) : .zero }
    func dist(_ o: CGPoint) -> CGFloat { hypot(x - o.x, y - o.y) }
}
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerpP(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }
func angleDiff(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    var d = b - a
    while d > .pi { d -= 2 * .pi }
    while d < -.pi { d += 2 * .pi }
    return d
}
func world(_ p: CGPoint, _ h: CGFloat = 0) -> SCNVector3 { v3(p.x, h, -p.y) }
func short(_ v: Double) -> String {
    if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
    if v >= 10_000 { return String(format: "%.1fK", v / 1_000) }
    return "\(Int(v))"
}

// MARK: - Level data

struct Area {
    let rect: CGRect      // walkable floor
    let value: Float      // coin value in this mine
    let beltStart: CGPoint, beltEnd: CGPoint   // the conveyor that feeds this mine (outside its left wall)
    let supply: Int       // coins the belt holds in total
    let rate: CGFloat     // coins per second when full (slows down as it runs dry)
}

/// A conveyor belt in a corner of a mine: the only source of gold. It slowly runs dry.
final class Belt {
    let area: Int
    let start: CGPoint, end: CGPoint
    let supply: Int
    let rate: CGFloat
    var left: Int
    var timer: CGFloat = 0
    var scroll: CGFloat = 0
    var riders: [(node: SCNNode, t: CGFloat, n: Int)] = []                              // clumps of coins on the belt
    var flyers: [(node: SCNNode, from: CGPoint, to: CGPoint, t: CGFloat, spin: CGFloat)] = []   // coins flying into the mine
    let beltMat = SCNMaterial()
    let heap = SCNNode()
    let sign = SCNNode()
    let signMat = SCNMaterial()
    var drawnLeft = -1
    let halfWidth: CGFloat = 0.55
    let top: CGFloat = 0.55
    init(area: Int, a: Area) {
        self.area = area; start = a.beltStart; end = a.beltEnd; supply = a.supply; rate = a.rate; left = a.supply
    }
    var dir: CGPoint { (end - start).normalized }
    var length: CGFloat { start.dist(end) }
    /// Random landing spot on the mine floor, past the wall.
    func landingSpot() -> CGPoint {
        let side = CGPoint(x: -dir.y, y: dir.x)
        return end + dir * CGFloat.random(in: 2.0...4.2) + side * CGFloat.random(in: -1.5...1.5)
    }
}

final class Gate {
    let y: CGFloat, x: CGFloat
    let half: CGFloat = 2.6
    var open = false
    let bars = SCNNode()
    init(y: CGFloat, x: CGFloat) { self.y = y; self.x = x }
}

struct DozerSpec {
    let speed: CGFloat
    let power: CGFloat
}

enum TagKind: Equatable { case gate(Int), dozer(Int), win }

/// A small recessed button in the floor. Pile enough coins on it and they melt into it.
final class Tag {
    let kind: TagKind
    let pos: CGPoint
    let area: Int
    let price: Double            // total coin value needed
    var radius: CGFloat = 1
    var amount: Double = 0       // value of the coins sitting on it right now
    var drawnKey = ""
    var meltT: CGFloat = -1      // >= 0 while the pile is melting
    var blobHeight: CGFloat = 0.2
    let node = SCNNode()
    let disc = SCNNode()
    let discMat = Art.pbr(rgb(0.95, 0.6, 0.12), metal: 0.6, rough: 0.35, emit: rgb(0.5, 0.25, 0.02))
    let ringMat = SCNMaterial()
    let sign = SCNNode()
    let signMat = SCNMaterial()
    let blob = SCNNode()
    let blobMat = Art.pbr(rgb(1, 0.62, 0.12), metal: 0.7, rough: 0.2, emit: rgb(1.0, 0.45, 0.05))
    init(kind: TagKind, pos: CGPoint, area: Int, price: Double) {
        self.kind = kind; self.pos = pos; self.area = area; self.price = price
    }
    func contains(_ x: Float, _ y: Float) -> Bool {
        let dx = CGFloat(x) - pos.x, dy = CGFloat(y) - pos.y
        return dx * dx + dy * dy < radius * radius
    }
}

// MARK: - Game

final class Game: NSObject, SCNSceneRendererDelegate {
    // Each belt holds a little more than the mine's dozer + gate cost (110%), so you have to collect nearly every coin.
    let areas: [Area] = [
        Area(rect: CGRect(x: -8, y: -6, width: 16, height: 14), value: 1,
             beltStart: CGPoint(x: -14.5, y: 4.5), beltEnd: CGPoint(x: -8.4, y: 4.5), supply: 1070, rate: 8),
        Area(rect: CGRect(x: -10, y: 8, width: 20, height: 16), value: 3,
             beltStart: CGPoint(x: -16.5, y: 12), beltEnd: CGPoint(x: -10.4, y: 12), supply: 2020, rate: 11),
        Area(rect: CGRect(x: -12, y: 24, width: 24, height: 20), value: 8,
             beltStart: CGPoint(x: -18.5, y: 28), beltEnd: CGPoint(x: -12.4, y: 28), supply: 4400, rate: 16),
        Area(rect: CGRect(x: -14, y: 44, width: 28, height: 24), value: 25,
             beltStart: CGPoint(x: -20.5, y: 58), beltEnd: CGPoint(x: -14.4, y: 58), supply: 4450, rate: 18),
    ]
    let gates = [Gate(y: 8, x: 4.6), Gate(y: 24, x: -6.4), Gate(y: 44, x: 6.4)]
    let specs: [DozerSpec] = [
        DozerSpec(speed: 4.2, power: 60),
        DozerSpec(speed: 4.6, power: 110),
        DozerSpec(speed: 5.0, power: 180),
        DozerSpec(speed: 5.4, power: 280),
        DozerSpec(speed: 5.8, power: 400),
        DozerSpec(speed: 6.2, power: 560),
    ]
    var tags: [Tag] = []

    let scene = SCNScene()
    let hud: Hud
    weak var view: SCNView?
    let coins = CoinField(minX: -15, minY: -7, maxX: 15, maxY: 69)
    var belts: [Belt] = []

    let rig = SCNNode()
    let camNode = SCNNode()
    var dozer: DozerModel.Built!
    let dust = SCNNode()
    let smoke = SCNNode()
    let burst = SCNNode()

    // State
    var tier = 0
    var shownTier = -1
    var pos = CGPoint(x: 5, y: -3)
    var heading: CGFloat = .pi / 2
    var velocity: CGFloat = 0
    var pushLoad: CGFloat = 0
    var burstTimer: CGFloat = 0
    var lastTime: TimeInterval = 0
    var clock: CGFloat = 0
    var camTarget = CGPoint(x: 5, y: -3)
    var camScale: CGFloat = 7
    var hintShown = true
    var won = false
    #if os(iOS)
    let haptic = UIImpactFeedbackGenerator(style: .heavy)   // made once: starting haptics on the first melt caused a hitch
    #endif
    /// Things that are otherwise first drawn mid-game (molten blob, flying coins, coin piles, sparks), drawn once
    /// under the floor at launch so iPhone builds their shaders during loading instead of at the first melt.
    let warmUp = SCNNode()
    var reversing = false   // touch steering is backing up
    var resetRequested = false
    let startPos = CGPoint(x: 5, y: -3)
    var pop: CGFloat = 0
    var tagRedrawTimer: CGFloat = 0
    var dozerModels: [DozerModel.Built] = []
    var prevPos = CGPoint(x: 5, y: -3)
    var prevHeading: CGFloat = .pi / 2

    // Input (written from the UI thread, read in the render loop)
    var joyOrigin = CGPoint.zero
    var joyVec = CGPoint.zero
    var joyActive = false
    var keys = Set<UInt16>()

    let wallBand: CGFloat = 0.35   // half-thickness of the crystal walls between mines
    var spec: DozerSpec { specs[tier] }
    /// Zoom that shows about 9 units across, so narrow phones see as much as the Mac window.
    var baseZoom: CGFloat {
        guard let size = view?.bounds.size, size.height > 0 else { return 7 }
        return max(7, 4.6 / (size.width / size.height))
    }
    var forward: CGPoint { CGPoint(x: cos(heading), y: sin(heading)) }
    func areaUnlocked(_ i: Int) -> Bool { i == 0 || gates[i - 1].open }

    // MARK: Setup

    init(view: SCNView) {
        self.view = view
        hud = Hud(size: view.bounds.size)
        super.init()
        tags = [
            // Each button needs a big pile: a mine's belt holds just enough for its dozer and gate (110%),
            // so you have to collect nearly every coin it delivers.
            Tag(kind: .dozer(1), pos: CGPoint(x: 2.0, y: -1.0), area: 0, price: 450),      // mine 1 belt: 1070 coins
            Tag(kind: .gate(0), pos: CGPoint(x: 1.0, y: 3.8), area: 0, price: 520),
            Tag(kind: .dozer(2), pos: CGPoint(x: 3.5, y: 14), area: 1, price: 2550),      // mine 2 belt: 2020 coins
            Tag(kind: .gate(1), pos: CGPoint(x: -1.0, y: 19.5), area: 1, price: 2970),
            Tag(kind: .dozer(3), pos: CGPoint(x: -3.0, y: 37), area: 2, price: 9000),     // mine 3 belt: 4400 coins
            Tag(kind: .dozer(4), pos: CGPoint(x: -3.0, y: 37), area: 2, price: 11500),
            Tag(kind: .gate(2), pos: CGPoint(x: 4.0, y: 32), area: 2, price: 11500),
            Tag(kind: .dozer(5), pos: CGPoint(x: 4.0, y: 62), area: 3, price: 50000),     // mine 4 belt: 4450 coins
            // the big golden pile: about 2000 coins from the last mine wins the game
            Tag(kind: .win, pos: CGPoint(x: 2.0, y: 52), area: 3, price: 51000),
        ]
        camScale = baseZoom
        buildLighting()
        buildFloor()
        buildWalls()
        buildGates()
        buildTags()
        buildBelts()
        buildEffects()
        applyTier()
        buildCamera()
        scene.rootNode.addChildNode(coins.root)
        coins.render(material: Art.coinMat)
        refreshTags()
        #if os(iOS)
        hud.hint.text = "▲▼ drive · ◀ ▶ turn · pile gold on the buttons"
        #else
        hud.hint.text = "W/S drive · A/D turn · pile gold on the buttons"
        #endif
        hud.layout()
        hud.coinIcon.isHidden = true
        hud.coinLabel.isHidden = true

        view.scene = scene
        view.pointOfView = camNode
        view.delegate = self
        view.overlaySKScene = hud
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = rgb(0.05, 0.03, 0.08)
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.loops = true
        view.prepare(dozerModels.map { $0.node }, completionHandler: nil)
        warmUpGraphics()
    }

    func warmUpGraphics() {
        #if os(iOS)
        haptic.prepare()
        #endif
        warmUp.position = world(pos, -2.5)        // under the floor: drawn (so compiled) but never seen
        var parts: [SCNGeometry?] = [Art.coinGeo, tags.first?.blob.geometry]
        parts += clumps.map { $0.geo }
        for (i, g) in parts.enumerated() {
            let n = SCNNode(geometry: g)
            n.position = v3(CGFloat(i % 4) * 0.3 - 0.45, 0, CGFloat(i / 4) * 0.3)
            n.scale = v3(0.2, 0.2, 0.2)
            warmUp.addChildNode(n)
        }
        scene.rootNode.addChildNode(warmUp)
        view?.prepare([warmUp], completionHandler: nil)
        // sparks and dust: emit a few under the floor too
        burst.position = world(pos, -6)
        burst.particleSystems?.first?.particleColor = SKColor(white: 1, alpha: 0)   // invisible while warming up
        burstTimer = 0.3
        dust.position = world(pos, -2.5)
    }

    func buildCamera() {
        let cam = SCNCamera()
        cam.usesOrthographicProjection = true
        cam.orthographicScale = Double(camScale)
        cam.zNear = 1
        cam.zFar = 200
        cam.wantsHDR = true
        cam.wantsExposureAdaptation = false
        cam.bloomIntensity = 0.6
        cam.bloomThreshold = 0.9
        cam.bloomBlurRadius = 10
        cam.vignettingIntensity = 0.6
        cam.vignettingPower = 1.0
        camNode.camera = cam
        scene.rootNode.addChildNode(rig)
        rig.addChildNode(camNode)
        camNode.position = v3(20, 24, 20)
        camNode.look(at: v3(0, 0, 0))
        rig.position = world(pos)
    }

    func buildLighting() {
        scene.background.contents = rgb(0.05, 0.03, 0.08)
        scene.lightingEnvironment.contents = Art.environmentImage()
        scene.lightingEnvironment.intensity = 1.3

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 1700
        sun.color = rgb(1, 0.93, 0.85)
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowColor = SKColor(white: 0, alpha: 0.5)
        sun.shadowSampleCount = 8
        sun.shadowRadius = 2
        sun.automaticallyAdjustsShadowProjection = true
        sun.maximumShadowDistance = 50
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.eulerAngles = v3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(sunNode)

        let amb = SCNLight()
        amb.type = .ambient
        amb.intensity = 320
        amb.color = rgb(0.7, 0.6, 0.95)
        let ambNode = SCNNode()
        ambNode.light = amb
        scene.rootNode.addChildNode(ambNode)
    }

    func floorMat(_ base: (CGFloat, CGFloat, CGFloat), seed: UInt64, repeats: CGFloat) -> SCNMaterial {
        let m = Art.pbr(Art.floorImage(base: base, seed: seed), rough: 0.95)
        m.diffuse.wrapS = .repeat
        m.diffuse.wrapT = .repeat
        #if os(macOS)
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(repeats, repeats, 1)
        #else
        m.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(repeats), Float(repeats), 1)
        #endif
        return m
    }

    func buildFloor() {
        let outer = SCNPlane(width: 120, height: 140)
        outer.materials = [floorMat((0.16, 0.11, 0.2), seed: 1, repeats: 24)]
        let on = SCNNode(geometry: outer)
        on.eulerAngles = v3(-.pi / 2, 0, 0)
        on.position = v3(0, -0.03, -30)
        scene.rootNode.addChildNode(on)
        let mat = floorMat((0.4, 0.35, 0.44), seed: 2, repeats: 4)
        for a in areas {
            let p = SCNPlane(width: a.rect.width, height: a.rect.height)
            p.materials = [mat]
            let n = SCNNode(geometry: p)
            n.eulerAngles = v3(-.pi / 2, 0, 0)
            n.position = v3(a.rect.midX, 0, -a.rect.midY)
            scene.rootNode.addChildNode(n)
        }
    }

    /// Sharp purple crystal walls. Their bases sit on the real collision edges, so what you see is what you hit.
    func buildWalls() {
        var rng = SeededRNG(s: 42)
        func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }
        let mats: [SCNMaterial] = [
            Art.pbr(rgb(0.36, 0.17, 0.62), metal: 0.15, rough: 0.22, emit: rgb(0.06, 0.01, 0.12)),
            Art.pbr(rgb(0.55, 0.3, 0.88), metal: 0.1, rough: 0.18, emit: rgb(0.1, 0.03, 0.18)),
            Art.pbr(rgb(0.26, 0.12, 0.45), metal: 0.2, rough: 0.3, emit: rgb(0.03, 0.0, 0.07)),
            Art.pbr(rgb(0.72, 0.5, 1.0), metal: 0.05, rough: 0.15, emit: rgb(0.16, 0.06, 0.26)),
        ]
        var protos: [SCNGeometry] = []
        for k in 0..<12 {
            let g = Art.crystal(sides: k % 3 == 0 ? 5 : 6, body: Float(r(1.2, 2.6)), tip: Float(r(0.7, 1.4)), twist: Float(r(-0.25, 0.25)))
            g.materials = [mats[k % mats.count]]
            protos.append(g)
        }
        let rockMat = Art.pbr(rgb(0.17, 0.11, 0.24), rough: 0.9)
        let rock: SCNGeometry = { let g = SCNSphere(radius: 1); g.segmentCount = 6; g.materials = [rockMat]; return g }()
        let container = SCNNode()

        /// One shard: `rad` base radius, `height` total height, leaning `lean` radians toward `out`.
        func shard(_ x: CGFloat, _ y: CGFloat, rad: CGFloat, height: CGFloat, out: CGPoint, lean: CGFloat) {
            let n = SCNNode(geometry: protos[Int(r(0, 11.99))])
            let unitH: CGFloat = 3.0
            n.simdScale = [Float(rad), Float(height / unitH), Float(rad)]
            n.position = v3(x, -0.05, -y)
            // lean away from the play area (world dir of `out` is (out.x, -out.y)), plus a random spin
            let axis = simd_normalize(SIMD3<Float>(Float(-out.y), 0, Float(-out.x)))
            let tilt = simd_quatf(angle: Float(lean), axis: axis)
            let spin = simd_quatf(angle: Float(r(0, 6.28)), axis: [0, 1, 0])
            n.simdOrientation = tilt * spin
            container.addChildNode(n)
        }
        func boulder(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
            let n = SCNNode(geometry: rock)
            n.position = v3(x, 0, -y)
            n.scale = v3(size * r(0.9, 1.4), size * r(0.35, 0.6), size * r(0.9, 1.4))
            n.eulerAngles = v3(0, r(0, 3), 0)
            container.addChildNode(n)
        }
        /// A crystal wall along a line. `out` points away from the play area; low walls face the camera.
        func wall(from a: CGPoint, to b: CGPoint, out: CGPoint, low: Bool, skip: ((CGPoint) -> Bool)? = nil) {
            let len = a.dist(b)
            let dir = (b - a).normalized
            var d: CGFloat = 0
            while d <= len {
                let p = a + dir * d
                d += low ? r(0.2, 0.3) : r(0.35, 0.55)
                if skip?(p) == true { continue }
                for row in 0..<3 {
                    // low walls (facing the camera) are thin short spikes so they stay sharp without hiding the dozer
                    let rad = low ? r(0.07, 0.15) + CGFloat(row) * 0.05 : r(0.2, 0.36) + CGFloat(row) * 0.12
                    let off = rad * 0.95 + CGFloat(row) * (low ? 0.35 : 0.75) + r(0, 0.12)
                    let maxH: CGFloat = low ? 0.5 + CGFloat(row) * 0.3 : 1.2 + CGFloat(row) * 0.9
                    let h = r(maxH * 0.5, maxH)
                    shard(p.x + out.x * off + dir.x * r(-0.15, 0.15), p.y + out.y * off + dir.y * r(-0.15, 0.15),
                          rad: rad, height: h, out: out, lean: r(0.05, 0.4))
                    if row == 0 && r(0, 1) < 0.5 {   // a small spike in front for a jagged edge
                        shard(p.x + out.x * rad * 0.6, p.y + out.y * rad * 0.6, rad: rad * 0.55,
                              height: h * r(0.4, 0.7), out: out, lean: r(0.3, 0.7))
                    }
                }
                if !low { boulder(p.x + out.x * 1.2, p.y + out.y * 1.2, r(0.6, 1.0)) }
            }
        }

        for (i, a) in areas.enumerated() {
            let ra = a.rect
            // left side faces away from the camera (tall), right side faces it (low)
            let beltY = a.beltStart.y
            wall(from: CGPoint(x: ra.minX, y: ra.minY), to: CGPoint(x: ra.minX, y: ra.maxY), out: CGPoint(x: -1, y: 0), low: false,
                 skip: { abs($0.y - beltY) < 1.0 })   // opening for the conveyor belt
            wall(from: CGPoint(x: ra.maxX, y: ra.minY), to: CGPoint(x: ra.maxX, y: ra.maxY), out: CGPoint(x: 1, y: 0), low: true)
            if i == 0 {
                wall(from: CGPoint(x: ra.minX, y: ra.minY), to: CGPoint(x: ra.maxX, y: ra.minY), out: CGPoint(x: 0, y: -1), low: true)
            }
            if i == areas.count - 1 {
                wall(from: CGPoint(x: ra.minX, y: ra.maxY), to: CGPoint(x: ra.maxX, y: ra.maxY), out: CGPoint(x: 0, y: 1), low: false)
            }
        }
        // Walls between mines: a band of medium crystals with a gap for the gate
        for (i, g) in gates.enumerated() {
            let a = areas[i].rect, b = areas[i + 1].rect
            let x0 = min(a.minX, b.minX), x1 = max(a.maxX, b.maxX)
            var x = x0
            while x <= x1 {
                defer { x += r(0.3, 0.45) }
                if abs(x - g.x) < g.half + 0.1 { continue }
                let rad = r(0.2, wallBand)
                shard(x, g.y + r(-0.12, 0.12), rad: rad, height: r(0.6, 1.4), out: CGPoint(x: 0, y: r(0, 1) < 0.5 ? 1 : -1), lean: r(0, 0.25))
            }
        }
        scene.rootNode.addChildNode(container.flattenedClone())
    }

    func buildGates() {
        let barMat = Art.pbr(rgb(0.55, 0.55, 0.65), metal: 0.9, rough: 0.3)
        let capMat = Art.pbr(rgb(0.75, 0.2, 0.35), metal: 0.3, rough: 0.4)
        for g in gates {
            g.bars.position = v3(g.x, 0, -g.y)
            var x = -g.half + 0.2
            while x <= g.half - 0.2 {
                let c = SCNCylinder(radius: 0.09, height: 1.7)
                c.materials = [barMat]
                let n = SCNNode(geometry: c)
                n.position = v3(x, 0.85, 0)
                g.bars.addChildNode(n)
                x += 0.45
            }
            Art.box(g.half * 2, 0.18, 0.22, capMat, at: v3(0, 1.7, 0), in: g.bars)
            Art.box(g.half * 2, 0.12, 0.18, capMat, at: v3(0, 0.3, 0), in: g.bars)
            if g.open { g.bars.isHidden = true }
            scene.rootNode.addChildNode(g.bars)
        }
    }

    func buildTags() {
        let pitMat = Art.pbr(rgb(0.08, 0.05, 0.11), rough: 0.9)
        let collarMat = Art.pbr(rgb(0.55, 0.42, 0.25), metal: 0.9, rough: 0.3)
        for t in tags {
            // size the button so the needed coins make a pile a few layers high
            let need = t.price / Double(areas[t.area].value)
            t.radius = min(t.kind == .win ? 3.0 : 2.2, max(0.75, CGFloat((need * 0.045 / (Double.pi * 2.5)).squareRoot())))
            let R = t.radius
            t.node.position = world(t.pos)
            // dark pit, the button itself sitting a little lower than the collar, and the collar
            let pit = SCNCylinder(radius: R + 0.1, height: 0.02); pit.materials = [pitMat]
            let pn = SCNNode(geometry: pit); pn.position = v3(0, 0.005, 0); t.node.addChildNode(pn)
            let disc = SCNCylinder(radius: R * 0.86, height: 0.04); disc.materials = [t.discMat]
            if case .gate = t.kind { t.discMat.diffuse.contents = rgb(0.7, 0.3, 0.95); t.discMat.emission.contents = rgb(0.3, 0.08, 0.45) }
            if t.kind == .win { t.discMat.diffuse.contents = rgb(1, 0.85, 0.3); t.discMat.emission.contents = rgb(0.8, 0.5, 0.05) }
            t.disc.geometry = disc
            t.disc.position = v3(0, 0.01, 0)
            t.node.addChildNode(t.disc)
            let collar = SCNTube(innerRadius: R * 0.88, outerRadius: R + 0.12, height: 0.12); collar.materials = [collarMat]
            let cn = SCNNode(geometry: collar); cn.position = v3(0, 0.06, 0); t.node.addChildNode(cn)
            // progress ring on the floor around the collar
            let ring = SCNPlane(width: (R + 0.5) * 2, height: (R + 0.5) * 2)
            t.ringMat.lightingModel = .constant
            t.ringMat.writesToDepthBuffer = false
            ring.materials = [t.ringMat]
            let rn = SCNNode(geometry: ring); rn.eulerAngles = v3(-.pi / 2, 0, 0); rn.position = v3(0, 0.015, 0)
            t.node.addChildNode(rn)
            // floating sign (turned to face the camera every frame)
            let sp = SCNPlane(width: 1.9, height: 0.86)
            t.signMat.lightingModel = .constant
            t.signMat.isDoubleSided = true
            sp.materials = [t.signMat]
            t.sign.geometry = sp
            t.sign.position = v3(0, 1.5 + R * 0.4, 0)
            if t.kind == .win { t.sign.scale = v3(1.6, 1.6, 1.6); t.sign.position = v3(0, 2.4 + R * 0.4, 0) }
            // molten gold blob, shown while the pile melts
            let bs = SCNSphere(radius: 1); bs.segmentCount = 28; bs.materials = [t.blobMat]
            t.blob.geometry = bs
            t.blob.isHidden = true
            t.node.addChildNode(t.blob)
            scene.rootNode.addChildNode(t.node)
        }
    }

    func buildBelts() {
        let frameMat = Art.pbr(rgb(0.22, 0.22, 0.26), metal: 0.8, rough: 0.4)
        let railMat = Art.pbr(rgb(1, 0.72, 0.1), metal: 0.3, rough: 0.4)
        let goldMat = Art.pbr(rgb(1, 0.75, 0.2), metal: 1, rough: 0.28, emit: rgb(0.35, 0.2, 0.0))
        for (i, a) in areas.enumerated() {
            let b = Belt(area: i, a: a)
            belts.append(b)
            let L = b.length, hw = b.halfWidth, top = b.top
            // the belt runs along its local z axis
            let g = SCNNode()
            let mid = (b.start + b.end) * 0.5
            g.position = world(mid)
            g.eulerAngles = v3(0, atan2(b.dir.x, -b.dir.y), 0)
            b.beltMat.diffuse.contents = Art.beltImage
            b.beltMat.diffuse.wrapS = .repeat
            b.beltMat.diffuse.wrapT = .repeat
            b.beltMat.roughness.contents = 0.8
            b.beltMat.lightingModel = .physicallyBased
            let body = SCNBox(width: hw * 2, height: 0.12, length: L, chamferRadius: 0.02)
            body.materials = [frameMat, frameMat, frameMat, frameMat, b.beltMat, frameMat]
            let bn = SCNNode(geometry: body); bn.position = v3(0, top - 0.06, 0); g.addChildNode(bn)
            for sx in [-1.0, 1.0] as [CGFloat] {
                Art.box(0.09, 0.22, L, railMat, at: v3(sx * (hw + 0.05), top + 0.05, 0), chamfer: 0.02, in: g)
                var z = -L / 2 + 0.4
                while z < L / 2 {
                    let leg = SCNCylinder(radius: 0.06, height: top - 0.1); leg.materials = [frameMat]
                    let ln = SCNNode(geometry: leg); ln.position = v3(sx * hw * 0.8, (top - 0.1) / 2, z); g.addChildNode(ln)
                    z += 1.2
                }
            }
            let roller = SCNCylinder(radius: 0.1, height: hw * 2 + 0.1); roller.materials = [railMat]
            let rn = SCNNode(geometry: roller); rn.eulerAngles = v3(0, 0, .pi / 2); rn.position = v3(0, top - 0.06, L / 2)
            g.addChildNode(rn)
            scene.rootNode.addChildNode(g)

            // hopper full of gold where the belt comes out of the wall
            let h = SCNNode()
            h.position = world(b.start - b.dir * 0.2)
            h.eulerAngles = v3(0, atan2(b.dir.x, -b.dir.y), 0)
            for (x, z, w, l) in [(-0.75, 0.0, 0.1, 1.6), (0.75, 0.0, 0.1, 1.6), (0.0, -0.75, 1.6, 0.1), (0.0, 0.75, 1.6, 0.1)]
                as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
                Art.box(w, 1.0, l, frameMat, at: v3(x, 0.5, z), chamfer: 0.02, in: h)
                Art.box(w + 0.04, 0.08, l + 0.04, railMat, at: v3(x, 1.02, z), chamfer: 0.01, in: h)
            }
            let heapGeo = SCNSphere(radius: 0.7); heapGeo.segmentCount = 18; heapGeo.materials = [goldMat]
            b.heap.geometry = heapGeo
            b.heap.position = v3(0, 0.6, 0)
            h.addChildNode(b.heap)
            scene.rootNode.addChildNode(h)

            // "gold left" sign above the hopper (turned to face the camera every frame)
            let sp = SCNPlane(width: 1.9, height: 0.9)
            b.signMat.lightingModel = .constant
            b.signMat.isDoubleSided = true
            sp.materials = [b.signMat]
            b.sign.geometry = sp
            b.sign.position = world(b.start, 2.3)
            scene.rootNode.addChildNode(b.sign)
        }
    }

    /// Random little piles of coins for the belt (built once, shared).
    lazy var clumps: [(geo: SCNGeometry?, n: Int)] = (0..<10).map { k in
        let n = 2 + k % 7
        let c = SCNNode()
        for i in 0..<n {
            let coin = SCNNode(geometry: Art.coinGeo)
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 0...0.2)
            coin.position = v3(cos(a) * d, 0.02 + CGFloat(i / 3) * 0.045 + CGFloat.random(in: 0...0.02), sin(a) * d)
            coin.eulerAngles = v3(.random(in: -0.4...0.4), .random(in: 0...6), .random(in: -0.4...0.4))
            c.addChildNode(coin)
        }
        return (c.flattenedClone().geometry, n)
    }

    /// Belts carry random piles of coins out of their hoppers; at the end each pile bursts
    /// and the coins fly over the wall into the mine.
    func updateBelts(_ dt: CGFloat) {
        let camRot = camNode.simdWorldOrientation
        for b in belts {
            b.sign.simdWorldOrientation = camRot
            let running = areaUnlocked(b.area) && (b.left > 0 || !b.riders.isEmpty || !b.flyers.isEmpty)
            if running {
                if b.left > 0 {
                    // slows down as it runs dry; piles come at random intervals
                    let r = b.rate * (0.3 + 0.7 * CGFloat(b.left) / CGFloat(b.supply))
                    b.timer += dt * r
                    let clump = clumps[Int.random(in: 0..<clumps.count)]
                    if b.timer >= CGFloat(clump.n) * CGFloat.random(in: 0.7...1.6) {
                        let n = min(clump.n, b.left)
                        b.timer = 0
                        b.left -= n
                        let node = SCNNode(geometry: clump.geo)
                        node.eulerAngles = v3(0, .random(in: 0...6), 0)
                        b.riders.append((node, 0, n))
                        scene.rootNode.addChildNode(node)
                    }
                }
                let speed: CGFloat = 1.6
                b.scroll -= speed * dt / 0.5
                b.beltMat.diffuse.contentsTransform = texMatrix(1, b.length / 0.5, b.scroll)
                var keep: [(node: SCNNode, t: CGFloat, n: Int)] = []
                for var r in b.riders {
                    r.t += speed * dt / b.length
                    if r.t >= 1 {
                        // the pile bursts: each coin flies into the mine
                        r.node.removeFromParentNode()
                        for _ in 0..<r.n {
                            let f = SCNNode(geometry: Art.coinGeo)
                            f.position = world(b.end, b.top + 0.05)
                            scene.rootNode.addChildNode(f)
                            b.flyers.append((f, b.end, b.landingSpot(), CGFloat.random(in: -0.08...0), CGFloat.random(in: 6...14)))
                        }
                    } else {
                        r.node.position = world(lerpP(b.start, b.end, r.t), b.top)
                        keep.append(r)
                    }
                }
                b.riders = keep
                var flying: [(node: SCNNode, from: CGPoint, to: CGPoint, t: CGFloat, spin: CGFloat)] = []
                for var f in b.flyers {
                    f.t += dt / 0.75
                    let t = max(0, f.t)
                    if t >= 1 {
                        f.node.removeFromParentNode()
                        coins.drop(Float(f.to.x), Float(f.to.y), h: 0.05, value: areas[b.area].value)
                    } else {
                        let h = lerp(b.top + 0.05, 0.05, t) + sin(t * .pi) * 2.2   // arc over the crystals
                        f.node.position = world(lerpP(f.from, f.to, t), h)
                        f.node.eulerAngles = v3(t * f.spin, 0, t * f.spin * 0.6)
                        flying.append(f)
                    }
                }
                b.flyers = flying
            }
            b.heap.scale = v3(1, 0.1 + 0.7 * CGFloat(b.left) / CGFloat(b.supply), 1)
            b.heap.isHidden = b.left == 0
            if b.left != b.drawnLeft && (b.left % 5 == 0 || b.left == 0 || b.drawnLeft < 0 || abs(b.left - b.drawnLeft) >= 5) {
                b.drawnLeft = b.left
                b.signMat.diffuse.contents = Art.supplyImage(left: b.left, total: b.supply)
            }
        }
    }

    func texMatrix(_ su: CGFloat, _ sv: CGFloat, _ tv: CGFloat) -> SCNMatrix4 {
        #if os(macOS)
        return SCNMatrix4Mult(SCNMatrix4MakeScale(su, sv, 1), SCNMatrix4MakeTranslation(0, tv, 0))
        #else
        return SCNMatrix4Mult(SCNMatrix4MakeScale(Float(su), Float(sv), 1), SCNMatrix4MakeTranslation(0, Float(tv), 0))
        #endif
    }

    func buildEffects() {
        dust.addParticleSystem(Art.particles(color: rgb(1, 0.85, 0.4), size: 0.09, life: 0.5, speed: 2.5,
                                             spread: 70, gravity: -7, additive: true))
        smoke.addParticleSystem(Art.particles(color: SKColor(white: 0.85, alpha: 0.6), size: 0.3, life: 0.9, speed: 0.8,
                                              spread: 20, gravity: 0.8, additive: false))
        burst.addParticleSystem(Art.particles(color: rgb(1, 0.85, 0.35), size: 0.14, life: 0.8, speed: 4,
                                              spread: 80, gravity: -6, additive: true))
        for n in [dust, smoke, burst] { scene.rootNode.addChildNode(n) }
    }

    func applyTier() {
        guard shownTier != tier else { return }
        shownTier = tier
        if dozerModels.isEmpty { dozerModels = (0..<6).map { DozerModel.build(level: $0) } }
        dozer?.node.removeFromParentNode()
        dozer = dozerModels[tier]
        dozer.node.simdScale = [1, 1, 1]
        scene.rootNode.addChildNode(dozer.node)
        placeDozer()
    }

    /// Start over: first mine, first dozer, every belt full again, no gold on the floor.
    func resetWorld() {
        tier = 0
        won = false
        for g in gates {
            g.open = false
            g.bars.removeAllActions()
            g.bars.position = v3(g.x, 0, -g.y)
            g.bars.isHidden = false
        }
        for t in tags {
            t.amount = 0
            t.meltT = -1
            t.blob.isHidden = true
            t.disc.position = v3(0, 0.01, 0)
            t.drawnKey = ""
        }
        coins.reset()
        for b in belts {
            b.left = b.supply
            b.timer = 0
            for r in b.riders { r.node.removeFromParentNode() }
            for f in b.flyers { f.node.removeFromParentNode() }
            b.riders = []
            b.flyers = []
            b.drawnLeft = -1
        }
        pos = startPos; prevPos = pos; camTarget = pos
        heading = .pi / 2; prevHeading = heading
        velocity = 0; pushLoad = 0; pop = 0
        applyTier()
        camScale = baseZoom
        refreshTags()
        hintShown = true
        hud.hint.removeAllActions()
        hud.hint.alpha = 1
        hud.winPanel.isHidden = true
    }

    // MARK: Input

    // Touches (iPhone: several fingers) and the mouse (Mac: id 0). Drive buttons first, then the joystick.
    var fingers: [Int: Hud.Control] = [:]
    var btnForward = false, btnReverse = false, btnLeft = false, btnRight = false

    func touchBegan(_ id: Int, _ p: CGPoint) {
        if let restart = hud.tapNewGame(p) {
            if restart { resetRequested = true }   // handled on the render thread
            return
        }
        if let c = hud.control(at: p) { fingers[id] = c; updateButtons(); return }
        #if os(macOS)
        joyBegin(p)   // on iPhone, touching the floor does nothing: only the buttons drive
        #endif
    }
    func touchMoved(_ id: Int, _ p: CGPoint) {
        if fingers[id] != nil {
            if let c = hud.control(at: p) { fingers[id] = c; updateButtons() }   // slide between buttons
            return
        }
        joyMove(p)
    }
    func touchEnded(_ id: Int) {
        if fingers.removeValue(forKey: id) != nil { updateButtons(); return }
        joyEnd()
    }
    func updateButtons() {
        let held = Set(fingers.values)
        btnForward = held.contains(.forward); btnReverse = held.contains(.reverse)
        btnLeft = held.contains(.left); btnRight = held.contains(.right)
        hud.showPressed(held)
    }

    func joyBegin(_ p: CGPoint) {
        joyActive = true; joyOrigin = p; joyVec = .zero
        hud.joyBase.position = p; hud.joyKnob.position = p
        hud.joyBase.isHidden = false; hud.joyKnob.isHidden = false
    }
    func joyMove(_ p: CGPoint) {
        guard joyActive else { return }
        var d = p - joyOrigin
        if d.length > 60 { d = d.normalized * 60 }
        hud.joyKnob.position = joyOrigin + d
        joyVec = d * (1.0 / 60)
    }
    func joyEnd() {
        joyActive = false; joyVec = .zero
        hud.joyBase.isHidden = true; hud.joyKnob.isHidden = true
    }

    /// Keyboard (dozer-relative): x = steer (-1 left … 1 right), y = throttle (-1 reverse … 1 forward).
    func inputVector() -> CGPoint {
        var s = CGPoint.zero
        if keys.contains(13) || keys.contains(126) { s.y += 1 }   // W / up: forward
        if keys.contains(1) || keys.contains(125) { s.y -= 1 }    // S / down: reverse
        if keys.contains(0) || keys.contains(123) { s.x -= 1 }    // A / left: turn left
        if keys.contains(2) || keys.contains(124) { s.x += 1 }    // D / right: turn right
        if btnForward { s.y += 1 }                                // on-screen buttons (iPhone)
        if btnReverse { s.y -= 1 }
        if btnLeft { s.x -= 1 }
        if btnRight { s.x += 1 }
        return CGPoint(x: max(-1, min(1, s.x)), y: max(-1, min(1, s.y)))
    }

    // MARK: World rules

    /// Is a circle of radius r at (x, y) outside the open play area?
    func blocked(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Bool {
        guard let ai = areas.firstIndex(where: { y >= $0.rect.minY && y < $0.rect.maxY }) else { return true }
        guard areaUnlocked(ai) else { return true }
        let a = areas[ai].rect
        if x < a.minX + r || x > a.maxX - r { return true }
        if ai == 0 && y < a.minY + r { return true }
        if ai == areas.count - 1 && y > a.maxY - r { return true }
        for gi in [ai - 1, ai] where gi >= 0 && gi < gates.count {
            let g = gates[gi]
            if abs(y - g.y) < r + wallBand {
                if !g.open || abs(x - g.x) > g.half - r { return true }
            }
        }
        return false
    }

    // MARK: Loop

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = CGFloat(lastTime == 0 ? 1.0 / 60 : min(time - lastTime, 1.0 / 20))
        lastTime = time
        clock += dt

        if resetRequested { resetRequested = false; resetWorld() }
        prevPos = pos
        prevHeading = heading
        if clock > 1.5 && warmUp.parent != nil {
            warmUp.removeFromParentNode()
            burst.particleSystems?.first?.particleColor = rgb(1, 0.85, 0.35)
        }
        drive(dt)

        let blade = makeBlade()
        let contacts = coins.step(dt: Float(dt), blade: blade, fillers: [],
                                  blocked: { [unowned self] x, y in self.blocked(CGFloat(x), CGFloat(y), 0.1) },
                                  sold: { _, _, _ in })
        pushLoad = lerp(pushLoad, CGFloat(contacts), 1 - exp(-10 * dt))

        updateButtons(dt)
        tagRedrawTimer += dt
        if tagRedrawTimer > 0.12 {
            tagRedrawTimer = 0
            for t in tags where tagVisible(t) { refreshTag(t) }   // only redraws when the number changed
        }
        updateBelts(dt)
        updateVisuals(dt, pushing: contacts > 0)
        coins.render(material: Art.coinMat)

        let ai = areas.firstIndex(where: { pos.y >= $0.rect.minY && pos.y < $0.rect.maxY }) ?? 0
        hud.loadLabel.text = "MINE \(ai + 1)  ·  DOZER \(tier + 1)"
    }

    /// The dozer's chassis box and plow walls, in game coordinates.
    func makeBlade() -> CoinField.Blade {
        let f = forward
        let fx = Float(f.x), fy = Float(f.y)
        let lx = -fy, ly = fx    // model +x maps to the dozer's left in game coords
        let px = Float(pos.x), py = Float(pos.y)
        var segs: [SIMD4<Float>] = []
        let pts = dozer.plow.map { SIMD2<Float>(px + $0.y * fx + $0.x * lx, py + $0.y * fy + $0.x * ly) }
        for i in 0..<(pts.count - 1) { segs.append([pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y]) }
        // Hold zone: the inside of the plow (its outline closed across the open side)
        let hold = dozer.plow.map { SIMD2<Float>($0.x, $0.y) }
        return CoinField.Blade(x: px, y: py, fx: fx, fy: fy, halfWidth: dozer.bodyHalfWidth,
                               back: dozer.bodyBack, front: dozer.bodyFront, segs: segs, wallHalf: dozer.wallHalf,
                               prevX: Float(prevPos.x), prevY: Float(prevPos.y),
                               prevFx: Float(cos(prevHeading)), prevFy: Float(sin(prevHeading)),
                               hold: hold)
    }

    func drive(_ dt: CGFloat) {
        var newHeading = heading
        var throttle: CGFloat = 0
        let stick = min(1, joyVec.length)
        if joyActive && stick > 0.15 {
            // Touch / mouse: point where you want to go. Screen right = game (1, 1), screen up = game (-1, 1).
            let k: CGFloat = 0.7071
            let want = atan2((joyVec.x + joyVec.y) * k, (joyVec.x - joyVec.y) * k)
            let diff = angleDiff(heading, want)
            // Dragging behind the dozer backs it up (plow stays facing away, so the pile is left alone)
            // instead of turning it around through the pile. Hysteresis stops it flipping back and forth.
            if reversing { if abs(diff) < 2.3 { reversing = false } } else if abs(diff) > 2.7 { reversing = true }   // only a ~25° cone straight behind
            let aim = reversing ? want + .pi : want
            let d = angleDiff(heading, aim)
            let maxTurn = (reversing ? 2.0 : 3.4) * dt
            newHeading = heading + max(-maxTurn, min(maxTurn, d))
            // pivot on the spot for sharp turns, then go; further drag = faster
            let go = stick * max(0, cos(d)) * (abs(d) < 1.6 ? 1 : 0)
            throttle = reversing ? -go : go
        } else {
            reversing = false
            // Keyboard: tank controls (tracks let the dozer turn on the spot; left = counter-clockwise)
            let input = inputVector()
            let steer = abs(input.x) > 0.12 ? input.x : 0
            throttle = abs(input.y) > 0.12 ? input.y : 0
            newHeading = heading - steer * 2.6 * dt
        }
        if hintShown && (newHeading != heading || throttle != 0) {
            hintShown = false
            hud.hint.run(.fadeOut(withDuration: 0.6))
        }
        // Heavier loads slow you down; bigger dozers shrug them off
        let drag = max(0.8, 1 - pushLoad / (spec.power * 4))
        let top = throttle >= 0 ? spec.speed * drag : spec.speed * 0.6
        velocity = lerp(velocity, throttle * top, 1 - exp(-(throttle == 0 ? 8 : 5) * dt))

        // Try the full move, then slide along walls; the whole outline (body + plow) must stay clear.
        let f = CGPoint(x: cos(newHeading), y: sin(newHeading))
        let step = f * (velocity * dt)
        let old = pos
        let stuck = hullBlocked(old, heading)   // e.g. just upgraded to a bigger dozer next to a wall
        // The player's turn comes first; if the plow would hit a wall, back off a little to make room.
        let back = forward * (1.2 * dt)
        let xs = CGPoint(x: step.x, y: 0), ys = CGPoint(x: 0, y: step.y)
        var tries: [(CGPoint, CGFloat)] = [
            (old + step, newHeading), (old + xs, newHeading), (old + ys, newHeading), (old, newHeading),
            (old - back, newHeading), (old - back + xs, newHeading), (old - back + ys, newHeading),
        ]
        if abs(angleDiff(heading, newHeading)) > 1e-5 {
            // The turn is blocked by a wall: reverse away from it properly, then try the turn again next frame
            let reverse = forward * (spec.speed * 0.5 * dt)
            tries += [(old - reverse, heading), (old - CGPoint(x: reverse.x, y: 0), heading), (old - CGPoint(x: 0, y: reverse.y), heading)]
        }
        tries += [(old + step, heading), (old + xs, heading), (old + ys, heading)]
        if let ok = tries.first(where: { stuck || !hullBlocked($0.0, $0.1) }) {
            pos = ok.0
            heading = ok.1
            if ok.0 == old && step.length > 0.001 { velocity *= 0.5 }   // ran into a wall
        } else {
            velocity *= 0.5
        }
    }

    /// Does any part of the dozer (chassis or plow) overlap a wall at this position and heading?
    func hullBlocked(_ p: CGPoint, _ h: CGFloat) -> Bool {
        let fx = cos(h), fy = sin(h)
        let lx = -fy, ly = fx                     // model +x is the dozer's left in game coords
        for q in dozer.hull {
            let x = p.x + CGFloat(q.y) * fx + CGFloat(q.x) * lx
            let y = p.y + CGFloat(q.y) * fy + CGFloat(q.x) * ly
            if blocked(x, y, CGFloat(q.z)) { return true }
        }
        return false
    }

    // MARK: Buttons

    /// Count the coins piled on each button; when a pile is big enough, it melts into the button.
    func updateButtons(_ dt: CGFloat) {
        let active = tags.filter { tagVisible($0) && $0.meltT < 0 }
        for t in active { t.amount = 0 }
        if !active.isEmpty {
            for i in 0..<coins.count {
                let st = coins.state[i]
                guard st == .asleep || st == .awake || st == .growing else { continue }
                for t in active where t.contains(coins.px[i], coins.py[i]) { t.amount += Double(coins.value[i]) }
            }
        }
        for t in active where t.amount >= t.price { startMelt(t) }

        let camRot = camNode.simdWorldOrientation
        for t in tags where tagVisible(t) || t.meltT >= 0 {
            let fill = CGFloat(min(1, t.amount / t.price))
            t.discMat.emission.intensity = 0.4 + fill * 1.2
            if t.meltT >= 0 { animateMelt(t, dt) }
        }
    }

    func startMelt(_ t: Tag) {
        // the coins on the button turn into one molten blob
        var top: Float = 0
        for i in 0..<coins.count where coins.state[i] != .dead && coins.state[i] != .selling && t.contains(coins.px[i], coins.py[i]) {
            top = max(top, coins.ph[i])
            coins.consume(i)
        }
        t.blobHeight = CGFloat(top) + 0.12
        t.meltT = 0
        t.blob.isHidden = false
        burst.position = world(t.pos, 0.3)
        burstTimer = 0.6
    }

    func animateMelt(_ t: Tag, _ dt: CGFloat) {
        t.meltT += dt
        let R = t.radius
        let melt: CGFloat = 1.1, drain: CGFloat = 0.6
        if t.meltT < melt {
            // the pile slumps into a glowing puddle
            let k = t.meltT / melt
            let ease = 1 - (1 - k) * (1 - k)
            let wob = 1 + sin(t.meltT * 18) * 0.03 * (1 - k)
            let rad = lerp(R * 0.75, R * 0.95, ease) * wob
            t.blob.scale = v3(rad, lerp(t.blobHeight, 0.03, ease), rad)
            t.blob.position = v3(0, 0.02, 0)
            t.blobMat.emission.intensity = 0.6 + 2.2 * k
            t.discMat.emission.intensity = 1.6 + k
        } else if t.meltT < melt + drain {
            // it drains into the button, which sinks in
            let k = (t.meltT - melt) / drain
            let rad = R * 0.95 * (1 - k * k)
            t.blob.scale = v3(max(0.01, rad), 0.03, max(0.01, rad))
            t.disc.position = v3(0, 0.01 - 0.05 * sin(k * .pi), 0)
            t.discMat.emission.intensity = 2.6 + 2 * sin(k * .pi)
        } else {
            t.meltT = -1
            t.blob.isHidden = true
            t.disc.position = v3(0, 0.01, 0)
            t.amount = 0
            purchase(t)
        }
    }

    func tagVisible(_ t: Tag) -> Bool {
        guard areaUnlocked(t.area) else { return false }
        switch t.kind {
        case .gate(let i): return !gates[i].open
        case .dozer(let k): return k == tier + 1
        case .win: return !won
        }
    }

    func purchase(_ t: Tag) {
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            self?.haptic.impactOccurred()
            self?.haptic.prepare()
        }
        #endif
        switch t.kind {
        case .gate(let i):
            gates[i].open = true
            gates[i].bars.runAction(.sequence([.move(by: v3(0, -1.9, 0), duration: 0.6), .hide()]))
            floatText("GATE OPEN!", at: CGPoint(x: gates[i].x, y: gates[i].y), h: 2, color: .white, size: 36)
        case .dozer(let k):
            tier = k
            applyTier()
            pop = 1
            floatText("BIGGER DOZER!", at: pos, h: 2.5, color: .white, size: 36)
        case .win:
            won = true
            DispatchQueue.main.async { [weak self] in self?.hud.showWin() }
        }
        burst.position = world(t.pos, 0.3)
        burstTimer = 0.2
        refreshTags()
    }

    // MARK: Visuals

    func placeDozer() {
        guard let dozer = dozer else { return }
        let f = forward
        dozer.node.position = world(pos)
        dozer.node.eulerAngles = v3(0, atan2(f.x, -f.y), 0)
    }

    func updateVisuals(_ dt: CGFloat, pushing: Bool) {
        placeDozer()
        let f = forward
        pop = max(0, pop - dt * 2.5)
        let s = Float(1 + pop * 0.3)
        let moving = abs(velocity) > 0.3
        let body = dozer.node.childNodes.first!
        let bob: Float = moving ? Float(sin(clock * 22)) * 0.012 : 0
        let shake: Float = pushing ? Float.random(in: -0.012...0.012) : 0
        body.simdPosition = [shake, bob, 0]
        dozer.node.simdScale = [s, s, s]

        let front = pos + f * CGFloat(dozer.plow.map { $0.y }.max()! * 0.8)
        dust.position = world(front, 0.25)
        dust.particleSystems?.first?.birthRate = pushing ? 70 : 0
        smoke.simdPosition = dozer.node.simdConvertPosition(dozer.exhaust, to: nil)
        smoke.particleSystems?.first?.birthRate = moving ? 7 : 1.5

        burstTimer -= dt
        burst.particleSystems?.first?.birthRate = burstTimer > 0 ? 400 : 0

        // Camera follows; zooms out as the dozer grows
        camTarget = lerpP(camTarget, pos + f * (velocity * 0.15), 1 - exp(-5 * dt))
        #if os(iOS)
        // aim the camera a bit lower so the dozer sits above the on-screen buttons (screen down = game (1, -1))
        rig.position = world(camTarget + CGPoint(x: 1, y: -1) * (camScale * 0.22))
        #else
        rig.position = world(camTarget)
        #endif
        let wantScale = baseZoom + CGFloat(tier) * 0.8
        camScale = lerp(camScale, wantScale, 1 - exp(-3 * dt))
        camNode.camera?.orthographicScale = Double(camScale)
    }

    func refreshTags() {
        for t in tags {
            let vis = tagVisible(t)
            t.node.isHidden = !vis
            if vis { refreshTag(t) }
        }
    }

    func refreshTag(_ t: Tag) {
        let have = short(min(t.amount, t.price).rounded(.down)), need = short(t.price)
        let progress = CGFloat(min(1, t.amount / t.price))
        let key = "\(have)|\(Int(progress * 60))"
        guard key != t.drawnKey else { return }
        t.drawnKey = key
        let full = progress >= 1
        switch t.kind {
        case .gate:
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 0.8, green: 0.45, blue: 1, alpha: 1))
        case .dozer(let k):
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1))
        case .win:
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 1, green: 0.9, blue: 0.4, alpha: 1))
        }
    }

    func screen(_ p: CGPoint, _ h: CGFloat) -> CGPoint {
        guard let view = view else { return .zero }
        let s = view.projectPoint(world(p, h))
        #if os(iOS)
        return CGPoint(x: CGFloat(s.x), y: hud.size.height - CGFloat(s.y))
        #else
        return CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
        #endif
    }

    func floatText(_ s: String, at p: CGPoint, h: CGFloat, color: SKColor, size: CGFloat) {
        hud.floatText(s, at: screen(p, h), color: color, size: size)
    }
}
