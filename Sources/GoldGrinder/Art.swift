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

    static let coinFace: CGImage = {
        let s = 128
        let ctx = context(s, s)
        ctx.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.06, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.24, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 8, y: 8, width: 112, height: 112))
        ctx.setStrokeColor(CGColor(red: 0.86, green: 0.58, blue: 0.1, alpha: 1))
        ctx.setLineWidth(6)
        ctx.strokeEllipse(in: CGRect(x: 22, y: 22, width: 84, height: 84))
        // star
        let path = CGMutablePath()
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5 + .pi / 2
            let rr: CGFloat = i % 2 == 0 ? 26 : 11
            let p = CGPoint(x: 64 + cos(a) * rr, y: 64 + sin(a) * rr)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0.92, green: 0.6, blue: 0.1, alpha: 1))
        ctx.fillPath()
        // shine
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.85, alpha: 0.45))
        ctx.fillEllipse(in: CGRect(x: 30, y: 74, width: 34, height: 16))
        return ctx.makeImage()!
    }()

    static let coinMat: SCNMaterial = {
        let m = pbr(coinFace, metal: 0.85, rough: 0.32)
        m.emission.contents = coinFace
        m.emission.intensity = 0.28
        return m
    }()

    /// Single coin for flying effects.
    static let coinGeo: SCNGeometry = {
        let g = SCNCylinder(radius: 0.13, height: 0.045)
        let side = pbr(rgb(0.85, 0.58, 0.12), metal: 0.9, rough: 0.3, emit: rgb(0.3, 0.17, 0))
        g.materials = [side, coinMat, coinMat]
        return g
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
    static func ringImage(progress: CGFloat, color: CGColor) -> CGImage {
        let s = 256
        let ctx = context(s, s)
        let c = CGPoint(x: 128, y: 128)
        ctx.setLineWidth(26)
        ctx.setStrokeColor(CGColor(red: 0.08, green: 0.05, blue: 0.12, alpha: 0.85))
        ctx.addArc(center: c, radius: 112, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
        if progress > 0 {
            ctx.setLineCap(.round)
            ctx.setStrokeColor(color)
            ctx.addArc(center: c, radius: 112, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi * min(1, progress), clockwise: true)
            ctx.strokePath()
        }
        // tick marks
        ctx.setLineCap(.butt)
        ctx.setLineWidth(3)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.25))
        for k in 0..<20 {
            let a = CGFloat(k) / 20 * 2 * .pi
            ctx.move(to: CGPoint(x: c.x + cos(a) * 100, y: c.y + sin(a) * 100))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 124, y: c.y + sin(a) * 124))
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
