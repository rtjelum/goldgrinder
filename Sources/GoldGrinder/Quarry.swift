import SceneKit
import SpriteKit
import simd

/// Which part of the game the dozer is in: the desert quarry up top (played first), or the mines below.
enum Stage { case intro, quarry, mines }

/// A rough-cut gold block in the quarry. It comes in four sizes (`cls` 0...3): bigger ones are worth more gold
/// and need a bigger dozer to move (class k needs dozer k + 1). The dozer pushes its outline; walls and other
/// blocks use a slightly larger `bound` circle.
final class GoldBlock {
    let room: Int
    let cls: Int
    let r: CGFloat               // size: the nugget is about 1.7 r across
    var half: CGFloat { r * 0.82 }
    var bound: CGFloat { r * 0.9 }
    var value: Int { cls + 1 }
    let home: CGPoint, homeAngle: CGFloat
    var p: CGPoint
    var angle: CGFloat
    var crushT: CGFloat = -1   // >= 0 while it is being crushed
    var crushFrom = CGPoint.zero
    var riding = false         // on the feeder belt, being carried into the crusher
    var gone = false
    var pinned = false         // a wall stopped it: the dozer can't push through it
    let node = SCNNode()
    init(room: Int, cls: Int, at p: CGPoint, angle: CGFloat) {
        self.room = room; self.cls = cls; r = Quarry.sizes[cls]; home = p; homeAngle = angle; self.p = p; self.angle = angle
    }
}

/// A crusher set into a room's left wall. A feeder belt, flush with the floor, runs from its mouth into the room:
/// push a block onto the belt and it is carried in and ground into coins, which ride a conveyor out the back
/// and down a shaft to the mines.
final class Crusher {
    let room: Int
    let x0: CGFloat, y: CGFloat   // the room's left wall (the crusher's mouth), and its centre line
    let mouth: CGFloat            // half-width of the mouth and the feeder belt
    let feedLen: CGFloat = 3.2    // how far the feeder belt reaches into the room
    let feedMat = SCNMaterial()
    var feedScroll: CGFloat = 0
    var need: Int
    var crushed = 0              // gold crushed in this room (a block is worth its size class + 1)
    var upgraded = false         // this room's dozer upgrade has been given
    let node = SCNNode()
    var rollers: [SCNNode] = []
    let beltMat = SCNMaterial()
    let beltStart: CGPoint, beltEnd: CGPoint
    var scroll: CGFloat = 0
    var riders: [(node: SCNNode, t: CGFloat)] = []
    var pending = 0              // coin piles still to drop onto the belt
    var dropTimer: CGFloat = 0
    var busy: CGFloat = 0        // > 0 while something is being crushed (rollers spin fast, machine shakes)
    var rollAngle: CGFloat = 0
    var done = false             // this room's crushing is complete
    init(room: Int, x0: CGFloat, y: CGFloat, mouth: CGFloat, need: Int) {
        self.room = room; self.x0 = x0; self.y = y; self.mouth = mouth; self.need = need
        beltStart = CGPoint(x: x0 - Quarry.housing - 0.4, y: y)
        beltEnd = CGPoint(x: x0 - Quarry.housing - 6.5, y: y)
    }
}

/// The desert quarry: four rooms laid out like the mines (same rooms, walls and gates), with gold blocks
/// to push into crushers. Crushing a room's blocks opens its gate and upgrades the dozer;
/// finishing the last room takes you down to mine 1.
final class Quarry {
    static let dx: CGFloat = 130                 // it sits far to the side of the mines in the same scene
    static let housing: CGFloat = 1.1            // depth of the crusher body, set back into the wall
    static let sizes: [CGFloat] = [0.42, 0.56, 0.7, 0.84]   // block size per class; class k needs dozer k + 1
    /// Each room: its blocks (size classes), the gold that earns the next dozer, and the gold that opens the gate.
    /// Start with the small ones, get a bigger dozer, then the big ones finish the room (with some to spare).
    /// Round 1 tops out at dozer 3 (no huge blocks); from round 2 the biggest dozer and the huge blocks join in.
    static let firstRound: [(blocks: [Int], upgradeAt: Int?, need: Int)] = [
        ([0, 0, 0, 0, 1, 1], 3, 6),
        ([1, 1, 1, 2, 2], 4, 9),
        ([2, 2, 2, 2, 1], nil, 9),
        ([2, 2, 2, 2, 2], nil, 12),
    ]
    static let laterRounds: [(blocks: [Int], upgradeAt: Int?, need: Int)] = [
        ([0, 0, 0, 0, 1, 1], 3, 6),
        ([1, 1, 1, 2, 2], 4, 9),
        ([2, 2, 2, 3, 3], 6, 13),
        ([3, 3, 3, 3, 2, 2], nil, 16),
    ]
    /// The biggest quarry dozer (tier) each round allows.
    static func maxTier(round: Int) -> Int { round == 1 ? 2 : 3 }
    /// From round 2 every room gets extra big blocks (one more each round), and the gate needs their gold too.
    static func plan(_ room: Int, round: Int) -> (blocks: [Int], upgradeAt: Int?, need: Int) {
        let base = round == 1 ? firstRound[room] : laterRounds[room]
        let extra = min(4, max(0, round - 1)), big = base.blocks.max()!
        return (base.blocks + Array(repeating: big, count: extra), base.upgradeAt, base.need + extra * (big + 1))
    }
    var nugget: [SCNGeometry] = []               // a few rough-cut shapes, shared by all blocks
    var rects: [CGRect] = []
    var gates: [Gate] = []
    var crushers: [Crusher] = []
    var blocks: [GoldBlock] = []
    var leaving: CGFloat = -1                    // >= 0 while heading down to the mines
    var heavyNote: CGFloat = -10                 // when "NEED DOZER" was last shown
    let dust = SCNNode()
    var start: CGPoint { CGPoint(x: 5 + Quarry.dx, y: -3) }
    func unlocked(_ i: Int) -> Bool { i == 0 || gates[i - 1].open }
    func room(at p: CGPoint) -> Int? { rects.firstIndex { p.y >= $0.minY && p.y < $0.maxY } }
}

extension Game {

    // MARK: Building

    func buildQuarry() {
        let q = quarry
        q.rects = areas.map { $0.rect.offsetBy(dx: Quarry.dx, dy: 0) }
        q.gates = gates.map { Gate(y: $0.y, x: $0.x + Quarry.dx) }
        q.crushers = q.rects.enumerated().map { i, r in
            Crusher(room: i, x0: r.minX, y: areas[i].beltStart.y,
                    mouth: max(1.05, Quarry.sizes[Quarry.laterRounds[i].blocks.max()!] + 0.55), need: Quarry.firstRound[i].need)
        }

        // floor: tan stone slabs in the rooms, brown dirt all around
        let sand = floorShape(CGRect(x: Quarry.dx - 60, y: -40, width: 120, height: 140), holes: [],
                              mat: floorMat((0.36, 0.28, 0.18), seed: 5, repeats: 24))
        sand.position = v3(0, -0.03, 0)
        scene.rootNode.addChildNode(sand)
        let slabs = Art.cobbleImage(seed: 7, stone: (0.62, 0.53, 0.4), grout: (0.3, 0.24, 0.16), count: 5)
        for r in q.rects {
            let mat = Art.pbr(slabs, rough: 0.85)
            mat.diffuse.wrapS = .repeat; mat.diffuse.wrapT = .repeat
            mat.diffuse.mipFilter = .linear
            #if os(macOS)
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(r.width / 4, r.height / 4, 1)
            #else
            mat.diffuse.contentsTransform = SCNMatrix4MakeScale(Float(r.width / 4), Float(r.height / 4), 1)
            #endif
            scene.rootNode.addChildNode(floorShape(r, holes: [], mat: mat))
        }

        // brown rock spires instead of crystals
        let mats: [SCNMaterial] = [
            Art.pbr(rgb(0.58, 0.44, 0.3), rough: 0.85, emit: rgb(0.06, 0.04, 0.02)),
            Art.pbr(rgb(0.72, 0.6, 0.44), rough: 0.8, emit: rgb(0.08, 0.06, 0.03)),
            Art.pbr(rgb(0.44, 0.33, 0.22), rough: 0.9, emit: rgb(0.04, 0.03, 0.01)),
            Art.pbr(rgb(0.82, 0.72, 0.56), rough: 0.8, emit: rgb(0.1, 0.08, 0.04)),
        ]
        buildWalls(rects: q.rects, gates: q.gates, openings: q.crushers.map { $0.y }, openingHalf: 1.9,
                   mats: mats, rockMat: Art.pbr(rgb(0.36, 0.28, 0.2), rough: 0.9), seed: 77)
        buildGates(q.gates, cap: rgb(0.15, 0.55, 0.6))
        for c in q.crushers { buildCrusher(c) }

        q.dust.addParticleSystem(Art.particles(color: rgb(0.9, 0.72, 0.45), size: 0.35, life: 1.0, speed: 1.6,
                                               spread: 60, gravity: 0.6, additive: false))
        scene.rootNode.addChildNode(q.dust)
        let gold = Art.pbr(rgb(1, 0.7, 0.12), metal: 0.8, rough: 0.35, emit: rgb(0.38, 0.21, 0.0))
        q.nugget = (0..<5).map { k in
            let g = Art.nugget(seed: UInt64(31 + k * 7))
            g.materials = [gold]
            return g
        }
        spawnBlocks(round: 1)
    }

    func buildCrusher(_ c: Crusher) {
        let body = DozerModel.machineYellow, steel = DozerModel.steel
        let dark = Art.pbr(rgb(0.12, 0.11, 0.12), metal: 0.6, rough: 0.5)
        let H = Quarry.housing, M = c.mouth
        let n = c.node
        n.position = world(CGPoint(x: c.x0, y: c.y))
        // local x points into the room (the mouth is at x = 0, the wall line), local z = -game y
        Art.box(0.5, 1.6, M * 2 + 0.9, body, at: v3(-H - 0.05, 0.8, 0), in: n)                    // back
        Art.box(H + 0.35, 0.25, M * 2 + 0.9, body, at: v3(-H / 2 - 0.1, 1.5, 0), in: n)            // roof
        for sz in [-1.0, 1.0] as [CGFloat] {                                                        // sides
            Art.box(H + 0.05, 1.1, 0.4, body, at: v3(-H / 2, 0.55, sz * (M + 0.2)), in: n)
            Art.box(0.12, 1.15, 0.46, steel, at: v3(-0.04, 0.58, sz * (M + 0.2)), in: n)           // steel edge
        }
        Art.box(H, 0.06, M * 2, dark, at: v3(-H / 2, 0.03, 0), in: n)                               // dark throat floor
        // two toothed rollers across the mouth
        for (k, x) in [-H * 0.6, -H * 0.18].enumerated() {
            let roller = SCNNode()
            roller.position = v3(x, 0.42, 0)
            let drum = SCNCylinder(radius: 0.28, height: M * 2 - 0.05); drum.materials = [steel]
            let dn = SCNNode(geometry: drum); dn.eulerAngles = v3(.pi / 2, 0, 0); roller.addChildNode(dn)
            for t in 0..<8 {
                let a = CGFloat(t) / 8 * 2 * .pi + CGFloat(k) * 0.4
                let tooth = Art.box(0.12, 0.12, M * 2 - 0.15, dark, at: v3(cos(a) * 0.3, sin(a) * 0.3, 0), in: roller)
                tooth.eulerAngles = v3(0, 0, a)
            }
            n.addChildNode(roller)
            c.rollers.append(roller)
        }
        // warning lamp on the roof
        let lamp = SCNSphere(radius: 0.14); lamp.materials = [Art.pbr(rgb(1, 0.4, 0.1), emit: rgb(1.2, 0.35, 0.05))]
        let ln = SCNNode(geometry: lamp); ln.position = v3(-H * 0.4, 1.7, 0); n.addChildNode(ln)
        scene.rootNode.addChildNode(n)

        // feeder belt, flush with the floor, running from the room into the mouth
        let f = SCNNode()
        let a = CGPoint(x: c.x0 + c.feedLen, y: c.y), b = CGPoint(x: c.x0, y: c.y)
        f.position = world((a + b) * 0.5)
        f.eulerAngles = v3(0, atan2(b.x - a.x, 0), 0)   // local z runs along the belt toward the crusher
        c.feedMat.diffuse.contents = Art.beltImage
        c.feedMat.diffuse.wrapS = .repeat; c.feedMat.diffuse.wrapT = .repeat
        c.feedMat.roughness.contents = 0.8
        c.feedMat.lightingModel = .physicallyBased
        let belt = SCNBox(width: M * 2, height: 0.03, length: c.feedLen, chamferRadius: 0)
        belt.materials = [dark, dark, dark, dark, c.feedMat, dark]
        let bn = SCNNode(geometry: belt); bn.position = v3(0, 0.0, 0); f.addChildNode(bn)
        for sx in [-1.0, 1.0] as [CGFloat] {   // yellow edges
            Art.box(0.14, 0.04, c.feedLen, body, at: v3(sx * (M + 0.07), 0.0, 0), chamfer: 0.01, in: f)
        }
        Art.box(M * 2 + 0.28, 0.04, 0.14, body, at: v3(0, 0.0, -c.feedLen / 2 - 0.07), chamfer: 0.01, in: f)
        scene.rootNode.addChildNode(f)

        // conveyor out through the wall, ending over a dark shaft down to the mines
        scene.rootNode.addChildNode(conveyor(from: c.beltStart, to: c.beltEnd, mat: c.beltMat))
        let shaft = SCNCylinder(radius: 0.8, height: 0.02); shaft.materials = [Art.pbr(rgb(0.02, 0.01, 0.01), rough: 1)]
        let sn = SCNNode(geometry: shaft); sn.position = world(c.beltEnd - CGPoint(x: 0.6, y: 0), 0.0); scene.rootNode.addChildNode(sn)
        let rim = SCNTube(innerRadius: 0.8, outerRadius: 0.95, height: 0.1); rim.materials = [steel]
        let rn = SCNNode(geometry: rim); rn.position = world(c.beltEnd - CGPoint(x: 0.6, y: 0), 0.05); scene.rootNode.addChildNode(rn)
    }

    /// Scatter each room's blocks for this round (the same layout every time you play that round),
    /// clear of the feeder belt, the gates and the start.
    func spawnBlocks(round: Int) {
        let q = quarry
        for b in q.blocks { b.node.removeFromParentNode() }
        q.blocks = []
        var rng = SeededRNG(s: 2024 + UInt64(round) * 97)
        for (i, rect) in q.rects.enumerated() {
            let c = q.crushers[i]
            let plan = Quarry.plan(i, round: round)
            c.need = plan.need
            // big ones first, so they get room
            for cls in plan.blocks.sorted(by: >) {
                let r = Quarry.sizes[cls]
                var tries = 0, placed = false
                while tries < 3000 && !placed {
                    tries += 1
                    let p = CGPoint(x: CGFloat.random(in: rect.minX + r + 1.0...rect.maxX - r - 1.0, using: &rng),
                                    y: CGFloat.random(in: rect.minY + r + 1.0...rect.maxY - r - 1.0, using: &rng))
                    if p.x < c.x0 + c.feedLen + r + 1.6 && abs(p.y - c.y) < c.mouth + r + 1.4 { continue }
                    if q.gates.contains(where: { abs(p.y - $0.y) < r + 1.4 }) { continue }
                    if p.dist(q.start) < 3 { continue }
                    if q.blocks.contains(where: { $0.p.dist(p) < $0.r + r + 0.9 }) { continue }
                    addBlock(to: q, room: i, cls: cls, at: p, rng: &rng)
                    placed = true
                }
                if !placed { c.need -= cls + 1 }   // no room for it: don't make the gate wait for it
            }
        }
    }

    /// A rough-cut lump of gold, added to a quarry's blocks and the scene.
    func addBlock(to q: Quarry, room: Int, cls: Int, at p: CGPoint, rng: inout SeededRNG) {
        let r = Quarry.sizes[cls]
        let b = GoldBlock(room: room, cls: cls, at: p, angle: CGFloat.random(in: 0...6.28, using: &rng))
        let n = SCNNode(geometry: mainQuarry.nugget[Int.random(in: 0..<mainQuarry.nugget.count, using: &rng)])
        n.scale = v3(r * 0.95, r * CGFloat.random(in: 0.75...0.95, using: &rng), r * 0.95)
        n.castsShadow = true
        b.node.addChildNode(n)
        q.blocks.append(b)
        scene.rootNode.addChildNode(b.node)
        placeBlock(b)
    }

    func placeBlock(_ b: GoldBlock) {
        b.node.position = world(b.p)
        b.node.eulerAngles = v3(0, b.angle, 0)
    }

    /// A new round (or new game): fresh blocks for the round, crushers and gates reset.
    func resetQuarry(round: Int) {
        let q = quarry
        spawnBlocks(round: round)
        for c in q.crushers {
            c.crushed = 0; c.pending = 0; c.busy = 0; c.done = false; c.upgraded = false
            for r in c.riders { r.node.removeFromParentNode() }
            c.riders = []
        }
        for g in q.gates {
            g.open = false
            g.bars.removeAllActions()
            g.bars.position = v3(g.x, 0, -g.y)
            g.bars.isHidden = false
        }
        q.leaving = -1
        stage = .quarry
        applyStageLook()
    }

    /// Colours that differ between the desert quarry, the vault and the green mines.
    func applyStageLook() {
        let desert = stage == .quarry, vault = stage == .intro
        let bg = vault ? rgb(0.07, 0.07, 0.07) : desert ? rgb(0.14, 0.11, 0.08) : rgb(0.08, 0.06, 0.04)
        scene.background.contents = bg
        view?.backgroundColor = bg
        ambient.color = vault ? rgb(0.95, 0.95, 0.95) : desert ? rgb(1, 0.95, 0.88) : rgb(1, 0.95, 0.88)
        ambient.intensity = desert || vault ? 500 : 450
        let goal = vault ? "fill the button, then crush the gold" : desert ? "push the gold into the crusher" : "pile gold on the buttons"
        #if os(iOS)
        hud.hint.text = "▲▼ drive · ◀ ▶ turn · " + goal
        #else
        hud.hint.text = "W/S drive · A/D turn · " + goal
        #endif
        hud.layout()
    }

    // MARK: Rules

    /// Quarry version of `blocked`: room walls and gates (the crushers sit back in the walls).
    func quarryBlocked(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Bool {
        let q = quarry
        guard let ai = q.room(at: CGPoint(x: x, y: y)), q.unlocked(ai) else { return true }
        let a = q.rects[ai]
        if x < a.minX + r || x > a.maxX - r { return true }
        if ai == 0 && y < a.minY + r { return true }
        if ai == q.rects.count - 1 && y > a.maxY - r { return true }
        for gi in [ai - 1, ai] where gi >= 0 && gi < q.gates.count {
            let g = q.gates[gi]
            if abs(y - g.y) < r + wallBand {
                if !g.open || abs(x - g.x) > g.half - r { return true }
            }
        }
        return false
    }

    /// A pinned block (stuck against a wall) stops the dozer instead of letting it drive through.
    func hitsPinnedBlock(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Bool {
        for b in quarry.blocks where b.pinned && !b.gone && b.crushT < 0 {
            if hypot(x - b.p.x, y - b.p.y) < r + b.bound * 0.95 { return true }
        }
        return false
    }

    // MARK: Simulation

    /// Push blocks with the dozer, crush the ones in a crusher's mouth. Returns how hard the dozer is pushing.
    func updateQuarry(_ dt: CGFloat) -> CGFloat {
        let q = quarry
        let b = makeBlade()
        var load: CGFloat = 0
        let wallFree: (GoldBlock, CGPoint) -> Bool = { [unowned self] blk, p in !self.quarryBlocked(p.x, p.y, blk.bound) }

        for blk in q.blocks where !blk.gone && blk.crushT < 0 && !blk.riding {
            if blk.cls > tier {
                // too heavy for this dozer: it won't budge (and stops the dozer)
                blk.pinned = true
                let (_, _, near) = pushedOutBlock(blk.p, angle: blk.angle, half: blk.half * 1.25, b)
                if near && clock - q.heavyNote > 1.5 {
                    q.heavyNote = clock
                    floatText("NEED DOZER \(blk.cls + 1)!", at: blk.p, h: 1.6, color: rgb(1, 0.55, 0.4), size: 26)
                }
                continue
            }
            var p = carried(blk.p, b)
            let (np, na, touched) = pushedOutBlock(p, angle: blk.angle, half: blk.half, b)
            p = np
            blk.pinned = false
            if touched {
                load += 25
                blk.angle = na
            }
            if p != blk.p {
                if wallFree(blk, p) { blk.p = p }
                else if wallFree(blk, CGPoint(x: p.x, y: blk.p.y)) { blk.p.x = p.x; blk.pinned = true }
                else if wallFree(blk, CGPoint(x: blk.p.x, y: p.y)) { blk.p.y = p.y; blk.pinned = true }
                else { blk.pinned = true }
            }
        }
        // blocks shove each other apart
        let live = q.blocks.filter { !$0.gone && $0.crushT < 0 && !$0.riding }
        for _ in 0..<2 {
            for i in 0..<live.count {
                for j in (i + 1)..<max(i + 1, live.count) {
                    let a = live[i], c = live[j]
                    let d = a.p.dist(c.p), minD = a.bound + c.bound
                    guard d < minD, d > 1e-4 else { continue }
                    let n = (c.p - a.p) * (1 / d), push = minD - d
                    let pa = a.p - n * (push / 2), pc = c.p + n * (push / 2)
                    let okA = a.cls <= tier && wallFree(a, pa), okC = c.cls <= tier && wallFree(c, pc)
                    if okA && okC { a.p = pa; c.p = pc }
                    else if okC, c.cls <= tier, wallFree(c, c.p + n * push) { c.p = c.p + n * push; a.pinned = a.pinned || !okA }
                    else if okA, a.cls <= tier, wallFree(a, a.p - n * push) { a.p = a.p - n * push; c.pinned = c.pinned || !okC }
                    else { a.pinned = true; c.pinned = true }
                }
            }
        }
        // onto a feeder belt?
        for blk in live {
            placeBlock(blk)
            guard let ri = q.room(at: blk.p) else { continue }
            let c = q.crushers[ri]
            if abs(blk.p.y - c.y) < c.mouth - blk.r * 0.3 && blk.p.x < c.x0 + c.feedLen + blk.r * 0.2 {
                blk.riding = true
                blk.pinned = false
            }
        }
        // riding the belt into the crusher, lining up as it goes
        for blk in q.blocks where blk.riding && !blk.gone && blk.crushT < 0 {
            guard let ri = q.room(at: blk.p) else { continue }
            let c = q.crushers[ri]
            // the belt carries it along; the dozer still pushes it (or stands in its way: then the belt
            // just slips under it). No wall checks here: the belt guides it into the crusher's mouth.
            let carriedP = CGPoint(x: blk.p.x - 1.5 * dt, y: lerp(blk.p.y, c.y, min(1, 3 * dt)))
            let (pushed, na, touched) = pushedOutBlock(carriedP, angle: blk.angle, half: blk.half, b)
            if touched {
                load += 25
                blk.angle = na
                // if the blade is right in front, pushing back against the belt, it stays put
                blk.p = pushed.x > carriedP.x + 1e-4 ? CGPoint(x: max(blk.p.x, pushed.x), y: pushed.y) : pushed
            } else {
                blk.p = carriedP
                var d = (-blk.angle).truncatingRemainder(dividingBy: .pi / 2)
                if d > .pi / 4 { d -= .pi / 2 } else if d < -.pi / 4 { d += .pi / 2 }
                blk.angle += d * min(1, 3 * dt)
            }
            // pushed off the side or back off the end of the belt: an ordinary block again
            if abs(blk.p.y - c.y) > c.mouth - blk.r * 0.2 || blk.p.x > c.x0 + c.feedLen + blk.r * 0.4 {
                blk.riding = false
                if quarryBlocked(blk.p.x, blk.p.y, blk.bound) {   // never leave it inside a wall
                    blk.p = CGPoint(x: max(blk.p.x, c.x0 + blk.bound + 0.01), y: blk.p.y)
                }
                placeBlock(blk)
                continue
            }
            if blk.p.x - blk.r * 0.5 <= c.x0 {
                blk.crushT = 0
                blk.crushFrom = blk.p
                c.busy = 1.3
            }
            placeBlock(blk)
        }
        for c in q.crushers {   // the feeder belts always run
            c.feedScroll -= 1.5 * dt / 0.5
            c.feedMat.diffuse.contentsTransform = texMatrix(1, c.feedLen / 0.5, c.feedScroll)
        }
        animateCrushing(dt)
        updateCrusherBelts(dt)
        return load
    }

    /// Being crushed: the block is dragged in between the rollers, shaking and shrinking, in a cloud of dust.
    func animateCrushing(_ dt: CGFloat) {
        let q = quarry
        for blk in q.blocks where blk.crushT >= 0 && !blk.gone {
            blk.crushT += dt
            let k = min(1, blk.crushT / 1.2)
            let c = q.crushers[q.room(at: blk.crushFrom) ?? blk.room]
            let target = CGPoint(x: c.x0 - Quarry.housing * 0.5, y: c.y)
            blk.p = lerpP(blk.crushFrom, target, min(1, k * 1.6))
            let jitter = CGPoint(x: .random(in: -0.04...0.04), y: .random(in: -0.04...0.04)) * (1 - k)
            blk.node.position = world(blk.p + jitter, -0.5 * k * k)
            let s = max(0.05, 1 - k * 0.9)
            blk.node.scale = v3(s, s, s)
            q.dust.position = world(CGPoint(x: c.x0 + 0.2, y: c.y), 0.6)
            q.dust.particleSystems?.first?.birthRate = 60
            if k >= 1 {
                blk.gone = true
                blk.node.isHidden = true
                c.crushed += blk.value
                c.pending += 3 + 2 * blk.cls
                burst.position = world(CGPoint(x: c.x0 + 0.1, y: c.y), 0.6)
                burstTimer = 0.25
                floatText("+\(blk.value)", at: CGPoint(x: c.x0 + 0.5, y: c.y), h: 2, color: rgb(1, 0.85, 0.35), size: 30)
                roomCrushed(c)
            }
        }
        if !q.blocks.contains(where: { $0.crushT >= 0 && !$0.gone }) { q.dust.particleSystems?.first?.birthRate = 0 }
    }

    /// Gold crushed: enough earns the room's bigger dozer; more opens the gate, or after the last room heads down to the mines.
    func roomCrushed(_ c: Crusher) {
        let q = quarry
        if stage == .intro {
            if !c.done && c.crushed >= c.need { c.done = true; finishIntro() }
            return
        }
        if !c.upgraded, let at = Quarry.plan(c.room, round: round).upgradeAt, c.crushed >= at, tier < Quarry.maxTier(round: round) {
            c.upgraded = true
            tier += 1
            applyTier()
            pop = 1
            floatText("BIGGER DOZER!", at: pos, h: 2.5, color: .white, size: 36)
        }
        guard !c.done, c.crushed >= c.need else { return }
        c.done = true
        if c.room < q.gates.count {
            let g = q.gates[c.room]
            g.open = true
            g.bars.runAction(.sequence([.move(by: v3(0, -1.9, 0), duration: 0.6), .hide()]))
            floatText("GATE OPEN!", at: CGPoint(x: g.x, y: g.y), h: 2, color: .white, size: 36)
        } else {
            q.leaving = 0
            floatText("TO THE MINES!", at: pos, h: 2.5, color: rgb(1, 0.85, 0.35), size: 40)
        }
        #if os(iOS)
        DispatchQueue.main.async { [weak self] in
            self?.haptic.impactOccurred()
            self?.haptic.prepare()
        }
        #endif
    }

    /// Coins from crushed blocks ride the belt out through the wall and drop down the shaft.
    func updateCrusherBelts(_ dt: CGFloat) {
        for c in quarry.crushers {
            c.busy = max(0, c.busy - dt)
            c.rollAngle += (c.busy > 0 ? 9 : 1.2) * dt
            for (k, r) in c.rollers.enumerated() { r.eulerAngles = v3(0, 0, c.rollAngle * (k == 0 ? 1 : -1)) }
            c.node.position = world(CGPoint(x: c.x0, y: c.y) + (c.busy > 0 ? CGPoint(x: .random(in: -0.02...0.02), y: .random(in: -0.02...0.02)) : .zero))
            if c.pending > 0 {
                c.dropTimer -= dt
                if c.dropTimer <= 0 {
                    c.dropTimer = 0.3
                    c.pending -= 1
                    let node = SCNNode(geometry: clumps[Int.random(in: 0..<clumps.count)].geo)
                    node.eulerAngles = v3(0, .random(in: 0...6), 0)
                    scene.rootNode.addChildNode(node)
                    c.riders.append((node, 0))
                }
            }
            guard !c.riders.isEmpty else { continue }
            let L = c.beltStart.dist(c.beltEnd), speed: CGFloat = 1.6
            c.scroll -= speed * dt / 0.5
            c.beltMat.diffuse.contentsTransform = texMatrix(1, L / 0.5, c.scroll)
            var keep: [(node: SCNNode, t: CGFloat)] = []
            for var r in c.riders {
                r.t += speed * dt / L
                if r.t >= 1.35 { r.node.removeFromParentNode(); continue }
                if r.t < 1 {
                    r.node.position = world(lerpP(c.beltStart, c.beltEnd, r.t), 0.55)
                } else {
                    // off the end of the belt and down the shaft
                    let k = (r.t - 1) / 0.35
                    r.node.position = world(c.beltEnd - CGPoint(x: 0.6 * k, y: 0), 0.55 - 1.6 * k * k)
                }
                keep.append(r)
            }
            c.riders = keep
        }
    }

    /// Heading down: fade out, move the dozer to mine 1 (back to the first dozer), fade in.
    func updateLeaving(_ dt: CGFloat) {
        let q = quarry
        guard q.leaving >= 0 else { return }
        let before = q.leaving
        q.leaving += dt
        if before < 1.6 && q.leaving >= 1.6 { DispatchQueue.main.async { [weak self] in self?.hud.fadeThrough() } }
        if before < 2.2 && q.leaving >= 2.2 {
            q.leaving = -1
            stage = .mines
            applyStageLook()
            tier = 0
            applyTier()
            pos = startPos; prevPos = pos; camTarget = pos
            heading = .pi / 2; prevHeading = heading
            velocity = 0; pushLoad = 0; pop = 0
            camScale = baseZoom
            refreshTags()
            hintShown = true
            hud.hint.removeAllActions()
            hud.hint.alpha = 1
        }
    }

    // MARK: Pushing (the coin rules, for one big circle)

    /// Inside the plow while turning, a block turns with the dozer (so turning doesn't spill it).
    func carried(_ p: CGPoint, _ b: CoinField.Blade) -> CGPoint {
        let plx = CGFloat(-b.prevFy), ply = CGFloat(b.prevFx)
        let lx = CGFloat(-b.fy), ly = CGFloat(b.fx)
        guard abs(plx - lx) + abs(ply - ly) > 1e-5 else { return p }
        let dx = p.x - CGFloat(b.prevX), dy = p.y - CGFloat(b.prevY)
        let local = SIMD2<Float>(Float(dx * plx + dy * ply), Float(dx * CGFloat(b.prevFx) + dy * CGFloat(b.prevFy)))
        guard CoinField.inside(local, b.hold) else { return p }
        return CGPoint(x: CGFloat(b.prevX) + CGFloat(local.y) * CGFloat(b.fx) + CGFloat(local.x) * lx,
                       y: CGFloat(b.prevY) + CGFloat(local.y) * CGFloat(b.fy) + CGFloat(local.x) * ly)
    }

    /// Points around a unit circle: a nugget's outline in block space.
    static let blockOutline: [CGPoint] = (0..<14).map { k in
        let a = CGFloat(k) / 14 * 2 * .pi
        return CGPoint(x: cos(a), y: sin(a))
    }

    /// How far a small circle (radius `pr`) at `pt` must move to get out of the dozer's chassis box and plow walls.
    func penetration(_ pt: CGPoint, _ pr: CGFloat, _ b: CoinField.Blade) -> CGPoint? {
        var best: CGPoint? = nil
        func keep(_ v: CGPoint) { if v.length > (best?.length ?? 0) { best = v } }
        let fx = CGFloat(b.fx), fy = CGFloat(b.fy)
        let rx = fy, ry = -fx
        let hw = CGFloat(b.halfWidth), back = CGFloat(b.back), front = CGFloat(b.front)
        let dx = pt.x - CGFloat(b.x), dy = pt.y - CGFloat(b.y)
        let ly = dx * fx + dy * fy, lx = dx * rx + dy * ry
        if lx > -hw - pr && lx < hw + pr && ly > -back - pr && ly < front + pr {
            let pf = front + pr - ly, pl = lx + hw + pr, prt = hw + pr - lx, pb = ly + back + pr
            let m = min(min(pf, pl), min(prt, pb))
            if m == pf { keep(CGPoint(x: fx, y: fy) * pf) }
            else if m == pl { keep(CGPoint(x: -rx, y: -ry) * pl) }
            else if m == prt { keep(CGPoint(x: rx, y: ry) * prt) }
            else { keep(CGPoint(x: -fx, y: -fy) * pb) }
        }
        let wr = CGFloat(b.wallHalf) + pr
        for s in b.segs {
            let ax = CGFloat(s.x), ay = CGFloat(s.y), bx = CGFloat(s.z), by = CGFloat(s.w)
            let abx = bx - ax, aby = by - ay
            let len2 = abx * abx + aby * aby
            var t = len2 > 0 ? ((pt.x - ax) * abx + (pt.y - ay) * aby) / len2 : 0
            t = max(0, min(1, t))
            let ddx = pt.x - (ax + abx * t), ddy = pt.y - (ay + aby * t)
            let d = hypot(ddx, ddy)
            if d < wr { keep(d > 1e-4 ? CGPoint(x: ddx / d, y: ddy / d) * (wr - d) : CGPoint(x: fx, y: fy) * wr) }
        }
        return best
    }

    /// Push a square block out of the dozer. Its outline points each push back; contacts off the centre
    /// turn the block (so a block hit on a corner swings round to sit flat against the blade).
    /// A big circle inside the square backs this up, so a fast blade can't slip between the outline points.
    /// Returns the new centre and angle, and whether the dozer touched it.
    func pushedOutBlock(_ p0: CGPoint, angle a0: CGFloat, half h: CGFloat, _ b: CoinField.Blade) -> (CGPoint, CGFloat, Bool) {
        var p = p0, a = a0, touched = false
        for _ in 0..<3 {
            let c = cos(a), s = sin(a)
            var deepest = CGPoint.zero
            var torque: CGFloat = 0
            for q in Game.blockOutline {
                let off = CGPoint(x: (q.x * c - q.y * s) * h, y: (q.x * s + q.y * c) * h)
                guard let push = penetration(p + off, 0.04, b) else { continue }
                if push.length > deepest.length { deepest = push }
                torque += off.x * push.y - off.y * push.x
            }
            if let push = penetration(p, h * 0.92, b), push.length > deepest.length { deepest = push }
            guard deepest.length > 1e-5 else { break }
            touched = true
            p = p + deepest
            a += max(-0.08, min(0.08, torque / (h * h) * 0.35))
        }
        return (p, a, touched)
    }
}
