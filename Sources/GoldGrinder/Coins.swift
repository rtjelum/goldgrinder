import SceneKit
import simd

/// All loose coins: simple 2D push physics on the ground plane, rendered as batched 3D meshes.
///
/// Game coords (x, y) map to world (x, h, -y). Coins sleep until something touches them, so only the
/// coins near the blade cost anything. Rendering groups coins into 3x3 chunks; a chunk's mesh is
/// rebuilt only when one of its coins changes.
final class CoinField {
    enum State: UInt8 { case asleep, awake, selling, dead, growing }

    let r: Float = 0.13
    let thick: Float = 0.045

    // Per-coin data (struct of arrays)
    var px = [Float](), py = [Float](), ph = [Float](), lastX = [Float](), lastY = [Float]()
    var tiltX = [Float](), tiltZ = [Float](), scale = [Float](), value = [Float](), sellT = [Float]()
    var state = [State](), still = [UInt8](), chunkOf = [Int]()
    var press = [Float]()   // how hard a coin was squeezed this frame
    var awake = [Int](), animating = [Int]()
    var deadCount = 0
    var count: Int { px.count }

    // Spatial grid for neighbour lookups
    let minX: Float, minY: Float, maxX: Float, maxY: Float
    let cell: Float = 0.3
    let gCols: Int, gRows: Int
    var head: [Int]
    var nextIdx = [Int]()

    // Render chunks
    let cSize: Float = 3
    let cCols: Int, cRows: Int
    var chunkNodes: [SCNNode] = []
    var chunkDirty: [Bool]
    var members: [[Int]]
    let root = SCNNode()

    // Coin mesh template
    var tP = [SIMD3<Float>](), tN = [SIMD3<Float>](), tUV = [SIMD2<Float>](), tI = [UInt32]()

    init(minX: Float, minY: Float, maxX: Float, maxY: Float) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        gCols = Int((maxX - minX) / cell) + 1
        gRows = Int((maxY - minY) / cell) + 1
        head = [Int](repeating: -1, count: gCols * gRows)
        cCols = Int((maxX - minX) / cSize) + 1
        cRows = Int((maxY - minY) / cSize) + 1
        chunkDirty = [Bool](repeating: false, count: cCols * cRows)
        members = [[Int]](repeating: [], count: cCols * cRows)
        for _ in 0..<(cCols * cRows) {
            let n = SCNNode()
            n.castsShadow = true
            root.addChildNode(n)
            chunkNodes.append(n)
        }
        buildTemplate()
    }

    func buildTemplate() {
        let seg = 12
        let h = thick / 2
        // top: centre + rim
        tP.append([0, h, 0]); tN.append([0, 1, 0]); tUV.append([0.5, 0.5])
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            tP.append([cos(a) * r, h, sin(a) * r]); tN.append([0, 1, 0])
            tUV.append([0.5 + 0.47 * cos(a), 0.5 + 0.47 * sin(a)])
        }
        for i in 0..<seg {
            tI += [0, UInt32(1 + (i + 1) % seg), UInt32(1 + i)]
        }
        // side ring (top + bottom)
        let base = UInt32(tP.count)
        for i in 0..<seg {
            let a = Float(i) / Float(seg) * 2 * .pi
            let n = SIMD3<Float>(cos(a), 0, sin(a))
            tP.append([cos(a) * r, h, sin(a) * r]); tN.append(n); tUV.append([0.03, 0.5])
            tP.append([cos(a) * r, -h, sin(a) * r]); tN.append(n); tUV.append([0.02, 0.5])
        }
        for i in 0..<seg {
            let t0 = base + UInt32(i * 2), b0 = t0 + 1
            let t1 = base + UInt32(((i + 1) % seg) * 2), b1 = t1 + 1
            tI += [t0, t1, b0, t1, b1, b0]
        }
    }

    // MARK: Adding / indexing

    @inline(__always) func chunkIndex(_ x: Float, _ y: Float) -> Int {
        let cx = max(0, min(cCols - 1, Int((x - minX) / cSize)))
        let cy = max(0, min(cRows - 1, Int((y - minY) / cSize)))
        return cy * cCols + cx
    }

    @inline(__always) func gridIndex(_ x: Float, _ y: Float) -> (Int, Int) {
        (max(0, min(gCols - 1, Int((x - minX) / cell))), max(0, min(gRows - 1, Int((y - minY) / cell))))
    }

    func add(_ x: Float, _ y: Float, h: Float = 0, value v: Float, grow: Bool) {
        let i = count
        px.append(x); py.append(y); ph.append(h); lastX.append(x); lastY.append(y)
        tiltX.append(.random(in: -0.25...0.25)); tiltZ.append(.random(in: -0.25...0.25))
        scale.append(grow ? 0.01 : 1); value.append(v); sellT.append(0)
        state.append(grow ? .growing : .asleep); still.append(0)
        press.append(0)
        let c = chunkIndex(x, y)
        chunkOf.append(c)
        chunkDirty[c] = true
        nextIdx.append(-1)
        if grow { animating.append(i) }
    }

    @inline(__always) func solid(_ i: Int) -> Bool {
        let s = state[i]
        return s == .asleep || s == .awake || s == .growing
    }

    func rebuildGrid() {
        for k in 0..<head.count { head[k] = -1 }
        for i in 0..<count where solid(i) {
            let (gx, gy) = gridIndex(px[i], py[i])
            let k = gy * gCols + gx
            nextIdx[i] = head[k]
            head[k] = i
        }
    }

    func hasCoin(near x: Float, _ y: Float, within d: Float) -> Bool {
        let (gx, gy) = gridIndex(x, y)
        let d2 = d * d
        for cy in max(0, gy - 1)...min(gRows - 1, gy + 1) {
            for cx in max(0, gx - 1)...min(gCols - 1, gx + 1) {
                var j = head[cy * gCols + cx]
                while j >= 0 {
                    let dx = px[j] - x, dy = py[j] - y
                    if dx * dx + dy * dy < d2 { return true }
                    j = nextIdx[j]
                }
            }
        }
        return false
    }

    @inline(__always) func wake(_ i: Int) {
        if state[i] == .asleep || state[i] == .growing {
            if state[i] == .growing { scale[i] = 1 }
            state[i] = .awake
            press[i] = 0
            awake.append(i)
        }
        still[i] = 0
    }

    @inline(__always) func touch(_ i: Int) {
        chunkDirty[chunkOf[i]] = true
        let c = chunkIndex(px[i], py[i])
        if c != chunkOf[i] { chunkOf[i] = c; chunkDirty[c] = true }
    }

    @inline(__always) func move(_ i: Int, _ dx: Float, _ dy: Float, _ blocked: (Float, Float) -> Bool) {
        let nx = px[i] + dx, ny = py[i] + dy
        if !blocked(nx, ny) { px[i] = nx; py[i] = ny }
        else if !blocked(nx, py[i]) { px[i] = nx }
        else if !blocked(px[i], ny) { py[i] = ny }
        wake(i)
        touch(i)
    }

    // MARK: Simulation

    struct Blade {
        var x: Float, y: Float      // dozer centre
        var fx: Float, fy: Float    // forward (unit)
        var halfWidth: Float, back: Float, front: Float   // chassis box
        var segs: [SIMD4<Float>]    // plow wall segments (ax, ay, bx, by) in game coords
        var wallHalf: Float
        // Coins inside `hold` (dozer-local: x = left, y = forward) turn with the dozer
        var prevX: Float, prevY: Float, prevFx: Float, prevFy: Float
        var hold: [SIMD2<Float>]
    }

    static func inside(_ p: SIMD2<Float>, _ poly: [SIMD2<Float>]) -> Bool {
        var c = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i
        }
        return c
    }

    /// Coins inside the plow turn with the dozer, so turning doesn't spill them.
    /// (Driving forward needs no help: the plow's back wall pushes them.)
    func carry(_ b: Blade, _ blocked: (Float, Float) -> Bool) {
        let plx = -b.prevFy, ply = b.prevFx        // previous left vector
        let lx = -b.fy, ly = b.fx                  // current left vector
        guard abs(plx - lx) + abs(ply - ly) > 1e-5 else { return }   // not turning
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for q in b.hold {
            let w = SIMD2<Float>(b.prevX + q.y * b.prevFx + q.x * plx, b.prevY + q.y * b.prevFy + q.x * ply)
            lo = simd_min(lo, w); hi = simd_max(hi, w)
        }
        let (g0x, g0y) = gridIndex(lo.x, lo.y)
        let (g1x, g1y) = gridIndex(hi.x, hi.y)
        for cy in g0y...g1y {
            for cx in g0x...g1x {
                var i = head[cy * gCols + cx]
                while i >= 0 {
                    let dx = px[i] - b.prevX, dy = py[i] - b.prevY
                    let local = SIMD2<Float>(dx * plx + dy * ply, dx * b.prevFx + dy * b.prevFy)
                    if CoinField.inside(local, b.hold) {
                        // same spot in the plow, rotated by this frame's turn (about the dozer's old centre)
                        let nx = b.prevX + local.y * b.fx + local.x * lx
                        let ny = b.prevY + local.y * b.fy + local.x * ly
                        move(i, nx - px[i], ny - py[i], blocked)
                    }
                    i = nextIdx[i]
                }
            }
        }
    }

    /// Push coins out of the chassis box and the plow walls. Returns how many coins were touched.
    func pushOut(_ b: Blade, _ blocked: (Float, Float) -> Bool) -> Int {
        var contacts = 0
        var lo = SIMD2<Float>(b.x, b.y), hi = lo
        let reachBody = max(b.halfWidth, max(b.back, b.front)) * 1.5
        lo -= reachBody; hi += reachBody
        for s in b.segs {
            lo = simd_min(lo, simd_min([s.x, s.y], [s.z, s.w]))
            hi = simd_max(hi, simd_max([s.x, s.y], [s.z, s.w]))
        }
        let pad = b.wallHalf + r
        let (g0x, g0y) = gridIndex(lo.x - pad, lo.y - pad)
        let (g1x, g1y) = gridIndex(hi.x + pad, hi.y + pad)
        let rx = b.fy, ry = -b.fx          // right vector
        let wr = b.wallHalf + r, wr2 = (wr - 0.002) * (wr - 0.002)   // ignore touching contacts (no endless nudging)
        let eps: Float = 0.002
        for cy in g0y...g1y {
            for cx in g0x...g1x {
                var i = head[cy * gCols + cx]
                while i >= 0 {
                    var touched = false
                    // chassis box
                    let dx = px[i] - b.x, dy = py[i] - b.y
                    let ly = dx * b.fx + dy * b.fy
                    let lx = dx * rx + dy * ry
                    if lx > -b.halfWidth - r + eps && lx < b.halfWidth + r - eps && ly > -b.back - r + eps && ly < b.front + r - eps {
                        let pf = b.front + r - ly, pl = lx + b.halfWidth + r
                        let pr = b.halfWidth + r - lx, pb = ly + b.back + r
                        let m = min(min(pf, pl), min(pr, pb))
                        if m == pf { move(i, b.fx * pf, b.fy * pf, blocked) }
                        else if m == pl { move(i, -rx * pl, -ry * pl, blocked) }
                        else if m == pr { move(i, rx * pr, ry * pr, blocked) }
                        else { move(i, -b.fx * pb, -b.fy * pb, blocked) }
                        touched = true
                    }
                    // plow walls
                    for s in b.segs {
                        let abx = s.z - s.x, aby = s.w - s.y
                        let len2 = abx * abx + aby * aby
                        var t = len2 > 0 ? ((px[i] - s.x) * abx + (py[i] - s.y) * aby) / len2 : 0
                        t = max(0, min(1, t))
                        let ddx = px[i] - (s.x + abx * t), ddy = py[i] - (s.y + aby * t)
                        let d2 = ddx * ddx + ddy * ddy
                        if d2 < wr2 {
                            if d2 > 1e-8 {
                                let d = d2.squareRoot()
                                move(i, ddx / d * (wr - d), ddy / d * (wr - d), blocked)
                            } else {
                                move(i, b.fx * wr, b.fy * wr, blocked)
                            }
                            touched = true
                        }
                    }
                    if touched { contacts += 1 }
                    i = nextIdx[i]
                }
            }
        }
        return contacts
    }

    /// Returns how many coins the blade is pushing this frame.
    func step(dt: Float, blade b: Blade, fillers: [(Float, Float, Float, Float)],
              blocked: (Float, Float) -> Bool, sold: (Float, Float, Float) -> Void) -> Int {
        rebuildGrid()
        for i in awake { press[i] = 0 }

        // 1. Coins held in the plow ride along, then chassis and plow walls push the rest
        carry(b, blocked)
        let contacts = pushOut(b, blocked)

        // 2. Coins push each other apart, but only within the same layer. When the blade squeezes
        //    two coins hard together, the one being pushed from behind climbs on top: that builds the heap.
        let minD = 2 * r * 0.86, minD2 = minD * minD
        let layer = thick * 0.95
        let maxH: Float = 0.6
        for _ in 0..<3 {
            var k = 0
            while k < awake.count {
                let i = awake[k]; k += 1
                guard state[i] == .awake else { continue }
                let (gx, gy) = gridIndex(px[i], py[i])
                for cy in max(0, gy - 1)...min(gRows - 1, gy + 1) {
                    for cx in max(0, gx - 1)...min(gCols - 1, gx + 1) {
                        var j = head[cy * gCols + cx]
                        while j >= 0 {
                            if j != i && solid(j) && abs(ph[i] - ph[j]) < layer * 0.8 {
                                let dx = px[j] - px[i], dy = py[j] - py[i]
                                let d2 = dx * dx + dy * dy
                                if d2 < minD2 {
                                    if d2 < 1e-8 {
                                        move(j, .random(in: -0.02...0.02), .random(in: -0.02...0.02), blocked)
                                    } else {
                                        let d = d2.squareRoot()
                                        if d > minD * 0.96 { j = nextIdx[j]; continue }   // close enough: no shivering
                                        let push = (minD - d) * 0.5
                                        press[i] += push; press[j] += push
                                        let nx = dx / d, ny = dy / d
                                        move(i, -nx * push, -ny * push, blocked)
                                        move(j, nx * push, ny * push, blocked)
                                    }
                                }
                            }
                            j = nextIdx[j]
                        }
                    }
                }
            }
        }

        // Squeezed coins climb on top of their neighbours: a jam turns into a heap instead of shivering
        for i in awake where state[i] == .awake && press[i] > 0.03 {
            var top: Float = -1
            let (gx, gy) = gridIndex(px[i], py[i])
            for cy in max(0, gy - 1)...min(gRows - 1, gy + 1) {
                for cx in max(0, gx - 1)...min(gCols - 1, gx + 1) {
                    var j = head[cy * gCols + cx]
                    while j >= 0 {
                        if j != i && solid(j) && abs(ph[i] - ph[j]) < layer * 0.8 {
                            let dx = px[j] - px[i], dy = py[j] - py[i]
                            if dx * dx + dy * dy < minD2 { top = max(top, ph[j]) }
                        }
                        j = nextIdx[j]
                    }
                }
            }
            if top >= 0 && top + layer <= maxH {
                ph[i] = top + layer
                touch(i)
            }
        }

        // walls win over neighbours shoving coins through them
        _ = pushOut(b, blocked)

        // 3. Gravity (coins without a coin underneath fall), selling, sleeping
        let supportR2 = (minD * 1.05) * (minD * 1.05)
        var stillAwake = [Int]()
        stillAwake.reserveCapacity(awake.count)
        var idx = 0
        while idx < awake.count {
            let i = awake[idx]; idx += 1
            guard state[i] == .awake else { continue }
            var support: Float = 0
            let (gx, gy) = gridIndex(px[i], py[i])
            for cy in max(0, gy - 1)...min(gRows - 1, gy + 1) {
                for cx in max(0, gx - 1)...min(gCols - 1, gx + 1) {
                    var j = head[cy * gCols + cx]
                    while j >= 0 {
                        if j != i && solid(j) {
                            let dx = px[j] - px[i], dy = py[j] - py[i]
                            if dx * dx + dy * dy < supportR2 {
                                if ph[j] < ph[i] - layer * 0.5 {
                                    support = max(support, ph[j] + layer)
                                } else if ph[j] > ph[i] + layer * 0.5 && state[j] != .awake {
                                    wake(j)   // a coin resting on this one must be able to fall
                                }
                            }
                        }
                        j = nextIdx[j]
                    }
                }
            }
            var falling = false
            if ph[i] > support + 0.001 {
                ph[i] = max(support, ph[i] - 2.2 * dt)
                touch(i)
                falling = true
            }

            var selling = false
            for f in fillers where px[i] > f.0 && px[i] < f.0 + f.2 && py[i] > f.1 && py[i] < f.1 + f.3 {
                selling = true
                break
            }
            if selling {
                state[i] = .selling
                sellT[i] = 0
                animating.append(i)
                continue
            }
            // Settle once the coin has stopped getting anywhere, even if it still jitters in place
            // (lastX/lastY hold where it was when it last made real progress).
            let mv = abs(px[i] - lastX[i]) + abs(py[i] - lastY[i])
            if mv > 0.04 || falling {
                still[i] = 0
                lastX[i] = px[i]; lastY[i] = py[i]
            } else {
                still[i] &+= 1
            }
            if still[i] > 25 { state[i] = .asleep; lastX[i] = px[i]; lastY[i] = py[i] } else { stillAwake.append(i) }
        }
        awake = stillAwake

        // 4. Selling (sink + shrink) and growing (respawn pop-in) animations
        var keep = [Int]()
        for i in animating {
            if state[i] == .selling {
                sellT[i] += dt * 2.5
                ph[i] -= dt * 0.5
                scale[i] = max(0.05, 1 - sellT[i] * 0.9)
                touch(i)
                if sellT[i] >= 1 {
                    state[i] = .dead
                    deadCount += 1
                    sold(value[i], px[i], py[i])
                } else { keep.append(i) }
            } else if state[i] == .growing {
                scale[i] = min(1, scale[i] + dt * 3)
                touch(i)
                if scale[i] >= 1 { state[i] = .asleep } else { keep.append(i) }
            }
        }
        animating = keep

        if deadCount > 400 { compact() }
        return contacts
    }

    /// Add a coin that falls (from the end of a belt).
    func drop(_ x: Float, _ y: Float, h: Float, value v: Float) {
        add(x, y, h: h, value: v, grow: false)
        wake(count - 1)
    }

    /// Remove every coin (new game).
    func reset() {
        px.removeAll(); py.removeAll(); ph.removeAll(); lastX.removeAll(); lastY.removeAll()
        tiltX.removeAll(); tiltZ.removeAll(); scale.removeAll(); value.removeAll(); sellT.removeAll()
        state.removeAll(); still.removeAll(); chunkOf.removeAll(); press.removeAll(); nextIdx.removeAll()
        awake.removeAll(); animating.removeAll()
        deadCount = 0
        for k in 0..<chunkDirty.count { chunkDirty[k] = true }
    }

    /// Remove a coin from play (it melted into a button).
    func consume(_ i: Int) {
        guard state[i] != .dead else { return }
        state[i] = .dead
        deadCount += 1
        chunkDirty[chunkOf[i]] = true
    }

    /// Drop dead coins from the arrays.
    func compact() {
        var keep = [Int]()
        for i in 0..<count where state[i] != .dead { keep.append(i) }
        func pick<T>(_ a: [T]) -> [T] { keep.map { a[$0] } }
        let wasAnimating = Set(animating)
        var remap = [Int](repeating: -1, count: count)
        for (n, o) in keep.enumerated() { remap[o] = n }
        px = pick(px); py = pick(py); ph = pick(ph); lastX = pick(lastX); lastY = pick(lastY)
        tiltX = pick(tiltX); tiltZ = pick(tiltZ); scale = pick(scale); value = pick(value); sellT = pick(sellT)
        state = pick(state); still = pick(still); chunkOf = pick(chunkOf)
        press = pick(press)
        nextIdx = [Int](repeating: -1, count: keep.count)
        awake = awake.compactMap { remap[$0] >= 0 ? remap[$0] : nil }
        animating = wasAnimating.compactMap { remap[$0] >= 0 ? remap[$0] : nil }
        deadCount = 0
        for k in 0..<chunkDirty.count { chunkDirty[k] = true }
    }

    // MARK: Rendering

    func render(material: SCNMaterial) {
        guard chunkDirty.contains(true) else { return }
        for k in 0..<members.count where chunkDirty[k] { members[k].removeAll(keepingCapacity: true) }
        for i in 0..<count where state[i] != .dead && chunkDirty[chunkOf[i]] {
            members[chunkOf[i]].append(i)
        }
        for k in 0..<chunkDirty.count where chunkDirty[k] {
            chunkDirty[k] = false
            buildChunk(k, material: material)
        }
    }

    func buildChunk(_ k: Int, material: SCNMaterial) {
        let list = members[k]
        if list.isEmpty { chunkNodes[k].geometry = nil; return }
        let vPer = tP.count
        var verts = [Float]()
        verts.reserveCapacity(list.count * vPer * 8)
        var idx = [UInt32]()
        idx.reserveCapacity(list.count * tI.count)
        for i in list {
            let q = simd_quatf(angle: tiltX[i], axis: [1, 0, 0]) * simd_quatf(angle: tiltZ[i], axis: [0, 0, 1])
            let s = scale[i]
            let t = SIMD3<Float>(px[i], ph[i] + thick / 2, -py[i])
            let base = UInt32(verts.count / 8)
            for v in 0..<vPer {
                let p = q.act(tP[v] * s) + t
                let n = q.act(tN[v])
                verts += [p.x, p.y, p.z, n.x, n.y, n.z, tUV[v].x, tUV[v].y]
            }
            for ti in tI { idx.append(base + ti) }
        }
        let vData = verts.withUnsafeBufferPointer { Data(buffer: $0) }
        let iData = idx.withUnsafeBufferPointer { Data(buffer: $0) }
        let vc = verts.count / 8
        let stride = 8 * MemoryLayout<Float>.size
        let pos = SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: vc, usesFloatComponents: true,
                                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nrm = SCNGeometrySource(data: vData, semantic: .normal, vectorCount: vc, usesFloatComponents: true,
                                    componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 12, dataStride: stride)
        let uv = SCNGeometrySource(data: vData, semantic: .texcoord, vectorCount: vc, usesFloatComponents: true,
                                   componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 24, dataStride: stride)
        let el = SCNGeometryElement(data: iData, primitiveType: .triangles, primitiveCount: idx.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [pos, nrm, uv], elements: [el])
        g.materials = [material]
        chunkNodes[k].geometry = g
    }
}
