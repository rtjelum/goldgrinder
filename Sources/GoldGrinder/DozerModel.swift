import SceneKit
import simd
import SpriteKit

/// 3D bulldozers modelled after dozer.png (6 levels). Built from primitives so they can be seen from every side.
/// Model faces +z. The plow is a polyline (x, z) that is both drawn and used as the physics wall.
enum DozerModel {

    struct Built {
        let node: SCNNode
        let scale: Float
        let plow: [SIMD2<Float>]     // plow centre line, model units (already scaled)
        let wallHalf: Float          // half the plow thickness (scaled)
        let bodyHalfWidth: Float
        let bodyBack: Float
        let bodyFront: Float
        let exhaust: SIMD3<Float>    // smoke point (scaled, model space)
        let hull: [SIMD3<Float>]     // wall-collision points: (x, z, radius), scaled, model space
        let plowTop: Float           // height of the top of the blade (scaled)
    }

    // MARK: Materials

    // worn-out paint and dull, dirty steel, about half covered in rust
    static func worn(_ c: (CGFloat, CGFloat, CGFloat), seed: UInt64, metal: CGFloat, rough: CGFloat) -> SCNMaterial {
        let m = Art.pbr(Art.wornPaint(c, seed: seed, rust: 0.15), metal: metal, rough: rough)
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        return m
    }
    static let paint = worn((0.12, 0.48, 1.0), seed: 11, metal: 0.1, rough: 0.75)       // worn blue
    static let paintDark = worn((0.08, 0.32, 0.78), seed: 12, metal: 0.15, rough: 0.78)
    static let machineYellow = worn((1.0, 0.76, 0.08), seed: 14, metal: 0.1, rough: 0.75)   // hard hat, crushers
    /// The crushers: dull mustard paint, grimy and heavily rusted
    static let crusherYellow: SCNMaterial = {
        let m = Art.pbr(Art.wornPaint((0.86, 0.66, 0.12), seed: 15, rust: 0.45), metal: 0.15, rough: 0.8)
        m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
        m.diffuse.mipFilter = .linear
        return m
    }()
    static let steel = worn((0.58, 0.58, 0.6), seed: 13, metal: 0.5, rough: 0.65)
    static let rubber = Art.pbr(rgb(0.13, 0.13, 0.15), rough: 0.85)
    static let wheel = Art.pbr(rgb(0.5, 0.52, 0.56), metal: 0.6, rough: 0.4)
    static let zombie = Art.pbr(rgb(0.45, 0.92, 0.25), rough: 0.6)
    static let black = Art.pbr(rgb(0.04, 0.04, 0.05), rough: 0.3)
    static let blueGrey = Art.pbr(rgb(0.28, 0.36, 0.58), metal: 0.5, rough: 0.4)
    static let lamp = Art.pbr(SKColor.white, emit: rgb(1.8, 1.5, 0.9))
    static let glass: SCNMaterial = {
        let m = Art.pbr(rgb(0.15, 0.25, 0.3), metal: 0.3, rough: 0.1, emit: rgb(0.02, 0.06, 0.08))
        m.transparency = 0.45
        return m
    }()
    static let plowMats: [SCNMaterial] = [paint, paintDark, steel].map { m in
        let c = m.copy() as! SCNMaterial
        c.isDoubleSided = true
        return c
    }

    // MARK: Primitive helpers

    @discardableResult
    static func part(_ g: SCNGeometry, _ m: SCNMaterial, _ p: SIMD3<Float>, rot: SIMD3<Float> = .zero,
                     in parent: SCNNode) -> SCNNode {
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = p
        n.simdEulerAngles = rot
        parent.addChildNode(n)
        return n
    }

    @discardableResult
    static func box(_ w: Float, _ h: Float, _ l: Float, _ m: SCNMaterial, _ p: SIMD3<Float>,
                    chamfer: Float = 0.03, rot: SIMD3<Float> = .zero, in parent: SCNNode) -> SCNNode {
        part(SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer)),
             m, p, rot: rot, in: parent)
    }

    @discardableResult
    static func cyl(_ r: Float, _ h: Float, _ m: SCNMaterial, _ p: SIMD3<Float>, rot: SIMD3<Float> = .zero,
                    in parent: SCNNode) -> SCNNode {
        part(SCNCylinder(radius: CGFloat(r), height: CGFloat(h)), m, p, rot: rot, in: parent)
    }

    @discardableResult
    static func ball(_ r: Float, _ m: SCNMaterial, _ p: SIMD3<Float>, in parent: SCNNode) -> SCNNode {
        part(SCNSphere(radius: CGFloat(r)), m, p, in: parent)
    }

    /// A box stretched between two points.
    @discardableResult
    static func beam(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ w: Float, _ m: SCNMaterial, round: Bool = false,
                     in parent: SCNNode) -> SCNNode {
        let len = simd_length(b - a)
        let g: SCNGeometry = round
            ? SCNCapsule(capRadius: CGFloat(w / 2), height: CGFloat(len + w))
            : SCNBox(width: CGFloat(w), height: CGFloat(w), length: CGFloat(len), chamferRadius: CGFloat(w * 0.25))
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.simdPosition = (a + b) / 2
        let axis: SIMD3<Float> = round ? [0, 1, 0] : [0, 0, 1]
        n.simdOrientation = simd_quatf(from: axis, to: simd_normalize(b - a))
        parent.addChildNode(n)
        return n
    }

    // MARK: Plow mesh (a wall extruded along a polyline)

    static func normals(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        // inner normal (pointing into the plow / forward): rotate the left→right tangent by +90°
        (0..<pts.count).map { i in
            let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
            let t = simd_normalize(b - a)
            return SIMD2<Float>(-t.y, t.x)
        }
    }

    static func extrude(_ pts: [SIMD2<Float>], y0: Float, y1: Float, thick: Float,
                        inner: SCNMaterial, outer: SCNMaterial, top: SCNMaterial) -> SCNNode {
        let ns = normals(pts)
        var pos = [SIMD3<Float>](), nrm = [SIMD3<Float>](), uvs = [SIMD2<Float>]()
        var groups: [[UInt32]] = [[], [], []]
        // texture coordinates: u runs along the plow, v up its height
        var along: [Float] = [0]
        for i in 1..<pts.count { along.append(along[i - 1] + simd_distance(pts[i - 1], pts[i])) }
        let span = max(0.001, y1 - y0)
        var uvA: Float = 0, uvB: Float = 0   // u at the start / end of the current segment
        func quad(_ p: [SIMD3<Float>], _ n: [SIMD3<Float>], _ g: Int) {
            let b = UInt32(pos.count)
            pos += p; nrm += n
            for (k, q) in p.enumerated() {
                // inner and top quads start at corners 0 and 3, outer quads at corners 0 and 1
                let atStart = g == 1 ? k < 2 : (k == 0 || k == 3)
                let u = atStart ? uvA : uvB
                uvs.append([u, g == 2 ? Float(k % 2) * 0.1 : (q.y - y0) / span])
            }
            groups[g] += [b, b + 1, b + 2, b, b + 2, b + 3]
        }
        let h = thick / 2
        for i in 0..<(pts.count - 1) {
            let p0 = pts[i], p1 = pts[i + 1], n0 = ns[i], n1 = ns[i + 1]
            uvA = along[i] / (span * 3); uvB = along[i + 1] / (span * 3)
            let i0 = p0 + n0 * h, i1 = p1 + n1 * h, o0 = p0 - n0 * h, o1 = p1 - n1 * h
            let N0 = SIMD3<Float>(n0.x, 0, n0.y), N1 = SIMD3<Float>(n1.x, 0, n1.y)
            quad([[i0.x, y0, i0.y], [i1.x, y0, i1.y], [i1.x, y1, i1.y], [i0.x, y1, i0.y]], [N0, N1, N1, N0], 0)
            quad([[o0.x, y0, o0.y], [o0.x, y1, o0.y], [o1.x, y1, o1.y], [o1.x, y0, o1.y]], [-N0, -N0, -N1, -N1], 1)
            let up = SIMD3<Float>(0, 1, 0)
            quad([[i0.x, y1, i0.y], [i1.x, y1, i1.y], [o1.x, y1, o1.y], [o0.x, y1, o0.y]], [up, up, up, up], 2)
        }
        for (k, i) in [0, pts.count - 1].enumerated() {
            let p = pts[i], n = ns[i]
            let a = p + n * h, b = p - n * h
            let j = k == 0 ? 1 : pts.count - 2
            let d = simd_normalize(p - pts[j])
            let N = SIMD3<Float>(d.x, 0, d.y)
            quad([[a.x, y0, a.y], [a.x, y1, a.y], [b.x, y1, b.y], [b.x, y0, b.y]], [N, N, N, N], 2)
        }
        let vData = pos.withUnsafeBufferPointer { Data(buffer: $0) }
        let nData = nrm.withUnsafeBufferPointer { Data(buffer: $0) }
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vs = SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: pos.count, usesFloatComponents: true,
                                   componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nsrc = SCNGeometrySource(data: nData, semantic: .normal, vectorCount: nrm.count, usesFloatComponents: true,
                                     componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let els = groups.map { g in
            SCNGeometryElement(data: g.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                               primitiveCount: g.count / 3, bytesPerIndex: 4)
        }
        let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
        let uvsrc = SCNGeometrySource(data: uvData, semantic: .texcoord, vectorCount: uvs.count, usesFloatComponents: true,
                                      componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0,
                                      dataStride: MemoryLayout<SIMD2<Float>>.stride)
        let geo = SCNGeometry(sources: [vs, nsrc, uvsrc], elements: els)
        geo.materials = [inner, outer, top]
        return SCNNode(geometry: geo)
    }

    /// Points evenly spaced along a polyline, with their inner normals.
    static func samples(_ pts: [SIMD2<Float>], spacing: Float) -> [(SIMD2<Float>, SIMD2<Float>)] {
        let ns = normals(pts)
        var out: [(SIMD2<Float>, SIMD2<Float>)] = []
        var carry: Float = spacing / 2
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = simd_length(b - a)
            var d = carry
            while d < len {
                let t = d / len
                out.append((a + (b - a) * t, simd_normalize(ns[i] + (ns[i + 1] - ns[i]) * t)))
                d += spacing
            }
            carry = d - len
        }
        return out
    }

    static func arc(cz: Float, r: Float, spanDeg: Float, steps: Int = 16) -> [SIMD2<Float>] {
        let span = spanDeg * .pi / 180
        return (0...steps).map { k in
            let th = -span + 2 * span * Float(k) / Float(steps)
            return SIMD2<Float>(r * sin(th), cz - r * cos(th))
        }
    }

    // MARK: Chassis pieces

    static func tracks(_ n: SCNNode, len: Float, x: Float, wheels: Int) {
        for sx in [-1, 1] as [Float] {
            box(0.28, 0.32, len, rubber, [sx * x, 0.17, 0], chamfer: 0.13, in: n)
            for k in 0..<wheels {
                let z = -len / 2 + 0.2 + (len - 0.4) * Float(k) / Float(wheels - 1)
                cyl(0.12, 0.06, wheel, [sx * (x + 0.15), 0.16, z], rot: [0, 0, .pi / 2], in: n)
                cyl(0.05, 0.07, rubber, [sx * (x + 0.16), 0.16, z], rot: [0, 0, .pi / 2], in: n)
            }
            var z = -len / 2 + 0.1
            while z < len / 2 - 0.05 {   // tread ribs on top
                box(0.3, 0.03, 0.04, black, [sx * x, 0.34, z], chamfer: 0.005, in: n)
                z += 0.12
            }
        }
    }

    static func driver(_ n: SCNNode, at p: SIMD3<Float>) {
        let d = SCNNode()
        d.simdPosition = p
        n.addChildNode(d)
        part(SCNCapsule(capRadius: 0.11, height: 0.34), zombie, [0, 0.17, 0], in: d)
        ball(0.13, zombie, [0, 0.43, 0.02], in: d)
        for sx in [-1, 1] as [Float] {
            ball(0.022, black, [sx * 0.045, 0.45, 0.14], in: d)
            beam([sx * 0.11, 0.25, 0.02], [sx * 0.09, 0.13, 0.22], 0.06, zombie, round: true, in: d)
        }
        // hard hat
        let hat = SCNSphere(radius: 0.145)
        let hn = part(hat, machineYellow, [0, 0.5, 0.02], in: d)
        hn.simdScale = [1, 0.75, 1]
        cyl(0.17, 0.02, machineYellow, [0, 0.47, 0.04], in: d)
        box(0.03, 0.05, 0.22, machineYellow, [0, 0.6, 0.02], chamfer: 0.01, in: d)
    }

    static func exhaust(_ n: SCNNode, at p: SIMD3<Float>, chrome: Bool) -> SIMD3<Float> {
        let m = chrome ? steel : blueGrey
        box(0.16, 0.1, 0.16, m, p, in: n)
        cyl(0.045, 0.55, m, p + [0, 0.3, 0], in: n)
        cyl(0.065, 0.24, chrome ? steel : blueGrey, p + [0, 0.42, 0], in: n)
        for k in 0..<4 { ball(0.012, black, p + [0.066, 0.33 + Float(k) * 0.05, 0], in: n) }
        cyl(0.055, 0.05, black, p + [0, 0.6, 0], in: n)
        return p + [0, 0.65, 0]
    }

    // MARK: Levels

    /// `flat`: a straight blade with angled ends (the quarry dozers) instead of the curved claw (the mine dozers).
    static func build(level: Int, flat: Bool = false) -> Built {
        let root = SCNNode()
        let m = SCNNode()
        root.addChildNode(m)
        let scales: [Float] = [1.0, 1.15, 1.3, 1.45, 1.6, 1.8]
        let s = scales[min(level, 5)]
        m.simdScale = [s, s, s]

        let enclosed = level >= 3
        let trackLen: Float = level >= 3 ? 1.5 : 1.4
        tracks(m, len: trackLen, x: 0.47, wheels: level >= 3 ? 5 : 4)

        // body + engine block (the tall block behind the seat)
        box(0.72, 0.2, trackLen - 0.15, paint, [0, 0.42, 0], chamfer: 0.05, in: m)
        if enclosed {
            box(0.7, 0.42, 0.6, paint, [0, 0.72, -0.42], chamfer: 0.1, in: m)
            box(0.55, 0.1, 0.5, paintDark, [0, 0.98, -0.42], chamfer: 0.04, in: m)
        } else {
            box(0.5, 0.62, 0.34, paint, [0, 0.8, -0.48], chamfer: 0.14, in: m)
        }
        box(0.4, 0.16, 0.14, paint, [0, 0.6, 0.3], chamfer: 0.04, in: m)               // dash
        for sx in [-1, 1] as [Float] {                                                   // levers
            cyl(0.012, 0.16, black, [sx * 0.08, 0.72, 0.28], rot: [0.4, 0, 0], in: m)
            ball(0.025, black, [sx * 0.08, 0.8, 0.31], in: m)
        }
        box(0.32, 0.06, 0.3, black, [0, 0.55, -0.1], chamfer: 0.03, in: m)               // seat
        driver(m, at: [0, 0.55, -0.1])
        let smoke = exhaust(m, at: [0.25, 0.58, -0.62], chrome: level == 5)

        if enclosed {
            // cab: pillars, roof and tinted windows
            for (x, z) in [(-0.3, 0.12), (0.3, 0.12), (-0.3, -0.3), (0.3, -0.3)] as [(Float, Float)] {
                box(0.06, 0.72, 0.06, paint, [x, 0.9, z], chamfer: 0.02, in: m)
            }
            box(0.7, 0.07, 0.55, paint, [0, 1.28, -0.09], chamfer: 0.03, in: m)
            box(0.56, 0.06, 0.08, paintDark, [0, 1.33, 0.12], chamfer: 0.02, in: m)
            box(0.56, 0.5, 0.02, glass, [0, 0.98, 0.12], chamfer: 0, in: m)
            for sx in [-1, 1] as [Float] { box(0.02, 0.5, 0.4, glass, [sx * 0.3, 0.98, -0.09], chamfer: 0, in: m) }
        }
        if level == 5 {
            // round glowing lights on the engine, like the LV.6 art
            for sx in [-1, 1] as [Float] {
                cyl(0.11, 0.06, steel, [sx * 0.2, 0.75, -0.73], rot: [.pi / 2, 0, 0], in: m)
                cyl(0.08, 0.07, lamp, [sx * 0.2, 0.75, -0.74], rot: [.pi / 2, 0, 0], in: m)
            }
            cyl(0.18, 0.08, steel, [0.4, 0.75, -0.42], rot: [0, 0, .pi / 2], in: m)       // gear wheel
        }

        // Plow
        var plow: [SIMD2<Float>]
        let height: Float, thick: Float
        let L = min(level, 5)
        height = [0.45, 0.55, 0.55, 0.72, 0.6, 0.82][L]
        thick = [0.06, 0.1, 0.1, 0.14, 0.1, 0.14][L]
        if flat {
            let w: Float = [0.62, 0.74, 0.86, 0.95, 1.0, 1.05][L]
            plow = [[-w * 1.22, 1.38], [-w, 1.0], [0, 1.0], [w, 1.0], [w * 1.22, 1.38]]
        } else {
            switch L {
            case 0: plow = arc(cz: 1.55, r: 0.62, spanDeg: 115)
            case 1: plow = arc(cz: 1.45, r: 0.85, spanDeg: 100)
            case 2: plow = arc(cz: 1.5, r: 0.95, spanDeg: 105)
            case 3: plow = arc(cz: 1.6, r: 1.05, spanDeg: 105)
            case 4: plow = arc(cz: 2.1, r: 1.25, spanDeg: 78)
            default: plow = arc(cz: 1.95, r: 1.15, spanDeg: 100)
            }
        }
        let y0: Float = 0.04
        let innerMat = level == 1 ? plowMats[1] : plowMats[2]
        m.addChildNode(extrude(plow, y0: y0, y1: y0 + height, thick: thick, inner: innerMat, outer: plowMats[0], top: plowMats[0]))
        // painted rims top and bottom
        m.addChildNode(extrude(plow, y0: y0 + height - 0.06, y1: y0 + height + 0.02, thick: thick + 0.05,
                               inner: plowMats[0], outer: plowMats[0], top: plowMats[0]))
        m.addChildNode(extrude(plow, y0: y0, y1: y0 + 0.07, thick: thick + 0.05,
                               inner: plowMats[0], outer: plowMats[0], top: plowMats[0]))

        let back = plow.min { $0.y < $1.y }!.y
        // arms from the chassis to the back of the plow
        for sx in [-1, 1] as [Float] {
            beam([sx * 0.28, 0.4, 0.55], [sx * 0.26, y0 + height * 0.5, back - thick / 2], 0.09, paint, in: m)
            if level >= 3 {   // hydraulic rams
                beam([sx * 0.36, 0.95, 0.05], [sx * 0.34, y0 + height * 0.75, back - thick / 2], 0.07, steel, round: true, in: m)
                beam([sx * 0.36, 0.95, 0.05], [sx * 0.35, 0.86, 0.45], 0.1, paint, round: true, in: m)
            }
        }

        // Plow details per level
        let teethMat = steel
        func teeth(spacing: Float, size: Float) {
            for (p, n) in samples(plow, spacing: spacing) {
                let g = SCNPyramid(width: CGFloat(size), height: CGFloat(size * 1.4), length: CGFloat(size * 0.5))
                g.materials = [teethMat]
                let t = SCNNode(geometry: g)
                t.simdPosition = [p.x + n.x * thick * 0.6, y0 + 0.02, p.y + n.y * thick * 0.6]
                t.simdOrientation = simd_quatf(from: [0, 1, 0], to: simd_normalize([n.x, 0, n.y]))
                m.addChildNode(t)
            }
        }
        func rivets(rows: [Float], spacing: Float) {
            for (p, n) in samples(plow, spacing: spacing) {
                for y in rows {
                    ball(0.022, steel, [p.x - n.x * (thick / 2 + 0.01), y, p.y - n.y * (thick / 2 + 0.01)], in: m)
                }
            }
        }
        switch level {
        case 1:
            rivets(rows: [y0 + 0.12, y0 + height - 0.12], spacing: 0.22)
            for (p, n) in samples(plow, spacing: 0.45) {   // panel seams
                let seam = box(0.04, height - 0.1, 0.03, plowMats[1], [p.x - n.x * (thick / 2 + 0.01), y0 + height / 2, p.y - n.y * (thick / 2 + 0.01)], chamfer: 0.005, in: m)
                seam.simdOrientation = simd_quatf(from: [0, 0, 1], to: simd_normalize([n.x, 0, n.y]))
            }
            for a in [0.7, -0.7] as [Float] {   // X brace on the back
                box(0.7, 0.05, 0.04, plowMats[1], [0, y0 + height / 2, back - thick / 2 - 0.03], chamfer: 0.01, rot: [0, 0, a], in: m)
            }
        case 2 where flat:
            // grille on top + teeth + face plates
            for (p, _) in samples(Array(plow[1...3]), spacing: 0.12) {
                cyl(0.018, 0.28, steel, [p.x, y0 + height + 0.14, p.y], in: m)
            }
            box(plow[3].x * 2, 0.05, 0.05, steel, [0, y0 + height + 0.28, 1.0], chamfer: 0.01, in: m)
            teeth(spacing: 0.3, size: 0.12)
            for x in [-0.55, 0, 0.55] as [Float] { box(0.4, 0.25, 0.02, steel, [x, y0 + 0.2, 1.07], chamfer: 0.01, in: m) }
        case 3 where flat:
            teeth(spacing: 0.32, size: 0.18)
            for x in [-0.6, 0, 0.6] as [Float] { box(0.1, height, 0.08, steel, [x, y0 + height / 2, 1.1], chamfer: 0.02, in: m) }
            rivets(rows: [y0 + height - 0.12], spacing: 0.3)
        case 2:
            teeth(spacing: 0.26, size: 0.12)
            rivets(rows: [y0 + 0.12, y0 + height - 0.12], spacing: 0.25)
        case 3:
            teeth(spacing: 0.28, size: 0.16)
            rivets(rows: [y0 + height - 0.12], spacing: 0.3)
        case 4:
            teeth(spacing: 0.22, size: 0.13)
            rivets(rows: [y0 + 0.15, y0 + height - 0.15], spacing: 0.3)
            for (p, n) in samples(plow, spacing: 0.6) {
                let plate = box(0.35, height - 0.2, 0.015, steel, [p.x + n.x * (thick / 2 + 0.01), y0 + height / 2, p.y + n.y * (thick / 2 + 0.01)], chamfer: 0.01, in: m)
                plate.simdOrientation = simd_quatf(from: [0, 0, 1], to: simd_normalize([n.x, 0, n.y]))
            }
        case 5:
            teeth(spacing: 0.2, size: 0.15)
            rivets(rows: [y0 + 0.15, y0 + height - 0.15], spacing: 0.28)
            for end in [plow.first!, plow.last!] {   // spiked end plates
                box(0.1, height + 0.15, 0.3, steel, [end.x, y0 + height / 2, end.y], chamfer: 0.02, in: m)
                for k in 0..<4 {
                    let sp = SCNPyramid(width: 0.08, height: 0.14, length: 0.08)
                    part(sp, steel, [end.x + (end.x > 0 ? 0.06 : -0.06), y0 + 0.15 + Float(k) * 0.2, end.y],
                         rot: [0, 0, end.x > 0 ? -.pi / 2 : .pi / 2], in: m)
                }
            }
        default:
            break
        }

        m.enumerateHierarchy { n, _ in n.castsShadow = true }
        let scaled = plow.map { $0 * s }
        // Wall collision: chassis corners and edges, plus points all along the plow
        var hull: [SIMD3<Float>] = []
        let hw: Float = 0.62, hb = trackLen / 2
        for (x, z) in [(-hw, -hb), (hw, -hb), (-hw, 0), (hw, 0), (-hw, hb - 0.1), (hw, hb - 0.1), (0, -hb)] as [(Float, Float)] {
            hull.append([x * s, z * s, 0.12 * s])
        }
        for p in samples(plow, spacing: 0.22) { hull.append([p.0.x * s, p.0.y * s, (thick / 2 + 0.04) * s]) }
        for p in [plow.first!, plow.last!] { hull.append([p.x * s, p.y * s, (thick / 2 + 0.04) * s]) }
        return Built(node: root, scale: s, plow: scaled, wallHalf: (thick / 2 + 0.09) * s,
                     bodyHalfWidth: 0.64 * s, bodyBack: trackLen / 2 * s, bodyFront: (back - thick / 2) * s,
                     exhaust: smoke * s, hull: hull, plowTop: (y0 + height) * s)
    }
}
