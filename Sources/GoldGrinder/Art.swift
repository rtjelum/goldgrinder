import SceneKit
import SpriteKit
import CoreText
import ImageIO
import simd

// MARK: - Helpers

func v3(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat) -> SCNVector3 { SCNVector3(x, y, z) }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> SKColor {
    SKColor(red: r, green: g, blue: b, alpha: a)
}

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s ^ (s >> 29)
    }
}

let hudFont = "AvenirNext-Heavy"

/// Materials, textures and small models, built in code (plus the dozer icons in Resources/).
enum Art {

    static func pbr(_ c: Any, metal: CGFloat = 0, rough: CGFloat = 0.6, emit: Any? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = c
        m.metalness.contents = metal
        m.roughness.contents = rough
        if let e = emit { m.emission.contents = e }
        return m
    }

    @discardableResult
    static func box(_ w: CGFloat, _ h: CGFloat, _ l: CGFloat, _ m: SCNMaterial, at p: SCNVector3,
                    chamfer: CGFloat = 0.03, in parent: SCNNode) -> SCNNode {
        let g = SCNBox(width: w, height: h, length: l, chamferRadius: chamfer)
        g.materials = [m]
        let n = SCNNode(geometry: g)
        n.position = p
        parent.addChildNode(n)
        return n
    }

    // MARK: Crystal shards (sharp faceted stone for the walls)

    /// A pointed crystal: an n-sided column with a sharp tip, flat-shaded so every facet catches the light.
    /// Unit size: base radius 1, column height `body`, tip height `tip`.
    static func crystal(sides: Int, body: Float, tip: Float, twist: Float) -> SCNGeometry {
        var pos = [SIMD3<Float>](), nrm = [SIMD3<Float>](), idx = [UInt32]()
        func ring(_ rad: Float, _ y: Float, _ k: Int, _ rot: Float) -> SIMD3<Float> {
            let a = Float(k) / Float(sides) * 2 * .pi + rot
            return [cos(a) * rad, y, sin(a) * rad]
        }
        func face(_ v: [SIMD3<Float>]) {
            let n = simd_normalize(simd_cross(v[1] - v[0], v[2] - v[0]))
            let b = UInt32(pos.count)
            pos += v; nrm += Array(repeating: n, count: v.count)
            for k in 1..<(v.count - 1) { idx += [b, b + UInt32(k), b + UInt32(k + 1)] }
        }
        let apex = SIMD3<Float>(0.08, body + tip, -0.05)
        for k in 0..<sides {
            let a0 = ring(1, 0, k, 0), a1 = ring(1, 0, k + 1, 0)
            let b0 = ring(0.82, body, k, twist), b1 = ring(0.82, body, k + 1, twist)
            face([a0, b0, b1, a1])
            face([b0, apex, b1])
        }
        let vData = pos.withUnsafeBufferPointer { Data(buffer: $0) }
        let nData = nrm.withUnsafeBufferPointer { Data(buffer: $0) }
        let st = MemoryLayout<SIMD3<Float>>.stride
        let g = SCNGeometry(sources: [
            SCNGeometrySource(data: vData, semantic: .vertex, vectorCount: pos.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: st),
            SCNGeometrySource(data: nData, semantic: .normal, vectorCount: nrm.count, usesFloatComponents: true,
                              componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: st),
        ], elements: [SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                         primitiveCount: idx.count / 3, bytesPerIndex: 4)])
        g.materials = [SCNMaterial()]
        return g
    }

    // MARK: Coins

    /// Coin size (CoinField and the flying coins share it).
    static let coinRadius: CGFloat = 0.16
    static let coinThick: CGFloat = 0.09

    /// Coin face relief as a height map: raised rim, beaded border, laurel wreath and a stepped star.
    /// The coin's edge sits at 0.47 of the texture's width (matching the coin mesh's UVs).
    static let coinHeight: (size: Int, h: [Float]) = {
        let s = 256
        let c = CGFloat(s) / 2, R = CGFloat(s) * 0.47
        let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        func gray(_ g: CGFloat) { ctx.setFillColor(gray: g, alpha: 1); ctx.setStrokeColor(gray: g, alpha: 1) }
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        gray(0.85); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        gray(1); disc(c, c, R * 0.97)                    // rim
        gray(0.25); disc(c, c, R * 0.85)                 // field
        gray(0.7)                                        // beaded border
        for i in 0..<44 {
            let a = CGFloat(i) / 44 * 2 * .pi
            disc(c + cos(a) * R * 0.78, c + sin(a) * R * 0.78, R * 0.03)
        }
        // laurel wreath: two branches curving up from the bottom
        for side in [-1.0, 1.0] as [CGFloat] {
            for k in 0..<9 {
                let a = -.pi / 2 + side * (0.25 + CGFloat(k) * 0.27)
                let rr = R * 0.6
                ctx.saveGState()
                ctx.translateBy(x: c + cos(a) * rr, y: c + sin(a) * rr)
                ctx.rotate(by: a + side * .pi / 2 + side * 0.5)
                for (dx, g) in [(-R * 0.055, 0.62), (R * 0.055, 0.72)] as [(CGFloat, CGFloat)] {
                    gray(g)
                    ctx.fillEllipse(in: CGRect(x: dx - R * 0.045, y: -R * 0.03 + (dx > 0 ? R * 0.035 : 0),
                                               width: R * 0.09, height: R * 0.13))
                }
                ctx.restoreGState()
            }
        }
        // stepped star: blurred, the steps become a smooth pyramid with sharp ridges
        for k in 0..<7 {
            let sc = 1 - CGFloat(k) * 0.14
            let path = CGMutablePath()
            for i in 0..<10 {
                let a = CGFloat(i) * .pi / 5 + .pi / 2
                let rr = (i % 2 == 0 ? R * 0.36 : R * 0.15) * sc
                let p = CGPoint(x: c + cos(a) * rr, y: c + sin(a) * rr)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
            gray(0.45 + CGFloat(k) * 0.08)
            ctx.addPath(path); ctx.fillPath()
        }
        // read back (row 0 = top of the image) and soften with a small box blur
        let raw = ctx.data!.bindMemory(to: UInt8.self, capacity: s * s)
        var h = (0..<(s * s)).map { Float(raw[$0]) / 255 }
        for _ in 0..<2 {
            var o = h
            for y in 1..<(s - 1) {
                for x in 1..<(s - 1) {
                    var sum: Float = 0
                    for dy in -1...1 { for dx in -1...1 { sum += h[(y + dy) * s + x + dx] } }
                    o[y * s + x] = sum / 9
                }
            }
            h = o
        }
        return (s, h)
    }()

    /// Turn a height map into a gold picture with the light baked in (from the upper left).
    static func bakedRelief(_ s: Int, _ h: [Float], strength: Float) -> CGImage {
        var px = [UInt8](repeating: 255, count: s * s * 4)
        let light = simd_normalize(SIMD3<Float>(-0.5, 0.6, 0.65))
        func at(_ x: Int, _ y: Int) -> Float { h[max(0, min(s - 1, y)) * s + max(0, min(s - 1, x))] }
        for y in 0..<s {
            for x in 0..<s {
                let i = y * s + x
                let dx = (at(x + 1, y) - at(x - 1, y)) * strength
                let dy = (at(x, y - 1) - at(x, y + 1)) * strength   // image up = +y
                let n = simd_normalize(SIMD3<Float>(-dx, -dy, 1))
                let col = goldColor(h[i])
                let shade = 0.55 + 0.6 * max(0, simd_dot(n, light)) + 0.5 * pow(max(0, n.y * 0.7 + n.z * 0.3), 30)
                for k in 0..<3 { px[i * 4 + k] = UInt8(min(255, col[k] * shade * 255)) }
            }
        }
        let ctx = context(s, s)
        px.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: px.count) }
        return ctx.makeImage()!
    }

    static func goldColor(_ v: Float) -> SIMD3<Float> {
        // deep gold in the recesses, bright yellow gold on the raised parts
        let lo = SIMD3<Float>(0.9, 0.62, 0.16), hi = SIMD3<Float>(1.0, 0.88, 0.45)
        return simd_mix(lo, hi, SIMD3<Float>(repeating: min(1, max(0, v))))
    }

    static let coinTexture = bakedRelief(coinHeight.size, coinHeight.h, strength: 4)

    /// Coin picture for the HUD and signs (face with the light baked in), cut out round.
    static let coinFace: CGImage = {
        let s = 128
        let ctx = context(s, s)
        let r = CGFloat(s) / 2
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: 2 * r - 2, height: 2 * r - 2))
        ctx.clip()
        // the texture's coin edge is at 0.47, so draw it a bit larger to fill the circle
        let big = CGFloat(s) / 0.94
        ctx.draw(coinTexture, in: CGRect(x: r - big / 2, y: r - big / 2, width: big, height: big))
        return ctx.makeImage()!
    }()

    /// Coins use one picture with the relief's light baked in (no normal or roughness maps): cheap to draw.
    static let coinMat: SCNMaterial = {
        let m = pbr(coinTexture, metal: 0.85, rough: 0.3)
        m.emission.contents = coinTexture
        m.emission.intensity = 0.2
        m.diffuse.mipFilter = .linear
        return m
    }()

    /// Single coin for flying effects.
    static let coinGeo: SCNGeometry = {
        let g = SCNCylinder(radius: coinRadius, height: coinThick)
        g.radialSegmentCount = 12
        let side = pbr(rgb(0.95, 0.68, 0.2), metal: 0.85, rough: 0.3, emit: rgb(0.2, 0.13, 0.02))
        let face = coinMat.copy() as! SCNMaterial
        for p in [face.diffuse, face.emission] {
            // SCNCylinder caps map the whole texture onto the disc; ours has the edge at 0.47
            p.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(0.94, 0.94, 1), SCNMatrix4MakeTranslation(0.03, 0.03, 0))
        }
        g.materials = [side, face, face]
        return g
    }()

    // MARK: Gold nuggets

    /// A rough-cut gold nugget: a lumpy, faceted rock with a flat bottom, flat-shaded so every facet catches
    /// the light. Unit size: x and z within about ±1, height about 1.
    static func nugget(seed: UInt64) -> SCNGeometry {
        var rng = SeededRNG(s: seed)
        func r(_ a: Float, _ b: Float) -> Float { Float.random(in: a...b, using: &rng) }
        let lon = 7
        // rings from the bottom up: (height, radius)
        let rings: [(Float, Float)] = [(0, 0.85), (0.35, 1.0), (0.7, 0.78), (0.95, 0.4)]
        var grid: [[SIMD3<Float>]] = []
        let twist = r(0, 1)
        for (k, ring) in rings.enumerated() {
            var row: [SIMD3<Float>] = []
            for i in 0..<lon {
                let a = (Float(i) + twist + r(-0.25, 0.25) + Float(k) * 0.5) / Float(lon) * 2 * .pi
                let rad = ring.1 * r(0.72, 1.12)
                let y = k == 0 ? 0 : ring.0 + r(-0.08, 0.08)
                row.append([cos(a) * rad, y, sin(a) * rad])
            }
            grid.append(row)
        }
        let top = SIMD3<Float>(r(-0.15, 0.15), 1.05 + r(-0.1, 0.05), r(-0.15, 0.15))
        let bottom = SIMD3<Float>(0, 0, 0)
        var pos = [SIMD3<Float>](), nrm = [SIMD3<Float>]()
        let mid = SIMD3<Float>(0, 0.45, 0)
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            var n = simd_normalize(simd_cross(b - a, c - a))
            var v = [a, b, c]
            if simd_dot(n, (a + b + c) / 3 - mid) < 0 { n = -n; v = [a, c, b] }   // keep faces pointing outward
            pos += v; nrm += [n, n, n]
        }
        for k in 0..<(grid.count - 1) {
            for i in 0..<lon {
                let a = grid[k][i], b = grid[k][(i + 1) % lon], c = grid[k + 1][i], d = grid[k + 1][(i + 1) % lon]
                tri(a, b, d); tri(a, d, c)
            }
        }
        for i in 0..<lon {
            tri(grid[grid.count - 1][i], grid[grid.count - 1][(i + 1) % lon], top)
            tri(grid[0][i], bottom, grid[0][(i + 1) % lon])
        }
        let idx = (0..<UInt32(pos.count)).map { $0 }
        let st = MemoryLayout<SIMD3<Float>>.stride
        let g = SCNGeometry(sources: [
            SCNGeometrySource(data: pos.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex, vectorCount: pos.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: st),
            SCNGeometrySource(data: nrm.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal, vectorCount: nrm.count,
                              usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: st),
        ], elements: [SCNGeometryElement(data: idx.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                         primitiveCount: idx.count / 3, bytesPerIndex: 4)])
        return g
    }

    // MARK: Twinkles

    /// A four-pointed star glint with a soft glow.
    static let twinkleImage: CGImage = {
        let s = 128
        let ctx = context(s, s)
        let c = CGFloat(s) / 2
        let colors = [CGColor(red: 1, green: 1, blue: 0.9, alpha: 1), CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 0.35), CGColor(red: 1, green: 0.85, blue: 0.4, alpha: 0)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.25, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: c, y: c), startRadius: 0,
                               endCenter: CGPoint(x: c, y: c), endRadius: c * 0.5, options: [])
        func spike(_ len: CGFloat, _ w: CGFloat, _ rot: CGFloat, _ alpha: CGFloat) {
            ctx.saveGState()
            ctx.translateBy(x: c, y: c)
            ctx.rotate(by: rot)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -len, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: w), control: CGPoint(x: -w, y: w * 0.2))
            p.addQuadCurve(to: CGPoint(x: len, y: 0), control: CGPoint(x: w, y: w * 0.2))
            p.addQuadCurve(to: CGPoint(x: 0, y: -w), control: CGPoint(x: w, y: -w * 0.2))
            p.addQuadCurve(to: CGPoint(x: -len, y: 0), control: CGPoint(x: -w, y: -w * 0.2))
            ctx.addPath(p)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.92, alpha: alpha))
            ctx.fillPath()
            ctx.restoreGState()
        }
        spike(c * 0.98, c * 0.15, 0, 1)
        spike(c * 0.98, c * 0.15, .pi / 2, 1)
        spike(c * 0.55, c * 0.09, .pi / 4, 0.8)
        spike(c * 0.55, c * 0.09, -.pi / 4, 0.8)
        return ctx.makeImage()!
    }()

    static let twinkleMat: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = twinkleImage
        m.blendMode = .alpha   // white on gold stands out better than additive
        m.writesToDepthBuffer = false
        m.isDoubleSided = true
        return m
    }()

    // MARK: Particles

    static let dotImage: CGImage = {
        let s = 64
        let ctx = context(s, s)
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
        ctx.drawRadialGradient(grad, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                               endCenter: CGPoint(x: 32, y: 32), endRadius: 32, options: [])
        return ctx.makeImage()!
    }()

    static func particles(color: SKColor, size: CGFloat, life: CGFloat, speed: CGFloat,
                          spread: CGFloat, gravity: CGFloat, additive: Bool) -> SCNParticleSystem {
        let p = SCNParticleSystem()
        p.birthRate = 0
        p.particleLifeSpan = life
        p.particleLifeSpanVariation = life * 0.4
        p.particleSize = size
        p.particleSizeVariation = size * 0.4
        p.particleColor = color
        p.particleImage = dotImage
        p.emitterShape = SCNSphere(radius: 0.3)
        p.particleVelocity = speed
        p.particleVelocityVariation = speed * 0.5
        p.spreadingAngle = spread
        p.emittingDirection = v3(0, 1, 0)
        p.acceleration = v3(0, gravity, 0)
        p.blendMode = additive ? .additive : .alpha
        p.isLightingEnabled = false
        let fade = CAKeyframeAnimation()
        fade.values = [0.9, 0.9, 0]
        fade.keyTimes = [0, 0.6, 1]
        fade.duration = 1
        p.propertyControllers = [.opacity: SCNParticlePropertyController(animation: fade)]
        return p
    }

    // MARK: Textures

    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func text(_ ctx: CGContext, _ s: String, size: CGFloat, color: CGColor, at p: CGPoint, center: Bool = true,
                     maxWidth: CGFloat? = nil) {
        func make(_ sz: CGFloat) -> CTLine {
            let font = CTFontCreateWithName(hudFont as CFString, sz, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
        }
        var line = make(size)
        var b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if let mw = maxWidth, b.width > mw {   // shrink to fit
            line = make(size * mw / b.width)
            b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        }
        ctx.textPosition = CGPoint(x: p.x - (center ? b.width / 2 : 0) - b.minX, y: p.y - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }

    static func coinIcon(_ ctx: CGContext, at c: CGPoint, r: CGFloat) {
        ctx.draw(coinFace, in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    static func lockIcon(_ ctx: CGContext, in rect: CGRect) {
        let white = CGColor(red: 0.95, green: 0.92, blue: 1, alpha: 1)
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.6)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.setFillColor(white); ctx.fillPath()
        ctx.setStrokeColor(white); ctx.setLineWidth(rect.width * 0.14)
        let r = rect.width * 0.3
        ctx.addArc(center: CGPoint(x: rect.midX, y: body.maxY), radius: r, startAngle: 0, endAngle: .pi, clockwise: false)
        ctx.strokePath()
        ctx.setFillColor(CGColor(red: 0.22, green: 0.14, blue: 0.3, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: rect.midX - 9, y: body.midY - 9, width: 18, height: 18))
    }

    /// Small floating sign above a button: icon, name and "have / need".
    static func signImage(icon: CGImage?, title: String, have: String, need: String, full: Bool) -> CGImage {
        let w = 440, h = 200
        let ctx = context(w, h)
        let rect = CGRect(x: 6, y: 6, width: w - 12, height: h - 12)
        let path = CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(full ? CGColor(red: 0.55, green: 0.32, blue: 0.05, alpha: 0.95) : CGColor(red: 0.2, green: 0.12, blue: 0.3, alpha: 0.92))
        ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 0.78, blue: 0.25, alpha: 1)); ctx.setLineWidth(8); ctx.strokePath()
        if let icon = icon {
            let maxW: CGFloat = 150, maxH: CGFloat = 130
            let sc = min(maxW / CGFloat(icon.width), maxH / CGFloat(icon.height))
            let iw = CGFloat(icon.width) * sc, ih = CGFloat(icon.height) * sc
            ctx.draw(icon, in: CGRect(x: 20 + (maxW - iw) / 2, y: 100 - ih / 2, width: iw, height: ih))
        } else {
            lockIcon(ctx, in: CGRect(x: 55, y: 45, width: 80, height: 100))
        }
        text(ctx, title, size: 34, color: CGColor(red: 1, green: 0.82, blue: 0.4, alpha: 1), at: CGPoint(x: 300, y: 150))
        coinIcon(ctx, at: CGPoint(x: 196, y: 70), r: 22)
        text(ctx, "\(have)/\(need)", size: 56,
             color: CGColor(red: 0.97, green: 0.95, blue: 1, alpha: 1), at: CGPoint(x: 226, y: 70), center: false, maxWidth: 196)
        return ctx.makeImage()!
    }

    /// Gold trophy cup for the victory button.
    static let trophyImage: CGImage = {
        let ctx = context(200, 200)
        let gold = CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1), dark = CGColor(red: 0.75, green: 0.48, blue: 0.05, alpha: 1)
        ctx.setLineWidth(14); ctx.setStrokeColor(dark)
        ctx.strokeEllipse(in: CGRect(x: 18, y: 100, width: 60, height: 60))     // handles
        ctx.strokeEllipse(in: CGRect(x: 122, y: 100, width: 60, height: 60))
        let cup = CGMutablePath()
        cup.move(to: CGPoint(x: 42, y: 175)); cup.addLine(to: CGPoint(x: 158, y: 175))
        cup.addQuadCurve(to: CGPoint(x: 100, y: 82), control: CGPoint(x: 160, y: 92))
        cup.addQuadCurve(to: CGPoint(x: 42, y: 175), control: CGPoint(x: 40, y: 92))
        ctx.addPath(cup); ctx.setFillColor(gold); ctx.fillPath()
        ctx.setFillColor(dark)
        ctx.fill(CGRect(x: 88, y: 50, width: 24, height: 38))                    // stem
        ctx.fill(CGRect(x: 58, y: 24, width: 84, height: 28))                    // base
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.85, alpha: 0.6))
        ctx.fillEllipse(in: CGRect(x: 62, y: 130, width: 22, height: 34))        // shine
        return ctx.makeImage()!
    }()

    /// Rubber conveyor belt with cleats (tiles along the belt).
    static let beltImage: CGImage = {
        let ctx = context(128, 128)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        ctx.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.34, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 52, width: 128, height: 24))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 70, width: 128, height: 6))
        return ctx.makeImage()!
    }()

    /// Sign over a belt's hopper: how much gold is left.
    static func supplyImage(left: Int, total: Int) -> CGImage {
        let w = 400, h = 190
        let ctx = context(w, h)
        let rect = CGRect(x: 6, y: 6, width: w - 12, height: h - 12)
        let path = CGPath(roundedRect: rect, cornerWidth: 36, cornerHeight: 36, transform: nil)
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.2, green: 0.12, blue: 0.3, alpha: 0.92)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 0.78, blue: 0.25, alpha: 1)); ctx.setLineWidth(8); ctx.strokePath()
        text(ctx, "GOLD LEFT", size: 34, color: CGColor(red: 1, green: 0.82, blue: 0.4, alpha: 1), at: CGPoint(x: 200, y: 145))
        if left > 0 {
            coinIcon(ctx, at: CGPoint(x: 110, y: 72), r: 30)
            text(ctx, "\(left)", size: 70, color: CGColor(red: 0.97, green: 0.95, blue: 1, alpha: 1), at: CGPoint(x: 152, y: 72), center: false, maxWidth: 220)
        } else {
            text(ctx, "EMPTY", size: 70, color: CGColor(red: 1, green: 0.4, blue: 0.4, alpha: 1), at: CGPoint(x: 200, y: 72))
        }
        // how full the belt still is
        let bar = CGRect(x: 30, y: 22, width: 340, height: 12)
        ctx.setFillColor(CGColor(red: 0.08, green: 0.05, blue: 0.12, alpha: 1)); ctx.fill(bar)
        ctx.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * CGFloat(left) / CGFloat(max(1, total)), height: bar.height))
        return ctx.makeImage()!
    }

    /// Flat ring around a button that fills up clockwise as coins pile on.
    /// `inner`: where the ring starts, as a fraction of the image's half-width (it ends near the edge).
    static func ringImage(progress: CGFloat, color: CGColor, inner: CGFloat = 0.78) -> CGImage {
        let s = 256
        let ctx = context(s, s)
        let c = CGPoint(x: s / 2, y: s / 2)
        let half = CGFloat(s) / 2
        let r0 = half * inner, r1 = half * 0.97
        let mid = (r0 + r1) / 2, width = r1 - r0
        ctx.setLineWidth(width)
        ctx.setStrokeColor(CGColor(red: 0.08, green: 0.05, blue: 0.12, alpha: 0.85))
        ctx.addArc(center: c, radius: mid, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        if progress > 0 {
            ctx.setLineWidth(width * 0.8)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color)
            ctx.addArc(center: c, radius: mid, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * min(1, progress), clockwise: true)
            ctx.strokePath()
        }
        // tick marks
        ctx.setLineCap(.butt)
        ctx.setLineWidth(2)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        for k in 0..<24 {
            let a = CGFloat(k) / 24 * 2 * .pi
            ctx.move(to: CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
        }
        ctx.strokePath()
        return ctx.makeImage()!
    }

    static func floorImage(base: (CGFloat, CGFloat, CGFloat), seed: UInt64) -> CGImage {
        var rng = SeededRNG(s: seed)
        let s = 512
        let ctx = context(s, s)
        ctx.setFillColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        for _ in 0..<1100 {
            let x = CGFloat.random(in: 0...512, using: &rng), y = CGFloat.random(in: 0...512, using: &rng)
            let r = CGFloat.random(in: 2...12, using: &rng)
            let k = CGFloat.random(in: -0.05...0.04, using: &rng)
            ctx.setFillColor(CGColor(red: base.0 + k, green: base.1 + k, blue: base.2 + k * 1.2, alpha: 0.7))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r * 1.5, height: r))
        }
        return ctx.makeImage()!
    }

    /// Tileable cobblestones: rounded stones of varied colour, lit from the upper left, in dark grout.
    static func cobbleImage(seed: UInt64, stone: (CGFloat, CGFloat, CGFloat) = (0.42, 0.38, 0.45),
                            grout: (CGFloat, CGFloat, CGFloat) = (0.22, 0.19, 0.24), count: Int = 6) -> CGImage {
        var rng = SeededRNG(s: seed)
        func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }
        let s: CGFloat = 512, n = count
        let cell = s / CGFloat(n)
        let ctx = context(Int(s), Int(s))
        ctx.setFillColor(CGColor(red: grout.0, green: grout.1, blue: grout.2, alpha: 1))   // grout
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        for row in 0..<n {
            for col in 0..<n {
                // rows are offset by half a stone, like laid cobbles
                let cx = (CGFloat(col) + 0.5 + (row % 2 == 0 ? 0 : 0.5)) * cell + r(-7, 7)
                let cy = (CGFloat(row) + 0.5) * cell + r(-6, 6)
                let squash = r(0.85, 1.12)
                // irregular rounded outline
                var pts: [CGPoint] = []
                let k = 9
                for i in 0..<k {
                    let a = CGFloat(i) / CGFloat(k) * 2 * .pi + r(-0.15, 0.15)
                    let rad = cell * r(0.43, 0.5)
                    pts.append(CGPoint(x: cos(a) * rad * squash, y: sin(a) * rad / squash))
                }
                func outline(_ scale: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> CGPath {
                    let p = CGMutablePath()
                    func at(_ i: Int) -> CGPoint { let q = pts[(i + k) % k]; return CGPoint(x: q.x * scale + dx, y: q.y * scale + dy) }
                    func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
                    p.move(to: mid(at(0), at(1)))
                    for i in 1...k { p.addQuadCurve(to: mid(at(i), at(i + 1)), control: at(i)) }
                    p.closeSubpath()
                    return p
                }
                let tone = r(-0.06, 0.05)
                let base = (stone.0 + tone + r(-0.03, 0.03), stone.1 + tone + r(-0.02, 0.02), stone.2 + tone + r(-0.03, 0.03))
                // draw at the wrap-around copies too so the tile repeats seamlessly
                for ox in [-s, 0, s] {
                    for oy in [-s, 0, s] {
                        let x = cx + ox, y = cy + oy
                        guard x > -cell, x < s + cell, y > -cell, y < s + cell else { continue }
                        ctx.addPath(outline(1, x + 2, y - 3))       // shadow side
                        ctx.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.14, alpha: 0.6)); ctx.fillPath()
                        ctx.addPath(outline(1, x, y))
                        ctx.setFillColor(CGColor(red: base.0 * 0.85, green: base.1 * 0.85, blue: base.2 * 0.87, alpha: 1)); ctx.fillPath()
                        ctx.addPath(outline(0.86, x - 2, y + 2.5))  // lit top
                        ctx.setFillColor(CGColor(red: base.0, green: base.1, blue: base.2, alpha: 1)); ctx.fillPath()
                        ctx.addPath(outline(0.45, x - 5, y + 6))    // soft shine
                        ctx.setFillColor(CGColor(red: 1, green: 0.95, blue: 1, alpha: 0.07)); ctx.fillPath()
                    }
                }
            }
        }
        // grit and wear across everything
        for _ in 0..<1400 {
            let x = r(0, s), y = r(0, s), rr = r(0.6, 2.2)
            let dark = r(0, 1) < 0.6
            ctx.setFillColor(dark ? CGColor(red: 0.12, green: 0.1, blue: 0.14, alpha: r(0.15, 0.4))
                                  : CGColor(red: 0.8, green: 0.75, blue: 0.82, alpha: r(0.08, 0.2)))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: rr, height: rr))
        }
        return ctx.makeImage()!
    }

    /// Worn paint: a base colour with grime, chipped spots showing bare metal, scratches, rust streaks
    /// and big rust patches covering about `rust` of the surface (0...1).
    static func wornPaint(_ c: (CGFloat, CGFloat, CGFloat), seed: UInt64, rust: CGFloat = 0) -> CGImage {
        var rng = SeededRNG(s: seed)
        func r(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b, using: &rng) }
        let s: CGFloat = 256
        let ctx = context(Int(s), Int(s))
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        // faded / blotchy paint
        for _ in 0..<60 {
            let x = r(0, s), y = r(0, s), rr = r(10, 40), k = r(-0.08, 0.06)
            ctx.setFillColor(CGColor(red: c.0 + k, green: c.1 + k, blue: c.2 + k * 0.5, alpha: 0.35))
            ctx.fillEllipse(in: CGRect(x: x - rr, y: y - rr, width: 2 * rr, height: 2 * rr * r(0.5, 1)))
        }
        // grime, heavier towards the bottom
        for _ in 0..<40 {
            let y = s * pow(r(0, 1), 2.2), x = r(0, s), rr = r(4, 20)
            ctx.setFillColor(CGColor(red: 0.35, green: 0.26, blue: 0.16, alpha: r(0.05, 0.14)))
            ctx.fillEllipse(in: CGRect(x: x - rr, y: y - rr * 0.6, width: 2 * rr, height: 1.2 * rr))
        }
        // rust patches: big merged clusters of mottled rust, fading into a brown stain at the edges,
        // more of them low down
        let rustColors: [(CGFloat, CGFloat, CGFloat)] = [(0.38, 0.18, 0.07), (0.48, 0.23, 0.09), (0.55, 0.28, 0.1), (0.42, 0.2, 0.09)]
        let clusters = Int(rust * 10)
        if rust > 0 {
            // overall tired, brownish paint
            ctx.setFillColor(CGColor(red: 0.45, green: 0.3, blue: 0.15, alpha: rust * 0.35))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        }
        for _ in 0..<clusters {
            let cx = r(0, s), cy = s * pow(r(0, 1), 1.5), spread = r(30, 60)
            var blobs: [(CGFloat, CGFloat, CGFloat, Int)] = []
            for _ in 0..<16 { blobs.append((cx + r(-spread, spread), cy + r(-spread, spread) * 0.8, r(12, 28), Int(r(0, 3.99)))) }
            // soft stain halo, then the rust
            for b in blobs {
                let colors = [CGColor(red: 0.42, green: 0.22, blue: 0.08, alpha: 0.5), CGColor(red: 0.42, green: 0.22, blue: 0.08, alpha: 0)] as CFArray
                let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: b.0, y: b.1), startRadius: b.2 * 0.8,
                                       endCenter: CGPoint(x: b.0, y: b.1), endRadius: b.2 * 1.6, options: [])
            }
            for b in blobs {
                let col = rustColors[b.3]
                ctx.setFillColor(CGColor(red: col.0, green: col.1, blue: col.2, alpha: 0.9))
                ctx.fillEllipse(in: CGRect(x: b.0 - b.2, y: b.1 - b.2 * 0.85, width: 2 * b.2, height: 1.7 * b.2))
            }
            // pitting and flecks inside the patch
            for _ in 0..<80 {
                let x = cx + r(-spread, spread), y = cy + r(-spread, spread) * 0.8, rr = r(1, 3.5)
                ctx.setFillColor(r(0, 1) < 0.6 ? CGColor(red: 0.24, green: 0.11, blue: 0.04, alpha: 0.5)
                                              : CGColor(red: 0.7, green: 0.38, blue: 0.14, alpha: 0.45))
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: rr, height: rr))
            }
        }
        // rust streaks running down
        for _ in 0..<(3 + Int(rust * 8)) {
            let x = r(0, s), top = r(s * 0.3, s), len = r(20, 70), w = r(2, 5)
            let colors = [CGColor(red: 0.55, green: 0.25, blue: 0.08, alpha: 0.55), CGColor(red: 0.55, green: 0.25, blue: 0.08, alpha: 0)] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x, y: top - len, width: w, height: len))
            ctx.drawLinearGradient(g, start: CGPoint(x: x, y: top), end: CGPoint(x: x, y: top - len), options: [])
            ctx.restoreGState()
        }
        // chipped paint: bare dark metal with a rusty edge
        for _ in 0..<9 {
            let x = r(0, s), y = r(0, s), rr = r(4, 10)
            let p = CGMutablePath()
            for i in 0..<7 {
                let a = CGFloat(i) / 7 * 2 * .pi
                let q = CGPoint(x: x + cos(a) * rr * r(0.5, 1.3), y: y + sin(a) * rr * r(0.5, 1.3))
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
            ctx.addPath(p); ctx.setStrokeColor(CGColor(red: 0.5, green: 0.27, blue: 0.1, alpha: 0.8)); ctx.setLineWidth(2); ctx.strokePath()
            ctx.addPath(p); ctx.setFillColor(CGColor(red: 0.4, green: 0.38, blue: 0.37, alpha: 1)); ctx.fillPath()
        }
        // scratches
        ctx.setLineCap(.round)
        for _ in 0..<12 {
            let x = r(0, s), y = r(0, s), a = r(0, .pi), len = r(15, 50)
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x + cos(a) * len, y: y + sin(a) * len))
            ctx.setStrokeColor(r(0, 1) < 0.5 ? CGColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 0.35)
                                             : CGColor(red: 0.3, green: 0.25, blue: 0.2, alpha: 0.3))
            ctx.setLineWidth(r(1, 2))
            ctx.strokePath()
        }
        return ctx.makeImage()!
    }

    static func environmentImage() -> CGImage {
        let ctx = context(256, 128)
        let colors = [
            CGColor(red: 0.06, green: 0.04, blue: 0.1, alpha: 1),
            CGColor(red: 0.4, green: 0.3, blue: 0.5, alpha: 1),
            CGColor(red: 1.0, green: 0.9, blue: 0.75, alpha: 1),
        ] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 128), options: [])
        return ctx.makeImage()!
    }

    // MARK: Dozer icons for the price tags (cut out of dozer.png)

    static let dozerSprites: [CGImage] = (1...6).map { i in
        #if SWIFT_PACKAGE
        let bundle = Bundle.module      // Mac build (swift run)
        #else
        let bundle = Bundle.main        // iPhone app (Xcode project)
        #endif
        let url = bundle.url(forResource: "dozer\(i)", withExtension: "png")!
        return CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }
}
