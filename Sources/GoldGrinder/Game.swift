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
    let baseSupply: Int
    var supply: Int
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
        self.area = area; start = a.beltStart; end = a.beltEnd; baseSupply = a.supply; supply = a.supply; rate = a.rate; left = a.supply
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
    let half: CGFloat               // half the opening's width
    var open = false
    let bars = SCNNode()
    init(y: CGFloat, x: CGFloat, half: CGFloat = 2.6) { self.y = y; self.x = x; self.half = half }
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
    let basePrice: Double        // total coin value needed in round 1
    var price: Double            // ... and this round
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
    let labelMat = SCNMaterial()   // the word on the button's plate
    let blob = SCNNode()
    let blobMat = Art.pbr(rgb(1, 0.56, 0.1), metal: 0.7, rough: 0.2, emit: rgb(1.0, 0.4, 0.04))
    init(kind: TagKind, pos: CGPoint, area: Int, price: Double) {
        self.kind = kind; self.pos = pos; self.area = area; self.price = price; basePrice = price
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
             beltStart: CGPoint(x: -14.5, y: 4.5), beltEnd: CGPoint(x: -8.4, y: 4.5), supply: 220, rate: 8),
        Area(rect: CGRect(x: -10, y: 8, width: 20, height: 16), value: 3,
             beltStart: CGPoint(x: -16.5, y: 12), beltEnd: CGPoint(x: -10.4, y: 12), supply: 440, rate: 11),
        Area(rect: CGRect(x: -12, y: 24, width: 24, height: 20), value: 8,
             beltStart: CGPoint(x: -18.5, y: 28), beltEnd: CGPoint(x: -12.4, y: 28), supply: 990, rate: 16),
        Area(rect: CGRect(x: -14, y: 44, width: 28, height: 24), value: 25,
             beltStart: CGPoint(x: -20.5, y: 58), beltEnd: CGPoint(x: -14.4, y: 58), supply: 880, rate: 18),
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
    let smoke = SCNNode()
    let burst = SCNNode()

    // State
    var tier = 0
    var shownDozer = ""
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
    var dozerModels: [DozerModel.Built] = []        // mine dozers: curved claw plows
    var quarryDozers: [DozerModel.Built] = []       // quarry dozers: flat blades
    var prevPos = CGPoint(x: 5, y: -3)
    var prevHeading: CGFloat = .pi / 2

    // Input (written from the UI thread, read in the render loop)
    var joyOrigin = CGPoint.zero
    var joyVec = CGPoint.zero
    var joyActive = false
    var keys = Set<UInt16>()

    let mainQuarry = Quarry()         // the desert stage played before the mines
    let introQuarry = Quarry()        // the intro's gold room (one room with a crusher)
    let intro = Intro()               // first launch only: a taste of the biggest dozer
    var introDozer: DozerModel.Built!
    /// The quarry rules work on whichever block-and-crusher area the dozer is in.
    var quarry: Quarry { stage == .intro ? introQuarry : mainQuarry }
    var round = 1                     // after winning, the game starts over in the quarry with more blocks
    var nextRoundT: CGFloat = -1      // >= 0 while waiting to head back up after a win
    var stage = Stage.quarry
    let ambient = SCNLight()
    var twinkles: [SCNNode] = []      // pool of glints that pop on random coins
    var twinkleTimer: CGFloat = 0
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
            Tag(kind: .dozer(1), pos: CGPoint(x: 2.0, y: -1.0), area: 0, price: 100),      // mine 1: 100 coins each, belt: 220 coins
            Tag(kind: .gate(0), pos: CGPoint(x: 1.0, y: 3.8), area: 0, price: 100),
            Tag(kind: .dozer(2), pos: CGPoint(x: 3.5, y: 14), area: 1, price: 600),       // mine 2: 200 coins each, belt: 440 coins
            Tag(kind: .gate(1), pos: CGPoint(x: -1.0, y: 19.5), area: 1, price: 600),
            Tag(kind: .dozer(3), pos: CGPoint(x: -3.0, y: 37), area: 2, price: 2400),     // mine 3: 300 coins each, belt: 990 coins
            Tag(kind: .dozer(4), pos: CGPoint(x: -3.0, y: 37), area: 2, price: 2400),
            Tag(kind: .gate(2), pos: CGPoint(x: 4.0, y: 32), area: 2, price: 2400),
            Tag(kind: .dozer(5), pos: CGPoint(x: 4.0, y: 62), area: 3, price: 10000),     // mine 4: 400 coins each, belt: 880 coins
            // the big golden pile: 400 coins from the last mine wins the game
            Tag(kind: .win, pos: CGPoint(x: 2.0, y: 52), area: 3, price: 10000),
        ]
        camScale = baseZoom
        buildLighting()
        sizeTags()
        buildFloor()
        buildMineWalls()
        buildGates(gates)
        buildTags()
        buildBelts()
        buildEffects()
        buildQuarry()
        buildIntro()
        pos = quarry.start; prevPos = pos; camTarget = pos   // the game starts up in the quarry
        startIntro()                                         // ... after the intro
        applyTier()
        buildCamera()
        scene.rootNode.addChildNode(coins.root)
        coins.render(material: Art.coinMat)
        refreshTags()
        applyStageLook()
        hud.coinIcon.isHidden = true
        hud.coinLabel.isHidden = true

        view.scene = scene
        view.pointOfView = camNode
        view.delegate = self
        view.overlaySKScene = hud
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = rgb(0.08, 0.06, 0.04)
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.loops = true
        view.prepare((dozerModels + quarryDozers + [introDozer]).map { $0.node }, completionHandler: nil)
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
        // sparks: emit a few under the floor too
        burst.position = world(pos, -6)
        burst.particleSystems?.first?.particleColor = SKColor(white: 1, alpha: 0)   // invisible while warming up
        burstTimer = 0.3
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
        cam.vignettingIntensity = 0.35
        cam.vignettingPower = 1.0
        cam.saturation = 1.05       // rich but natural colours, like the reference art
        cam.contrast = 0.18
        camNode.camera = cam
        scene.rootNode.addChildNode(rig)
        rig.addChildNode(camNode)
        camNode.position = v3(20, 24, 20)
        camNode.look(at: v3(0, 0, 0))
        rig.position = world(pos)
    }

    func buildLighting() {
        scene.background.contents = rgb(0.08, 0.06, 0.04)
        scene.lightingEnvironment.contents = Art.environmentImage()
        scene.lightingEnvironment.intensity = 0.8

        // a warm, late-afternoon sun from the upper left of the screen (the dirt texture bakes in the same light)
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 2800
        sun.color = rgb(1, 0.92, 0.8)
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowColor = SKColor(red: 0.1, green: 0.06, blue: 0.03, alpha: 0.75)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 2.5
        sun.automaticallyAdjustsShadowProjection = true
        sun.maximumShadowDistance = 50
        let sunNode = SCNNode()
        sunNode.light = sun
        sunNode.position = v3(-12.5, 12.2, 7.5)    // shining toward the screen's lower right
        sunNode.look(at: v3(0, 0, 0))
        scene.rootNode.addChildNode(sunNode)

        ambient.type = .ambient
        ambient.intensity = 300
        ambient.color = rgb(0.85, 0.88, 1)         // cool sky fill in the shadows
        let ambNode = SCNNode()
        ambNode.light = ambient
        scene.rootNode.addChildNode(ambNode)
    }

    /// The dirt texture is costly to make, so all floors share one.
    static let dirt = Art.dirtImage(seed: 3)
    static let dirtTile: CGFloat = 6          // one dirt tile covers 6 x 6 units

    /// Dirt for a floor piece covering `r` (game coords), lined up with the world so neighbouring pieces match.
    /// `tint` colours the big soft patches laid over it (different per stage).
    func dirtMat(_ r: CGRect, tint: (CGFloat, CGFloat, CGFloat), seed: UInt64) -> SCNMaterial {
        let m = Art.pbr(Game.dirt, rough: 0.95)
        m.multiply.contents = Art.dirtVariation(seed: seed, tint: tint)
        for (p, tile) in [(m.diffuse, Game.dirtTile), (m.multiply, Game.dirtTile * 4.7)] {
            p.wrapS = .repeat; p.wrapT = .repeat
            p.mipFilter = .linear
            #if os(macOS)
            p.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(r.width / tile, r.height / tile, 1),
                                                 SCNMatrix4MakeTranslation(r.minX / tile, r.minY / tile, 0))
            #else
            p.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(Float(r.width / tile), Float(r.height / tile), 1),
                                                 SCNMatrix4MakeTranslation(Float(r.minX / tile), Float(r.minY / tile), 0))
            #endif
        }
        return m
    }

    /// One well per button spot (buttons sharing a spot share a well): (centre, radius).
    var wells: [(p: CGPoint, r: CGFloat)] {
        var out: [(p: CGPoint, r: CGFloat)] = []
        for t in tags where !out.contains(where: { $0.p == t.pos }) { out.append((t.pos, t.radius)) }
        return out
    }
    let wellDepth: CGFloat = 0.32

    /// A well under a hole in the floor: dark stone walls going down to a floor, with a metal lip flush with the ground.
    func buildWell(_ p: CGPoint, _ r: CGFloat) {
        let wallMat = Art.pbr(rgb(0.12, 0.1, 0.08), rough: 0.9)
        let bottomMat = Art.pbr(rgb(0.09, 0.07, 0.06), rough: 0.9)
        let lipMat = Art.pbr(rgb(0.55, 0.42, 0.25), metal: 0.9, rough: 0.3)
        let D = wellDepth
        let n = SCNNode()
        n.position = world(p)
        let wall = SCNTube(innerRadius: r, outerRadius: r + 0.1, height: D + 0.04)
        wall.radialSegmentCount = 64
        wall.materials = [wallMat]
        let wn = SCNNode(geometry: wall); wn.position = v3(0, -(D + 0.04) / 2 - 0.005, 0); n.addChildNode(wn)
        let bottom = SCNCylinder(radius: r + 0.05, height: 0.02); bottom.radialSegmentCount = 64
        bottom.materials = [bottomMat]
        let bn = SCNNode(geometry: bottom); bn.position = v3(0, -D - 0.03, 0); n.addChildNode(bn)
        let lip = SCNTube(innerRadius: r, outerRadius: r + 0.13, height: 0.02); lip.radialSegmentCount = 64
        lip.materials = [lipMat]
        let ln = SCNNode(geometry: lip); ln.position = v3(0, 0.005, 0); n.addChildNode(ln)
        scene.rootNode.addChildNode(n)
    }

    /// A flat floor piece in game coordinates with round holes cut out for the wells.
    func floorShape(_ r: CGRect, holes: [(p: CGPoint, r: CGFloat)], mat: SCNMaterial) -> SCNNode {
        #if os(macOS)
        let path = NSBezierPath(rect: r)
        for h in holes { path.appendOval(in: CGRect(x: h.p.x - h.r, y: h.p.y - h.r, width: 2 * h.r, height: 2 * h.r)) }
        path.windingRule = .evenOdd
        #else
        let path = UIBezierPath(rect: r)
        for h in holes { path.append(UIBezierPath(ovalIn: CGRect(x: h.p.x - h.r, y: h.p.y - h.r, width: 2 * h.r, height: 2 * h.r))) }
        path.usesEvenOddFillRule = true
        #endif
        path.flatness = 0.01
        let shape = SCNShape(path: path, extrusionDepth: 0)
        shape.materials = [mat]
        let n = SCNNode(geometry: shape)
        n.eulerAngles = v3(-.pi / 2, 0, 0)   // shape (x, y) lands on world (x, 0, -y), same as game coords
        return n
    }

    func buildFloor() {
        let holes = wells
        // mines: darker, redder dirt, a little darker still outside the walls
        let outside = CGRect(x: -60, y: -40, width: 120, height: 140)
        let on = floorShape(outside, holes: holes, mat: dirtMat(outside, tint: (0.72, 0.62, 0.55), seed: 1))
        on.position = v3(0, -0.03, 0)
        scene.rootNode.addChildNode(on)
        for a in areas {
            let inside = holes.filter { a.rect.contains($0.p) }
            scene.rootNode.addChildNode(floorShape(a.rect, holes: inside, mat: dirtMat(a.rect, tint: (0.85, 0.74, 0.66), seed: 2)))
        }
        for h in holes { buildWell(h.p, h.r) }
        let D = wellDepth
        coins.wells = holes.map { SIMD3<Float>(Float($0.p.x), Float($0.p.y), Float($0.r)) }
        coins.wellDepth = Float(D)
    }

    /// Sharp crystal walls. Their bases sit on the real collision edges, so what you see is what you hit.
    /// The dark green crystal walls of the mines.
    func buildMineWalls() {
        let mats: [SCNMaterial] = [
            Art.pbr(rgb(0.05, 0.42, 0.22), metal: 0.15, rough: 0.22, emit: rgb(0.0, 0.08, 0.03)),
            Art.pbr(rgb(0.12, 0.58, 0.32), metal: 0.1, rough: 0.18, emit: rgb(0.01, 0.12, 0.05)),
            Art.pbr(rgb(0.03, 0.28, 0.14), metal: 0.2, rough: 0.3, emit: rgb(0.0, 0.05, 0.02)),
            Art.pbr(rgb(0.28, 0.72, 0.46), metal: 0.05, rough: 0.15, emit: rgb(0.03, 0.16, 0.08)),
        ]
        buildWalls(rects: areas.map { $0.rect }, gates: gates, openings: areas.map { $0.beltStart.y }, openingHalf: 1.0,
                   mats: mats, rockMat: Art.pbr(rgb(0.08, 0.2, 0.12), rough: 0.9), seed: 42)
    }

    /// Jagged walls around a row of rooms: tall at the back (left), low spikes at the front (right),
    /// a band between rooms with a gap for each gate, and an opening in each room's left wall at `openings`.
    func buildWalls(rects: [CGRect], gates: [Gate], openings: [CGFloat], openingHalf: CGFloat,
                    mats: [SCNMaterial], rockMat: SCNMaterial, seed: UInt64, grain: Float = 0.4) {
        var rng = SeededRNG(s: seed)
        // streaky, gritty stone laid over each shard's colour
        let grainImage = Art.shardGrain(seed: seed, strength: grain)
        for m in mats { m.multiply.contents = grainImage; m.multiply.wrapS = .repeat; m.multiply.mipFilter = .linear }
        func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }
        var protos: [SCNGeometry] = []
        for k in 0..<12 {
            let g = Art.crystal(sides: k % 3 == 0 ? 5 : 6, body: Float(r(1.2, 2.6)), tip: Float(r(0.7, 1.4)), twist: Float(r(-0.25, 0.25)))
            g.materials = [mats[k % mats.count]]
            protos.append(g)
        }
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

        for (i, ra) in rects.enumerated() {
            // left side faces away from the camera (tall), right side faces it (low)
            let beltY = openings[i]
            wall(from: CGPoint(x: ra.minX, y: ra.minY), to: CGPoint(x: ra.minX, y: ra.maxY), out: CGPoint(x: -1, y: 0), low: false,
                 skip: { abs($0.y - beltY) < openingHalf })   // opening for the conveyor belt
            wall(from: CGPoint(x: ra.maxX, y: ra.minY), to: CGPoint(x: ra.maxX, y: ra.maxY), out: CGPoint(x: 1, y: 0), low: true)
            if i == 0 {
                wall(from: CGPoint(x: ra.minX, y: ra.minY), to: CGPoint(x: ra.maxX, y: ra.minY), out: CGPoint(x: 0, y: -1), low: true)
            }
            if i == rects.count - 1 {
                wall(from: CGPoint(x: ra.minX, y: ra.maxY), to: CGPoint(x: ra.maxX, y: ra.maxY), out: CGPoint(x: 0, y: 1), low: false)
            }
        }
        // Walls between mines: a band of medium crystals with a gap for the gate
        for (i, g) in gates.enumerated() {
            let a = rects[i], b = rects[i + 1]
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

    func buildGates(_ list: [Gate], cap: SKColor = rgb(0.1, 0.4, 0.2)) {
        let barMat = Art.pbr(rgb(0.55, 0.55, 0.65), metal: 0.9, rough: 0.3)
        let capMat = Art.pbr(cap, metal: 0.3, rough: 0.4)
        for g in list {
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

    /// Size each button so its coins make a low pile, about 1.5 layers deep with some room to spare.
    /// Buttons sharing a spot share the biggest size, since they share a well.
    func sizeTags() {
        for t in tags {
            let need = t.price / Double(areas[t.area].value)
            let d = 2 * Double(Art.coinRadius) * 0.8           // coin spacing in a packed layer
            let fit = CGFloat((need * d * d / (Double.pi * 1.5)).squareRoot()) * 1.15
            t.radius = min(4, max(0.75, fit))
        }
        for t in tags { t.radius = tags.filter { $0.pos == t.pos }.map { $0.radius }.max()! }
    }

    /// Height of the glowing button plate (the well's floor).
    var discY: CGFloat { -wellDepth - 0.01 }

    func buildTags() {
        for t in tags {
            let R = t.radius
            t.node.position = world(t.pos)
            // the glowing plate at the bottom of the well
            let disc = SCNCylinder(radius: R, height: 0.02); disc.radialSegmentCount = 64
            // dark glowing pad: orange for dozers, blue for gates, gold for the win
            var glow: (CGFloat, CGFloat, CGFloat) = (1, 0.55, 0.12)
            if case .gate = t.kind { glow = (0.2, 0.75, 1) }
            if t.kind == .win { glow = (1, 0.85, 0.3) }
            let pad = Art.padImage(glow)
            t.discMat.diffuse.contents = pad
            t.discMat.emission.contents = pad
            t.discMat.emission.intensity = 0.9
            t.discMat.metalness.contents = 0.4
            disc.materials = [Art.pbr(rgb(0.1, 0.1, 0.11), metal: 0.6, rough: 0.4), t.discMat, t.discMat]
            t.disc.geometry = disc
            t.disc.position = v3(0, discY, 0)
            t.node.addChildNode(t.disc)
            // the button's name on its plate, turned to read across the screen (screen right = game (1, 1))
            let labelMat = t.labelMat
            labelMat.lightingModel = .constant
            labelMat.diffuse.contents = Art.buttonLabel(buttonWord(t))
            labelMat.writesToDepthBuffer = false
            // taller than the image, so the letters look right when seen at the camera's slant
            let lp = SCNPlane(width: R * 1.5, height: R * 1.5 * 160 / 512 * 1.7)
            lp.materials = [labelMat]
            let ln = SCNNode(geometry: lp)
            ln.eulerAngles = v3(-.pi / 2, 0, 0)
            ln.renderingOrder = 5
            let turn = SCNNode()
            turn.eulerAngles = v3(0, .pi / 4, 0)
            turn.position = v3(0, discY + 0.015, 0)
            turn.addChildNode(ln)
            t.node.addChildNode(turn)
            // slowly flash
            let down = SCNAction.fadeOpacity(to: 0.25, duration: 0.9); down.timingMode = .easeInEaseOut
            let up = SCNAction.fadeOpacity(to: 1, duration: 0.9); up.timingMode = .easeInEaseOut
            ln.runAction(.repeatForever(.sequence([down, up])))
            // progress ring on the floor around the well's lip
            let ring = SCNPlane(width: (R + 0.75) * 2, height: (R + 0.75) * 2)
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

    static let beltFrameMat = Art.pbr(rgb(0.22, 0.22, 0.26), metal: 0.8, rough: 0.4)
    static let beltRailMat = Art.pbr(rgb(0.88, 0.66, 0.12), metal: 0.3, rough: 0.55)

    /// A conveyor belt on legs from `a` to `b` (the belt surface at height 0.55). `mat` is the moving belt.
    func conveyor(from a: CGPoint, to b: CGPoint, mat: SCNMaterial) -> SCNNode {
        let frameMat = Game.beltFrameMat, railMat = Game.beltRailMat
        let dir = (b - a).normalized, L = a.dist(b), hw: CGFloat = 0.55, top: CGFloat = 0.55
        // the belt runs along its local z axis
        let g = SCNNode()
        g.position = world((a + b) * 0.5)
        g.eulerAngles = v3(0, atan2(dir.x, -dir.y), 0)
        mat.diffuse.contents = Art.beltImage
        mat.diffuse.wrapS = .repeat
        mat.diffuse.wrapT = .repeat
        mat.roughness.contents = 0.8
        mat.lightingModel = .physicallyBased
        let body = SCNBox(width: hw * 2, height: 0.12, length: L, chamferRadius: 0.02)
        body.materials = [frameMat, frameMat, frameMat, frameMat, mat, frameMat]
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
        return g
    }

    func buildBelts() {
        let frameMat = Game.beltFrameMat
        let railMat = Game.beltRailMat
        let goldMat = Art.pbr(rgb(1, 0.7, 0.12), metal: 0.8, rough: 0.28, emit: rgb(0.4, 0.22, 0.0))
        for (i, a) in areas.enumerated() {
            let b = Belt(area: i, a: a)
            belts.append(b)
            scene.rootNode.addChildNode(conveyor(from: b.start, to: b.end, mat: b.beltMat))

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
            coin.position = v3(cos(a) * d, 0.02 + CGFloat(i / 3) * Art.coinThick + CGFloat.random(in: 0...0.02), sin(a) * d)
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
        smoke.addParticleSystem(Art.particles(color: SKColor(white: 0.85, alpha: 0.6), size: 0.3, life: 0.9, speed: 0.8,
                                              spread: 20, gravity: 0.8, additive: false))
        burst.addParticleSystem(Art.particles(color: rgb(1, 0.76, 0.28), size: 0.14, life: 0.8, speed: 4,
                                              spread: 80, gravity: -6, additive: true))
        for n in [smoke, burst] { scene.rootNode.addChildNode(n) }
    }

    func applyTier() {
        let key = "\(stage)\(tier)"
        guard shownDozer != key else { return }
        shownDozer = key
        if dozerModels.isEmpty { dozerModels = (0..<6).map { DozerModel.build(level: $0) } }
        if quarryDozers.isEmpty { quarryDozers = (0..<4).map { DozerModel.build(level: $0, flat: true) } }
        if introDozer == nil { introDozer = DozerModel.build(level: 5, flat: true) }   // the biggest, with a flat blade
        dozer?.node.removeFromParentNode()
        switch stage {
        case .intro: dozer = introDozer
        case .quarry: dozer = quarryDozers[min(tier, quarryDozers.count - 1)]
        case .mines: dozer = dozerModels[tier]
        }
        dozer.node.simdScale = [1, 1, 1]
        scene.rootNode.addChildNode(dozer.node)
        placeDozer()
    }

    /// Start over (round 1), or the next round after a win: back up to the quarry, first dozer,
    /// fresh blocks and full belts, no gold on the floor.
    func resetWorld(round newRound: Int = 1) {
        stage = .quarry
        round = newRound
        nextRoundT = -1
        // harder each round: the mine buttons need 25% more coins per round (up to +50%, so the piles still fit
        // the buttons), and the belts carry that much more
        let m = min(1.5, 1 + 0.25 * Double(round - 1))
        for t in tags {
            t.price = (t.basePrice * m).rounded()
            if t.kind == .win { t.labelMat.diffuse.contents = Art.buttonLabel(buttonWord(t)) }
        }
        for b in belts { b.supply = Int((Double(b.baseSupply) * m).rounded()) }
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
            t.disc.position = v3(0, discY, 0)
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
        resetQuarry(round: round)
        pos = quarry.start; prevPos = pos; camTarget = pos
        heading = .pi / 2; prevHeading = heading
        velocity = 0; pushLoad = 0; pop = 0
        applyTier()
        camScale = baseZoom
        refreshTags()
        hintShown = true
        hud.hint.removeAllActions()
        hud.hint.alpha = 1
        hud.winPanel.isHidden = true
        if round > 1 {
            let r = round
            DispatchQueue.main.async { [weak self] in self?.hud.roundBanner(r) }
        } else {
            startIntro()   // a new game starts with the intro
        }
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
        if stage == .quarry { return quarryBlocked(x, y, r) }
        if stage == .intro { return introBlocked(x, y, r) }
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
            burst.particleSystems?.first?.particleColor = rgb(1, 0.76, 0.28)
        }
        drive(dt)

        if stage == .intro { updateIntro(dt); return }
        if stage == .quarry {
            let load = updateQuarry(dt)
            pushLoad = lerp(pushLoad, load, 1 - exp(-10 * dt))
            updateVisuals(dt, pushing: load > 0)
            updateTwinkles(dt)
            updateLeaving(dt)
            let ri = quarry.room(at: pos) ?? 0
            hud.loadLabel.text = (round > 1 ? "R\(round) · " : "") + "QUARRY \(ri + 1)  ·  DOZER \(tier + 1)"
            let c = quarry.crushers[ri]
            var title = "CRUSHER"
            if !c.upgraded, let at = Quarry.plan(ri, round: round).upgradeAt, tier < Quarry.maxTier(round: round) { title = "BIGGER DOZER AT \(at)" }
            hud.showCounters((title, min(c.crushed, c.need), c.need), haveCaption: "GOLD IN")
            return
        }

        let blade = makeBlade()
        coins.heapTop = dozer.plowTop      // coins heap up as high as the blade, then tumble off
        let contacts = coins.step(dt: Float(dt), blade: blade, fillers: [],
                                  blocked: { [unowned self] x, y in self.blocked(CGFloat(x), CGFloat(y), 0.1) },
                                  sold: { _, _, _ in })
        pushLoad = lerp(pushLoad, CGFloat(contacts), 1 - exp(-10 * dt))

        updateButtons(dt)
        tagRedrawTimer += dt
        if tagRedrawTimer > 0.12 {
            tagRedrawTimer = 0
            for t in tags where tagVisible(t) { refreshTag(t) }   // only redraws when the ring changed
        }
        updateBelts(dt)
        updateVisuals(dt, pushing: contacts > 0)
        coins.render(material: Art.coinMat)
        updateTwinkles(dt)

        let ai = areas.firstIndex(where: { pos.y >= $0.rect.minY && pos.y < $0.rect.maxY }) ?? 0
        hud.loadLabel.text = (round > 1 ? "R\(round) · " : "") + "MINE \(ai + 1)  ·  DOZER \(tier + 1)"
        updateCounters()
        // after a win: a few seconds to enjoy it, then back up to the quarry for the next round
        if nextRoundT >= 0 {
            let before = nextRoundT
            nextRoundT += dt
            if before < 4 && nextRoundT >= 4 { DispatchQueue.main.async { [weak self] in self?.hud.fadeThrough() } }
            if before < 4.6 && nextRoundT >= 4.6 { resetWorld(round: round + 1) }
        }
    }

    /// What a button is called. In round 1 the last button leads on to round 2 rather than winning.
    func buttonWord(_ t: Tag) -> String {
        switch t.kind {
        case .dozer: return "UPGRADE"
        case .gate: return "GATE"
        case .win: return round == 1 ? "NEXT ROUND" : "VICTORY"
        }
    }

    /// The two counters at the top: coins on the nearest button and coins it needs.
    func updateCounters() {
        let near = tags.filter { tagVisible($0) }.min { $0.pos.dist(pos) < $1.pos.dist(pos) }
        guard let t = near else { hud.showCounters(nil); return }
        let value = Double(areas[t.area].value)
        let need = Int((t.price / value).rounded(.up))
        let have = t.meltT >= 0 ? need : min(need, Int((t.amount / value).rounded(.down)))
        let name: String
        switch t.kind {
        case .dozer: name = "NEXT DOZER"
        case .gate: name = "GATE"
        case .win: name = buttonWord(t)
        }
        hud.showCounters((name, have, need))
    }

    /// Every so often a coin on screen catches the light: a little star glint pops on it and fades.
    func updateTwinkles(_ dt: CGFloat) {
        if twinkles.isEmpty {
            let plane = SCNPlane(width: 0.9, height: 0.9)
            plane.materials = [Art.twinkleMat]
            for _ in 0..<6 {
                let n = SCNNode()
                n.constraints = [SCNBillboardConstraint()]
                n.isHidden = true
                let star = SCNNode(geometry: plane)
                star.renderingOrder = 10
                n.addChildNode(star)
                scene.rootNode.addChildNode(n)
                twinkles.append(n)
            }
        }
        twinkleTimer -= dt
        if stage == .quarry {
            guard twinkleTimer <= 0 else { return }
            twinkleTimer = .random(in: 0.3...0.8)
            let live = quarry.blocks.filter { !$0.gone && $0.crushT < 0 && ($0.p - camTarget).length < camScale * 0.8 }
            guard let b = live.randomElement(), let n = twinkles.first(where: { $0.isHidden }) else { return }
            let off = CGPoint(x: .random(in: -0.4...0.4), y: .random(in: -0.4...0.4)) * b.r
            popTwinkle(n, at: world(b.p + off, b.r * 0.85 + 0.05))
            return
        }
        let coins = stage == .intro ? intro.coins : self.coins
        guard twinkleTimer <= 0, coins.count > 0 else { return }
        twinkleTimer = .random(in: 0.15...0.5)
        guard let n = twinkles.first(where: { $0.isHidden }) else { return }
        // a random resting coin near the middle of the screen
        for _ in 0..<12 {
            let i = Int.random(in: 0..<coins.count)
            guard coins.state[i] == .asleep || coins.state[i] == .awake else { continue }
            let p = CGPoint(x: CGFloat(coins.px[i]), y: CGFloat(coins.py[i]))
            guard (p - camTarget).length < camScale * 0.8 else { continue }
            // on the coin's face, nudged toward the light side
            let off = CGPoint(x: .random(in: -0.07...0.07), y: .random(in: -0.07...0.07))
            popTwinkle(n, at: world(p + off, CGFloat(coins.ph[i] + coins.thick) + 0.03))
            break
        }
    }

    /// Show one glint: it grows, spins a little and fades.
    func popTwinkle(_ n: SCNNode, at p: SCNVector3) {
        n.position = p
        let star = n.childNodes[0]
        let s = CGFloat.random(in: 0.8...1.2)
        star.scale = v3(0.01, 0.01, 0.01)
        star.eulerAngles = v3(0, 0, .random(in: 0...0.8))
        n.isHidden = false
        let grow = SCNAction.scale(to: s, duration: 0.14); grow.timingMode = .easeOut
        let shrink = SCNAction.scale(to: 0.01, duration: 0.4); shrink.timingMode = .easeIn
        star.runAction(.group([.sequence([grow, shrink]), .rotateBy(x: 0, y: 0, z: 0.9, duration: 0.54)])) {
            n.isHidden = true
        }
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
                               hold: hold, lip: dozer.lip)
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
        // Already overlapping something (e.g. just upgraded to a bigger dozer next to a wall)? Then a move is fine
        // as long as no part of the dozer that was clear runs into a wall: it can work itself free,
        // but never push on through a wall or a closed gate.
        let stuckAt = hullHits(old, heading)
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
        if let ok = tries.first(where: { hullHits($0.0, $0.1).isSubset(of: stuckAt) }) {
            pos = ok.0
            heading = ok.1
            if ok.0 == old && step.length > 0.001 { velocity *= 0.5 }   // ran into a wall
        } else {
            velocity *= 0.5
        }
    }

    /// Does any part of the dozer (chassis or plow) overlap a wall at this position and heading?
    /// Which of the dozer's outline points overlap a wall (or a block too heavy to move) at this position and heading.
    func hullHits(_ p: CGPoint, _ h: CGFloat) -> Set<Int> {
        let fx = cos(h), fy = sin(h)
        let lx = -fy, ly = fx
        var hits = Set<Int>()
        for (k, q) in dozer.hull.enumerated() {
            let x = p.x + CGFloat(q.y) * fx + CGFloat(q.x) * lx
            let y = p.y + CGFloat(q.y) * fy + CGFloat(q.x) * ly
            if blocked(x, y, CGFloat(q.z)) || (stage != .mines && hitsPinnedBlock(x, y, CGFloat(q.z))) { hits.insert(k) }
        }
        return hits
    }

    func hullBlocked(_ p: CGPoint, _ h: CGFloat) -> Bool {
        let fx = cos(h), fy = sin(h)
        let lx = -fy, ly = fx                     // model +x is the dozer's left in game coords
        for q in dozer.hull {
            let x = p.x + CGFloat(q.y) * fx + CGFloat(q.x) * lx
            let y = p.y + CGFloat(q.y) * fy + CGFloat(q.x) * ly
            if blocked(x, y, CGFloat(q.z)) { return true }
            if stage != .mines && hitsPinnedBlock(x, y, CGFloat(q.z)) { return true }
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
        t.blobHeight = CGFloat(top) - discY + 0.12
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
            t.blob.position = v3(0, discY + 0.02, 0)
            t.blobMat.emission.intensity = 0.6 + 2.2 * k
            t.discMat.emission.intensity = 1.6 + k
        } else if t.meltT < melt + drain {
            // it drains into the button, which sinks in
            let k = (t.meltT - melt) / drain
            let rad = R * 0.95 * (1 - k * k)
            t.blob.scale = v3(max(0.01, rad), 0.03, max(0.01, rad))
            t.disc.position = v3(0, discY - 0.05 * sin(k * .pi), 0)
            t.discMat.emission.intensity = 2.6 + 2 * sin(k * .pi)
        } else {
            t.meltT = -1
            t.blob.isHidden = true
            t.disc.position = v3(0, discY, 0)
            t.amount = 0
            purchase(t)
        }
    }

    func tagVisible(_ t: Tag) -> Bool {
        guard areaUnlocked(t.area) else { return false }
        switch t.kind {
        case .gate(let i): return !gates[i].open
        case .dozer(let k): return k == tier + 1 && (round > 1 || k <= 3)   // dozers 5 and 6 wait for round 2
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
            if round == 1 {
                // not the end yet: straight on to round 2 (no win screen)
                nextRoundT = 1.5
                floatText("NEXT ROUND!", at: pos, h: 2.5, color: rgb(1, 0.85, 0.35), size: 40)
            } else {
                nextRoundT = 0
                DispatchQueue.main.async { [weak self] in self?.hud.showWin() }
            }
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
        // the ring is redrawn only when its arc moves a visible step (drawing it costs a few ms on a phone)
        let progress = CGFloat(Int(min(1, t.amount / t.price) * 40)) / 40
        let key = "\(progress)"
        guard key != t.drawnKey else { return }
        t.drawnKey = key
        switch t.kind {
        case .gate:
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 0.3, green: 0.6, blue: 1, alpha: 1), inner: ringInner(t))
        case .dozer:
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1), inner: ringInner(t))
        case .win:
            t.ringMat.diffuse.contents = Art.ringImage(progress: progress, color: CGColor(red: 1, green: 0.9, blue: 0.4, alpha: 1), inner: ringInner(t))
        }
    }

    /// Where the progress ring starts (just outside the well's lip), as a fraction of the ring image.
    func ringInner(_ t: Tag) -> CGFloat { (t.radius + 0.2) / (t.radius + 0.75) }

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
