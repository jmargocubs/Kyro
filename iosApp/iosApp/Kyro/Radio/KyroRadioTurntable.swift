#if os(iOS)
import AVFoundation
import AVKit
import MediaPlayer
import Nuke
import SwiftUI
import UIKit

// The expanded Radio player as a turntable, with one layout across all finishes.
//
// Performance rules this file keeps:
// - The record turns as a Core Animation rotation on one layer; SwiftUI does
//   not re-render per frame. Spin-up and coasting are single timed animations.
// - Record grooves, the walnut grain and the brass slider knob are drawn once
//   into cached bitmaps (grain and grooves off the main thread); the label is
//   composed once per station and theme.
// - Nothing here runs outside the presented sheet. Off screen, in the
//   background or with Reduce Motion the record holds still.

// MARK: - Palette

/// Shared finishes for the iOS turntable and cassette players.
struct KyroRadioPlayerPalette {
    let theme: KyroRadioPlayerTheme
    let backgroundTop: Color
    let backgroundBottom: Color
    let plinthTop: Color
    let plinthBottom: Color
    let plinthEdge: Color
    let edgeGlow: Color
    let metalLight: Color
    let metalMid: Color
    let metalDark: Color
    let lamp: Color
    let panelTop: Color
    let panelBottom: Color
    let panelStroke: Color
    let panelPrimary: Color
    let panelSecondary: Color
    let headerText: Color
    let controlIcon: Color
    let sheen: Color
    let label: UIColor
    let labelRing: UIColor
    let labelInk: UIColor
    let cartridge: Color
    let usesWood: Bool

    static func of(_ theme: KyroRadioPlayerTheme) -> Self {
        switch theme {
        case .crimsonNoir:
            Self(theme: theme,
                 backgroundTop: Color(hex: 0x5A0B16), backgroundBottom: Color(hex: 0x0D0405),
                 plinthTop: Color(hex: 0x1C1517), plinthBottom: Color(hex: 0x0B090A),
                 plinthEdge: Color(hex: 0x3A1218), edgeGlow: Color(hex: 0xC4142E),
                 metalLight: Color(hex: 0xF6D9CB), metalMid: Color(hex: 0xC48E78), metalDark: Color(hex: 0x553329),
                 lamp: Color(hex: 0xFF2E48),
                 panelTop: Color.black.opacity(0.42), panelBottom: Color(hex: 0x2A070C).opacity(0.6),
                 panelStroke: Color(hex: 0xC48E78).opacity(0.35),
                 panelPrimary: Color(hex: 0xF4DED4), panelSecondary: Color(hex: 0xC9A296),
                 headerText: Color(hex: 0xF4DED4), controlIcon: Color(hex: 0xF4DED4),
                 sheen: Color(hex: 0xFF3048).opacity(0.22),
                 label: UIColor(hex: 0x7C1322), labelRing: UIColor(hex: 0xC48E78), labelInk: UIColor(hex: 0xF6D9CB),
                 cartridge: Color(hex: 0xB3122A), usesWood: false)
        case .classicWalnut:
            Self(theme: theme,
                 backgroundTop: Color(hex: 0x5B3519), backgroundBottom: Color(hex: 0x2A160A),
                 plinthTop: Color(hex: 0x4A2914), plinthBottom: Color(hex: 0x2B170A),
                 plinthEdge: Color(hex: 0xC9993F), edgeGlow: Color(hex: 0xFFB547),
                 metalLight: Color(hex: 0xFFEBB0), metalMid: Color(hex: 0xC99A3E), metalDark: Color(hex: 0x6A4816),
                 lamp: Color(hex: 0xFFB547),
                 panelTop: Color(hex: 0xF3E7CC), panelBottom: Color(hex: 0xE3D0A8),
                 panelStroke: Color(hex: 0xC9993F).opacity(0.8),
                 panelPrimary: Color(hex: 0x3A2414), panelSecondary: Color(hex: 0x6B4E36),
                 headerText: Color(hex: 0xF6D9A0), controlIcon: Color(hex: 0xF6D9A0),
                 sheen: Color(hex: 0xFFE2B0).opacity(0.16),
                 label: UIColor(hex: 0xEADCBE), labelRing: UIColor(hex: 0x6E1E22), labelInk: UIColor(hex: 0x4A2316),
                 cartridge: Color(hex: 0x3A2A1E), usesWood: true)
        case .modernStream:
            Self(theme: theme,
                 backgroundTop: Color(hex: 0x191F1D), backgroundBottom: Color(hex: 0x090C0B),
                 plinthTop: Color(hex: 0x282E2D), plinthBottom: Color(hex: 0x111514),
                 plinthEdge: Color(hex: 0x424E48), edgeGlow: Color(hex: 0x52F598),
                 metalLight: Color(hex: 0xC5D0CB), metalMid: Color(hex: 0x707D77), metalDark: Color(hex: 0x25302C),
                 lamp: Color(hex: 0x6BFFAA),
                 panelTop: Color(hex: 0x232C28), panelBottom: Color(hex: 0x151B19),
                 panelStroke: Color(hex: 0x46574E),
                 panelPrimary: Color(hex: 0xF1F7F3), panelSecondary: Color(hex: 0xB1C2B8),
                 headerText: Color(hex: 0xF1F7F3), controlIcon: Color(hex: 0xE6F1EA),
                 sheen: Color(hex: 0x65CE9A).opacity(0.12),
                 label: UIColor(hex: 0x202B25), labelRing: UIColor(hex: 0x6BFFAA), labelInk: UIColor(hex: 0xDFF7E9),
                 cartridge: Color(hex: 0x34443D), usesWood: false)
        }
    }

    var metal: AngularGradient {
        AngularGradient(colors: [metalLight, metalMid, metalDark, metalMid, metalLight, metalMid, metalDark, metalMid, metalLight],
                        center: .center)
    }

    var metalLinear: LinearGradient {
        LinearGradient(colors: [metalLight, metalMid, metalDark], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var isModern: Bool { theme == .modernStream }
    var titleDesign: Font.Design { isModern ? .default : .serif }
    var transportInk: Color { isModern ? Color(hex: 0x0B2115) : metalDark }
    var miniAccent: Color {
        switch theme {
        case .crimsonNoir: Color(hex: 0xF06C83)
        case .classicWalnut: Color(hex: 0xD9AC62)
        case .modernStream: edgeGlow
        }
    }

    func panel(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        return shape.fill(LinearGradient(colors: [panelTop, panelBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.strokeBorder(panelStroke, lineWidth: 1))
    }
}

/// Keeps the shell's accessory material and footprint intact.
struct KyroAudioMiniTransportFinish: ViewModifier {
    let theme: KyroRadioPlayerTheme

    func body(content: Content) -> some View {
        let accent = KyroRadioPlayerPalette.of(theme).miniAccent
        content.background {
            Circle().fill(accent.opacity(0.19))
                .overlay(Circle().strokeBorder(accent.opacity(0.52), lineWidth: 1))
                .padding(3)
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Cached textures

/// Bitmaps drawn once per size and kept for the session. Grain and grooves are
/// drawn with Core Graphics off the main thread.
enum KyroRadioTextures {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: UIImage] = [:]
        func get(_ key: String) -> UIImage? { lock.lock(); defer { lock.unlock() }; return images[key] }
        func set(_ key: String, _ image: UIImage) {
            lock.lock(); defer { lock.unlock() }
            // Bounded: a few record sizes, two grain sizes, recent labels.
            if images.count > 24 { images.removeAll() }
            images[key] = image
        }
    }

    private static let cache = Cache()

    static func cached(_ key: String) -> UIImage? { cache.get(key) }

    static func recordKey(pixels: Int) -> String { "record-\(pixels)" }
    static func woodKey(width: Int, height: Int) -> String { "wood-\(width)x\(height)" }

    /// The record's grooves, without the label. Drawn once per pixel size.
    static func record(pixels: Int) async -> UIImage {
        let key = recordKey(pixels: pixels)
        if let image = cache.get(key) { return image }
        let image = await Task.detached(priority: .userInitiated) { drawRecord(pixels: pixels) }.value
        cache.set(key, image)
        return image
    }

    /// Walnut grain for the background and plinth. Drawn once per size.
    static func wood(width: Int, height: Int) async -> UIImage {
        let key = woodKey(width: width, height: height)
        if let image = cache.get(key) { return image }
        let image = await Task.detached(priority: .userInitiated) { drawWood(width: width, height: height) }.value
        cache.set(key, image)
        return image
    }

    /// A fixed-seed generator so the grain and grooves look the same every time.
    private struct Seeded {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawRecord(pixels: Int) -> UIImage {
        let size = max(pixels, 64)
        guard let ctx = context(width: size, height: size) else { return UIImage() }
        let d = CGFloat(size)
        let center = CGPoint(x: d / 2, y: d / 2)
        let radius = d / 2
        ctx.setFillColor(CGColor(gray: 0.035, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))

        // Concentric grooves: hairline rings of slightly varying brightness.
        var random = Seeded(state: 0x4B59524F)
        let step = max(0.9, d / 520)
        var r = radius * 0.38
        while r < radius * 0.975 {
            let brightness = 0.10 + random.next() * 0.10
            ctx.setStrokeColor(CGColor(gray: 1, alpha: brightness * 0.55))
            ctx.setLineWidth(max(0.5, step * 0.42))
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
            r += step
        }
        // Gaps between tracks: smooth darker bands with a faint lit edge.
        for fraction in [0.50, 0.61, 0.72, 0.83, 0.92] {
            let band = radius * CGFloat(fraction)
            ctx.setStrokeColor(CGColor(gray: 0.0, alpha: 0.75))
            ctx.setLineWidth(d * 0.007)
            ctx.strokeEllipse(in: CGRect(x: center.x - band, y: center.y - band, width: band * 2, height: band * 2))
            let edge = band + d * 0.0042
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
            ctx.setLineWidth(max(0.5, d * 0.0012))
            ctx.strokeEllipse(in: CGRect(x: center.x - edge, y: center.y - edge, width: edge * 2, height: edge * 2))
        }
        // Run-out area and the rolled outer edge.
        let runOut = radius * 0.375
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.06))
        ctx.setLineWidth(d * 0.004)
        ctx.strokeEllipse(in: CGRect(x: center.x - runOut, y: center.y - runOut, width: runOut * 2, height: runOut * 2))
        let rim = radius - d * 0.006
        ctx.setStrokeColor(CGColor(gray: 0.28, alpha: 1))
        ctx.setLineWidth(d * 0.010)
        ctx.strokeEllipse(in: CGRect(x: center.x - rim, y: center.y - rim, width: rim * 2, height: rim * 2))
        guard let image = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: image)
    }

    private static func drawWood(width: Int, height: Int) -> UIImage {
        guard let ctx = context(width: width, height: height) else { return UIImage() }
        let w = CGFloat(width), h = CGFloat(height)
        // Core Graphics draws bottom-up; grain is symmetric enough not to care.
        ctx.setFillColor(CGColor(red: 0.30, green: 0.17, blue: 0.085, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var random = Seeded(state: 0x57414C4E)
        let lines = Int(w / 3.2)
        for _ in 0..<lines {
            let x0 = CGFloat(random.next()) * w
            let amplitude = CGFloat(4 + random.next() * 14) * (w / 800)
            let frequency = CGFloat(0.002 + random.next() * 0.004)
            let phase = CGFloat(random.next() * .pi * 2)
            let drift = CGFloat(random.next() - 0.5) * w * 0.04
            let dark = random.next() < 0.55
            let tone = dark ? CGColor(red: 0.16, green: 0.08, blue: 0.035, alpha: 0.18 + random.next() * 0.30)
                            : CGColor(red: 0.55, green: 0.33, blue: 0.17, alpha: 0.10 + random.next() * 0.22)
            ctx.setStrokeColor(tone)
            ctx.setLineWidth(CGFloat(0.8 + random.next() * 4.5) * (w / 800))
            let path = CGMutablePath()
            var y: CGFloat = -10
            path.move(to: CGPoint(x: x0 + sin(phase) * amplitude, y: y))
            while y < h + 20 {
                y += 18
                let x = x0 + sin(y * frequency + phase) * amplitude + drift * (y / h)
                path.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        // A few figure swirls, as walnut veneer has.
        for _ in 0..<5 {
            let cx = CGFloat(random.next()) * w, cy = CGFloat(random.next()) * h
            let rings = 6 + Int(random.next() * 8)
            for ring in 0..<rings {
                let rx = CGFloat(ring) * 6 * (w / 800) + 4, ry = rx * CGFloat(2.4 + random.next())
                ctx.setStrokeColor(CGColor(red: 0.18, green: 0.09, blue: 0.04, alpha: 0.10 + random.next() * 0.12))
                ctx.setLineWidth(1.2 * (w / 800))
                ctx.strokeEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
            }
        }
        // Lacquer: a soft vertical sheen.
        let colors = [CGColor(gray: 1, alpha: 0.07), CGColor(gray: 1, alpha: 0), CGColor(gray: 0, alpha: 0.18)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        guard let image = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: image)
    }

    /// The record label: the station's own logo when it has one, its name and
    /// "Internet Radio". Composed once per station, theme and size.
    @MainActor
    static func label(stationID: String?, name: String, artwork: UIImage?, palette: KyroRadioPlayerPalette,
                      points: CGFloat, scale: CGFloat) -> UIImage {
        let key = "label-\(stationID ?? "none")-\(palette.theme.rawValue)-\(Int(points * scale))-\(artwork == nil ? 0 : 1)"
        if let image = cache.get(key) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let size = CGSize(width: points, height: points)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            let rect = CGRect(origin: .zero, size: size)
            ctx.setFillColor(palette.label.cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(palette.labelRing.cgColor)
            ctx.setLineWidth(points * (palette.isModern ? 0.015 : 0.027))
            ctx.strokeEllipse(in: rect.insetBy(dx: points * 0.03, dy: points * 0.03))
            ctx.setStrokeColor(palette.labelRing.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(points * 0.006)
            ctx.strokeEllipse(in: rect.insetBy(dx: points * 0.09, dy: points * 0.09))

            // Logo (or a radio mast) above the spindle.
            let logoSide = points * 0.34
            let logoRect = CGRect(x: (points - logoSide) / 2, y: points * 0.13, width: logoSide, height: logoSide)
            if let artwork {
                ctx.saveGState()
                UIBezierPath(roundedRect: logoRect, cornerRadius: logoSide * 0.18).addClip()
                UIColor.white.withAlphaComponent(0.92).setFill()
                UIRectFill(logoRect)
                let fit = aspectFit(artwork.size, in: logoRect.insetBy(dx: logoSide * 0.06, dy: logoSide * 0.06))
                artwork.draw(in: fit)
                ctx.restoreGState()
            } else if let mast = UIImage(systemName: "antenna.radiowaves.left.and.right")?
                .withTintColor(palette.labelInk, renderingMode: .alwaysOriginal) {
                mast.draw(in: aspectFit(mast.size, in: logoRect.insetBy(dx: logoSide * 0.12, dy: logoSide * 0.12)))
            }

            // Station name below the spindle; then the label's small print.
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let baseFont = UIFont.systemFont(ofSize: points * 0.083, weight: .semibold)
            let descriptor = palette.isModern ? nil : baseFont.fontDescriptor.withDesign(.serif)
            let nameFont = descriptor.map { UIFont(descriptor: $0, size: baseFont.pointSize) } ?? baseFont
            let nameText = NSAttributedString(string: name.uppercased(), attributes: [
                .font: nameFont, .foregroundColor: palette.labelInk, .paragraphStyle: paragraph, .kern: points * 0.008,
            ])
            nameText.draw(with: CGRect(x: points * 0.16, y: points * 0.60, width: points * 0.68, height: points * 0.18),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            let small = NSAttributedString(string: "INTERNET RADIO", attributes: [
                .font: UIFont.systemFont(ofSize: points * 0.042, weight: .medium),
                .foregroundColor: palette.labelInk.withAlphaComponent(0.8), .paragraphStyle: paragraph, .kern: points * 0.012,
            ])
            small.draw(with: CGRect(x: points * 0.2, y: points * 0.80, width: points * 0.6, height: points * 0.08),
                       options: [.usesLineFragmentOrigin], context: nil)
        }
        cache.set(key, image)
        return image
    }

    private static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    /// The volume slider's knob, per theme.
    @MainActor
    static func knob(_ palette: KyroRadioPlayerPalette) -> UIImage {
        let key = "knob-\(palette.theme.rawValue)"
        if let image = cache.get(key) { return image }
        let side: CGFloat = 26
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let ctx = context.cgContext
            let rect = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
            let colors = [UIColor(palette.metalLight).cgColor, UIColor(palette.metalMid).cgColor, UIColor(palette.metalDark).cgColor] as CFArray
            ctx.addEllipse(in: rect)
            ctx.clip()
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: side * 0.38, y: side * 0.32), startRadius: 0,
                                       endCenter: CGPoint(x: side / 2, y: side / 2), endRadius: side / 2, options: [])
            }
            ctx.resetClip()
            ctx.setStrokeColor(UIColor(palette.metalDark).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect)
        }
        cache.set(key, image)
        return image
    }
}

// MARK: - Spinning record (Core Animation)

/// The record and its label on one layer, rotated by Core Animation. SwiftUI
/// only tells it whether to turn; it never redraws per frame.
final class KyroVinylPlatterUIView: UIView {
    private let spinLayer = CALayer()
    private let groovesLayer = CALayer()
    private let labelLayer = CALayer()
    private(set) var isTurning = false
    private weak var shownRecord: UIImage?
    private weak var shownLabel: UIImage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(spinLayer)
        spinLayer.addSublayer(groovesLayer)
        spinLayer.addSublayer(labelLayer)
        groovesLayer.contentsGravity = .resizeAspect
        labelLayer.contentsGravity = .resizeAspect
        labelLayer.masksToBounds = true
        // Static content: rasterising keeps the rotation a cheap compositor job.
        spinLayer.shouldRasterize = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.bounds = bounds
        spinLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        groovesLayer.frame = bounds
        let labelSide = bounds.width * KyroTurntableGeometry.labelFraction
        labelLayer.frame = CGRect(x: (bounds.width - labelSide) / 2, y: (bounds.height - labelSide) / 2,
                                  width: labelSide, height: labelSide)
        labelLayer.cornerRadius = labelSide / 2
        spinLayer.rasterizationScale = traitCollection.displayScale
        CATransaction.commit()
    }

    func setImages(record: UIImage?, label: UIImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let record, record !== shownRecord {
            groovesLayer.contents = record.cgImage
            shownRecord = record
        }
        if let label, label !== shownLabel {
            labelLayer.contents = label.cgImage
            shownLabel = label
        }
        CATransaction.commit()
    }

    private var currentAngle: CGFloat {
        let source = spinLayer.presentation() ?? spinLayer
        return (source.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
    }

    /// Starts or stops the record. Starting spins up to 33⅓ rpm; stopping coasts
    /// down when `coasts` is true and freezes in place otherwise (off screen,
    /// background, Reduce Motion).
    func setTurning(_ turning: Bool, coasts: Bool) {
        guard turning != isTurning else { return }
        isTurning = turning
        let angle = currentAngle
        spinLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()

        let speed = 2 * CGFloat.pi / KyroTurntableMotion.secondsPerRevolution
        let now = spinLayer.convertTime(CACurrentMediaTime(), from: nil)
        if turning {
            // Ease in from rest; the curve's end slope equals the steady speed.
            let rampTime = KyroTurntableMotion.spinUpSeconds
            let rampEnd = angle + speed * rampTime / 2
            let ramp = CABasicAnimation(keyPath: "transform.rotation.z")
            ramp.fromValue = angle
            ramp.toValue = rampEnd
            ramp.duration = rampTime
            ramp.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.5)
            spinLayer.add(ramp, forKey: "spinUp")
            let steady = CABasicAnimation(keyPath: "transform.rotation.z")
            steady.fromValue = rampEnd
            steady.byValue = 2 * CGFloat.pi
            steady.duration = KyroTurntableMotion.secondsPerRevolution
            steady.repeatCount = .infinity
            steady.beginTime = now + rampTime
            spinLayer.add(steady, forKey: "spin")
            spinLayer.setValue(rampEnd, forKeyPath: "transform.rotation.z")
        } else if coasts {
            // Ease out from the steady speed to rest.
            let coastTime = KyroTurntableMotion.slowDownSeconds
            let end = angle + speed * coastTime / 2
            let coast = CABasicAnimation(keyPath: "transform.rotation.z")
            coast.fromValue = angle
            coast.toValue = end
            coast.duration = coastTime
            coast.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.5, 0.5, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            spinLayer.setValue(end, forKeyPath: "transform.rotation.z")
            CATransaction.commit()
            spinLayer.add(coast, forKey: "coast")
        }
    }

    /// Removes every animation and holds the current angle.
    func freeze() {
        let angle = currentAngle
        isTurning = false
        spinLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinLayer.setValue(angle, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
    }
}

private struct KyroVinylPlatter: UIViewRepresentable {
    let record: UIImage?
    let label: UIImage?
    let turning: Bool
    let coasts: Bool

    func makeUIView(context: Context) -> KyroVinylPlatterUIView { KyroVinylPlatterUIView() }

    func updateUIView(_ view: KyroVinylPlatterUIView, context: Context) {
        view.setImages(record: record, label: label)
        view.setTurning(turning, coasts: coasts)
    }

    static func dismantleUIView(_ view: KyroVinylPlatterUIView, coordinator: ()) { view.freeze() }
}

// MARK: - Geometry

/// Proportions of the deck, relative to its width.
enum KyroTurntableGeometry {
    static let heightRatio: CGFloat = 0.94
    static let recordDiameter: CGFloat = 0.80
    static let recordCenter = CGPoint(x: 0.45, y: 0.47)
    static let labelFraction: CGFloat = 0.34
    static let pivot = CGPoint(x: 0.885, y: 0.13)
}

// MARK: - Tonearm

/// Counterweight, curved tube, headshell and cartridge, drawn at rest in deck
/// coordinates and turned about the pivot. Drawn once per size and theme; only
/// its rotation animates.
private struct KyroTonearm: View {
    let palette: KyroRadioPlayerPalette
    let width: CGFloat

    var body: some View {
        Canvas { context, size in
            let w = width
            let pivot = CGPoint(x: KyroTurntableGeometry.pivot.x * w, y: KyroTurntableGeometry.pivot.y * w)
            let end = CGPoint(x: pivot.x - 0.06 * w, y: pivot.y + 0.62 * w)

            // Counterweight behind the pivot.
            let weight = CGRect(x: pivot.x - 0.04 * w, y: pivot.y - 0.115 * w, width: 0.08 * w, height: 0.085 * w)
            context.fill(Path(roundedRect: weight, cornerRadius: 0.012 * w),
                         with: .linearGradient(Gradient(colors: [palette.metalDark, palette.metalLight, palette.metalMid, palette.metalDark]),
                                               startPoint: CGPoint(x: weight.minX, y: weight.midY),
                                               endPoint: CGPoint(x: weight.maxX, y: weight.midY)))
            for index in 1...4 {
                let y = weight.minY + weight.height * CGFloat(index) / 5
                context.stroke(Path { $0.move(to: CGPoint(x: weight.minX, y: y)); $0.addLine(to: CGPoint(x: weight.maxX, y: y)) },
                               with: .color(palette.metalDark.opacity(0.5)), lineWidth: 0.6)
            }

            // The S-shaped tube.
            var tube = Path()
            tube.move(to: pivot)
            tube.addCurve(to: end, control1: CGPoint(x: pivot.x + 0.025 * w, y: pivot.y + 0.32 * w),
                          control2: CGPoint(x: pivot.x - 0.075 * w, y: pivot.y + 0.44 * w))
            context.stroke(tube, with: .color(palette.metalDark), style: StrokeStyle(lineWidth: 0.026 * w, lineCap: .round))
            context.stroke(tube, with: .color(palette.metalMid), style: StrokeStyle(lineWidth: 0.018 * w, lineCap: .round))
            context.stroke(tube.offsetBy(dx: -0.003 * w, dy: 0), with: .color(palette.metalLight.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 0.005 * w, lineCap: .round))

            // Headshell and cartridge, angled like a real offset headshell.
            var head = context
            head.translateBy(x: end.x, y: end.y)
            head.rotate(by: .degrees(28))
            let shell = CGRect(x: -0.032 * w, y: -0.01 * w, width: 0.064 * w, height: 0.10 * w)
            head.fill(Path(roundedRect: shell, cornerRadius: 0.008 * w),
                      with: .linearGradient(Gradient(colors: [palette.metalLight, palette.metalMid, palette.metalDark]),
                                            startPoint: CGPoint(x: shell.minX, y: shell.minY), endPoint: CGPoint(x: shell.maxX, y: shell.maxY)))
            let cartridge = CGRect(x: -0.026 * w, y: 0.05 * w, width: 0.052 * w, height: 0.045 * w)
            head.fill(Path(roundedRect: cartridge, cornerRadius: 0.004 * w), with: .color(palette.cartridge))
            head.fill(Path(ellipseIn: CGRect(x: -0.014 * w, y: 0.012 * w, width: 0.008 * w, height: 0.008 * w)), with: .color(palette.metalDark))
            head.fill(Path(ellipseIn: CGRect(x: 0.006 * w, y: 0.012 * w, width: 0.008 * w, height: 0.008 * w)), with: .color(palette.metalDark))
            // Finger lift.
            head.stroke(Path { $0.move(to: CGPoint(x: shell.maxX, y: 0.02 * w)); $0.addLine(to: CGPoint(x: shell.maxX + 0.028 * w, y: 0.034 * w)) },
                        with: .color(palette.metalMid), style: StrokeStyle(lineWidth: 0.006 * w, lineCap: .round))
        }
        .frame(width: width, height: width * KyroTurntableGeometry.heightRatio)
        .shadow(color: .black.opacity(0.45), radius: 4, x: 3, y: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Deck

/// The plinth, platter, record, tonearm, pilot lamp and badge.
struct KyroTurntableDeck: View {
    let palette: KyroRadioPlayerPalette
    let width: CGFloat
    let station: KyroRadioStation?
    let motion: KyroTurntableMotion
    /// On screen in an active app: the record may turn and the lamp may blink.
    let isLive: Bool
    let wood: UIImage?

    @Environment(\.displayScale) private var displayScale
    @State private var record: UIImage?
    @State private var artwork: UIImage?
    @State private var lampDim = false

    private var height: CGFloat { width * KyroTurntableGeometry.heightRatio }
    private var diameter: CGFloat { width * KyroTurntableGeometry.recordDiameter }
    private var center: CGPoint {
        CGPoint(x: KyroTurntableGeometry.recordCenter.x * width, y: KyroTurntableGeometry.recordCenter.y * width)
    }

    private var label: UIImage {
        KyroRadioTextures.label(stationID: station?.id, name: station?.name ?? "Kyro Radio", artwork: artwork,
                                palette: palette, points: diameter * KyroTurntableGeometry.labelFraction, scale: displayScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            plinth
            screws
            platterRing
            KyroVinylPlatter(record: record, label: label,
                             turning: KyroTurntableMotion.platterRuns(motion, isVisible: isLive, isAppActive: true),
                             coasts: motion.animates && isLive)
                .frame(width: diameter, height: diameter)
                .position(center)
            sheen
            spindle
            lampView
            badge
            armBase
            KyroTonearm(palette: palette, width: width)
                .rotationEffect(.degrees(KyroTurntableMotion.tonearmDegrees(motion.tonearm)),
                                anchor: UnitPoint(x: KyroTurntableGeometry.pivot.x,
                                                  y: KyroTurntableGeometry.pivot.y / KyroTurntableGeometry.heightRatio))
                .animation(motion.animates ? .spring(duration: 1.1, bounce: 0.08) : nil, value: motion.tonearm)
        }
        .frame(width: width, height: height)
        .task(id: Int(diameter * displayScale)) {
            record = await KyroRadioTextures.record(pixels: Int(diameter * displayScale))
        }
        .task(id: station?.id) { await loadArtwork() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch motion.tonearm {
        case .playing: "Turntable, record playing"
        case .cued: "Turntable, connecting"
        case .rest: motion.lamp == .fault ? "Turntable, stopped after an error" : "Turntable, stopped"
        }
    }

    private func loadArtwork() async {
        artwork = nil
        guard let url = station?.favicon,
              let request = PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: 120, height: 120),
                                                            scale: displayScale, priority: .normal),
              let image = try? await ImagePipeline.shared.image(for: request),
              !Task.isCancelled else { return }
        artwork = image
    }

    // MARK: Parts

    private var plinth: some View {
        let shape = RoundedRectangle(cornerRadius: width * 0.06, style: .continuous)
        return ZStack {
            if palette.usesWood, let wood {
                Image(uiImage: wood).resizable().scaledToFill()
                    .frame(width: width, height: height).clipped()
                    .overlay(Color.black.opacity(0.18))
            } else {
                LinearGradient(colors: [palette.plinthTop, palette.plinthBottom], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.plinthEdge, lineWidth: palette.usesWood ? 2 : 1))
        .overlay(shape.inset(by: 4).strokeBorder(Color.white.opacity(palette.usesWood ? 0.10 : 0.05), lineWidth: 1))
        .shadow(color: .black.opacity(0.50), radius: 12, y: 7)
        .shadow(color: palette.usesWood ? .clear : palette.edgeGlow.opacity(0.24), radius: 10, y: 5)
    }

    private var screws: some View {
        let inset = width * 0.045
        let points = [CGPoint(x: inset, y: inset), CGPoint(x: width - inset, y: inset),
                      CGPoint(x: inset, y: height - inset), CGPoint(x: width - inset, y: height - inset)]
        return ForEach(points.indices, id: \.self) { index in
            ZStack {
                Circle().fill(palette.metalLinear)
                Rectangle().fill(palette.metalDark).frame(width: width * 0.022, height: 1.2)
                    .rotationEffect(.degrees(Double(index) * 37 + 20))
            }
            .frame(width: width * 0.026, height: width * 0.026)
            .shadow(color: .black.opacity(0.6), radius: 1, y: 1)
            .position(points[index])
        }
    }

    private var platterRing: some View {
        ZStack {
            Circle().fill(palette.metal)
            Circle().fill(Color.black.opacity(0.85)).padding(diameter * 0.018)
            // Knurled strobe edge, as on a real platter.
            Circle().strokeBorder(palette.metalDark.opacity(0.7),
                                  style: StrokeStyle(lineWidth: diameter * 0.012, dash: [1.2, 2.2]))
                .padding(diameter * 0.004)
        }
        .frame(width: diameter * 1.045, height: diameter * 1.045)
        .shadow(color: .black.opacity(0.6), radius: 8, y: 4)
        .position(center)
    }

    /// Fixed light on the record's surface; it does not turn with the record.
    private var sheen: some View {
        Circle()
            .fill(AngularGradient(stops: [
                .init(color: .clear, location: 0.00),
                .init(color: .white.opacity(0.16), location: 0.10),
                .init(color: palette.sheen, location: 0.14),
                .init(color: .clear, location: 0.24),
                .init(color: .clear, location: 0.52),
                .init(color: .white.opacity(0.10), location: 0.62),
                .init(color: .clear, location: 0.72),
                .init(color: .clear, location: 1.00),
            ], center: .center, angle: .degrees(-30)))
            .mask {
                ZStack {
                    Circle()
                    Circle().frame(width: diameter * KyroTurntableGeometry.labelFraction * 1.05)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .frame(width: diameter, height: diameter)
            .position(center)
            .allowsHitTesting(false)
    }

    private var spindle: some View {
        Circle()
            .fill(RadialGradient(colors: [palette.metalLight, palette.metalMid, palette.metalDark],
                                 center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: diameter * 0.02))
            .frame(width: diameter * 0.04, height: diameter * 0.04)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .position(center)
    }

    private var armBase: some View {
        let pivot = CGPoint(x: KyroTurntableGeometry.pivot.x * width, y: KyroTurntableGeometry.pivot.y * width)
        return ZStack {
            Circle().fill(palette.metal)
            Circle().fill(LinearGradient(colors: [palette.metalDark, palette.plinthBottom], startPoint: .top, endPoint: .bottom))
                .padding(width * 0.018)
            Circle().fill(palette.metalLinear).padding(width * 0.04)
        }
        .frame(width: width * 0.15, height: width * 0.15)
        .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
        .position(pivot)
    }

    /// The pilot lamp: lit while playing, blinking while connecting, red after an error.
    private var lampView: some View {
        let color: Color = motion.lamp == .fault ? Color(hex: 0xFF3B30) : palette.lamp
        let isLit = motion.lamp != .off
        let blinking = motion.lamp == .blinking && motion.animates && isLive
        return Circle()
            .fill(RadialGradient(colors: [isLit ? .white : color.opacity(0.35), isLit ? color : color.opacity(0.25),
                                          palette.metalDark],
                                 center: .center, startRadius: 0, endRadius: width * 0.03))
            .overlay(Circle().strokeBorder(palette.metalLinear, lineWidth: width * 0.008))
            .frame(width: width * 0.055, height: width * 0.055)
            .shadow(color: isLit ? color.opacity(0.9) : .clear, radius: isLit ? 10 : 0)
            .opacity(blinking && lampDim ? 0.35 : 1)
            .position(x: width * 0.09, y: height * 0.885)
            .onChange(of: blinking, initial: true) { _, isBlinking in
                if isBlinking {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { lampDim = true }
                } else {
                    withAnimation(.none) { lampDim = false }
                }
            }
    }

    private var badge: some View {
        Text("Kyro X")
            .font(.system(size: width * 0.04, weight: .semibold, design: .serif).italic())
            .foregroundStyle(palette.usesWood ? palette.metalDark : palette.metalLight)
            .padding(.horizontal, width * 0.03)
            .padding(.vertical, width * 0.012)
            .background(RoundedRectangle(cornerRadius: 3).fill(palette.usesWood ? AnyShapeStyle(palette.metalLinear)
                                                                                  : AnyShapeStyle(Color.black.opacity(0.5))))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(palette.metalMid, lineWidth: 0.8))
            .position(x: width * 0.83, y: height * 0.885)
            .accessibilityHidden(true)
    }
}

// MARK: - Hardware controls

/// A machined round button.
struct KyroHardwareButtonStyle: ButtonStyle {
    let palette: KyroRadioPlayerPalette
    let diameter: CGFloat
    var isPrimary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().fill(isPrimary ? (palette.isModern ? AnyShapeStyle(palette.edgeGlow) : AnyShapeStyle(palette.metal))
                                    : AnyShapeStyle(LinearGradient(colors: [palette.plinthTop, palette.plinthBottom],
                                                                   startPoint: .top, endPoint: .bottom)))
            if isPrimary && !palette.isModern {
                Circle().fill(RadialGradient(colors: [palette.metalLight, palette.metalMid], center: UnitPoint(x: 0.4, y: 0.3),
                                             startRadius: 0, endRadius: diameter * 0.45))
                    .padding(diameter * 0.09)
            }
            Circle().strokeBorder(palette.isModern && isPrimary ? palette.lamp : palette.metalMid.opacity(0.7), lineWidth: 1)
            configuration.label
                .foregroundStyle(isPrimary ? palette.transportInk : palette.controlIcon)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: isPrimary && !palette.usesWood ? palette.edgeGlow.opacity(0.28) : .black.opacity(0.45),
                radius: isPrimary ? 8 : 4, y: isPrimary ? 4 : 2)
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
        .brightness(configuration.isPressed ? -0.06 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
        .contentShape(Circle())
    }
}

/// The system volume slider in the theme's metal.
private struct KyroRadioVolumeSlider: UIViewRepresentable {
    let palette: KyroRadioPlayerPalette

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        style(view)
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) { style(view) }

    private func style(_ view: MPVolumeView) {
        for case let slider as UISlider in view.subviews {
            slider.minimumTrackTintColor = UIColor(palette.usesWood ? palette.metalMid : palette.edgeGlow)
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.22)
            slider.setThumbImage(KyroRadioTextures.knob(palette), for: .normal)
            slider.setThumbImage(KyroRadioTextures.knob(palette), for: .highlighted)
        }
    }
}

/// The system output picker: AirPlay, Bluetooth and this iPhone.
struct KyroAudioOutputPicker: UIViewRepresentable {
    let tint: Color
    let activeTint: Color
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.tintColor = UIColor(tint)
        view.activeTintColor = UIColor(activeTint)
    }
}

/// The current audio output's name, from the system's route.
enum KyroRadioAudioRoute {
    static func currentName() -> String {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "This iPhone" }
        switch output.portType {
        case .builtInSpeaker, .builtInReceiver: return "This iPhone"
        default: return output.portName
        }
    }
}

// MARK: - Expanded player

/// Now Playing as a turntable. Live radio only: Play/Pause, Stop,
/// Save, output and volume. No skip, shuffle or repeat, no progress, and no
/// waveform, because the stream provides none of them.
struct KyroRadioNowPlayingView: View {
    private let player = KyroRadioPlayer.shared
    private let appearance = KyroRadioPlayerAppearance.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var isVisible = false
    @State private var wood: UIImage?
    @State private var routeName = KyroRadioAudioRoute.currentName()

    var body: some View {
        let palette = KyroRadioPlayerPalette.of(appearance.theme)
        let motion = KyroTurntableMotion.motion(for: player.state, reduceMotion: reduceMotion)
        GeometryReader { proxy in
            let deckWidth = max(1, min(460, proxy.size.width - 36, proxy.size.height * 0.47 / KyroTurntableGeometry.heightRatio))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 18) {
                    header(palette)
                    KyroTurntableDeck(palette: palette, width: deckWidth, station: player.station, motion: motion,
                                      isLive: isVisible && scenePhase == .active, wood: wood)
                    KyroRadioStationPanel(palette: palette, player: player)
                    controls(palette)
                    volume(palette)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(background(palette).ignoresSafeArea())
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: appearance.theme) { await loadWood(palette) }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in
            routeName = KyroRadioAudioRoute.currentName()
        }
        .accessibilityIdentifier("kyroRadioNowPlaying")
    }

    private func loadWood(_ palette: KyroRadioPlayerPalette) async {
        guard palette.usesWood, wood == nil else { return }
        // One grain bitmap covers every iPhone (440 × 956 pt is the largest), at most 2×.
        let scale = min(displayScale, 2)
        wood = await KyroRadioTextures.wood(width: Int(440 * scale), height: Int(956 * scale))
    }

    // MARK: Background

    @ViewBuilder
    private func background(_ palette: KyroRadioPlayerPalette) -> some View {
        if palette.usesWood {
            ZStack {
                LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
                if let wood { Image(uiImage: wood).resizable().scaledToFill() }
                RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 120, endRadius: 600)
            }
        } else {
            ZStack {
                LinearGradient(colors: [palette.backgroundTop, palette.backgroundBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [palette.edgeGlow.opacity(palette.isModern ? 0.11 : 0.28), .clear],
                               center: UnitPoint(x: 0.2, y: 0.05),
                               startRadius: 0, endRadius: 420)
                RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center, startRadius: 200, endRadius: 650)
            }
        }
    }

    // MARK: Header

    private func header(_ palette: KyroRadioPlayerPalette) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.body.weight(.semibold))
            }
            .buttonStyle(KyroHardwareButtonStyle(palette: palette, diameter: 44))
            .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 4) {
                AppWordmarkView(placement: .compactHeader)
                Text("INTERNET RADIO")
                    .font(.caption2.weight(.medium))
                    .kerning(3)
                    .foregroundStyle(palette.headerText.opacity(0.85))
            }
            Spacer()
            KyroAudioThemeMenu(selection: appearance.theme, palette: palette, select: appearance.select)
        }
        .padding(.top, 12)
    }

    private func controls(_ palette: KyroRadioPlayerPalette) -> some View {
        HStack(spacing: 26) {
            Button { player.stop(); dismiss() } label: {
                Image(systemName: "stop.fill").font(.body.weight(.semibold))
            }
            .buttonStyle(KyroHardwareButtonStyle(palette: palette, diameter: 52))
            .accessibilityLabel("Stop")

            Button(action: transport) {
                Group {
                    switch player.state {
                    case .connecting, .reconnecting: ProgressView().tint(palette.transportInk).controlSize(.large)
                    case .failed: Image(systemName: "arrow.clockwise")
                    case .playing: Image(systemName: "pause.fill")
                    case .idle, .paused: Image(systemName: "play.fill")
                    }
                }
                .font(.system(size: 28, weight: .semibold))
            }
            .buttonStyle(KyroHardwareButtonStyle(palette: palette, diameter: 76, isPrimary: true))
            .accessibilityLabel(transportLabel)

            KyroAudioOutputPicker(tint: palette.controlIcon, activeTint: palette.miniAccent)
                .frame(width: 52, height: 52)
                .background(Circle().fill(palette.plinthTop))
                .overlay(Circle().strokeBorder(palette.metalMid.opacity(0.7), lineWidth: 1))
                .accessibilityLabel("Audio output, AirPlay and Bluetooth")
        }
    }

    private func transport() {
        if case .failed = player.state, let station = player.station {
            player.play(station)
        } else {
            player.togglePlayPause()
        }
    }

    private var transportLabel: String {
        switch player.state {
        case .playing: "Pause"
        case .failed: "Try Again"
        case .connecting, .reconnecting: "Connecting"
        case .idle, .paused: "Play"
        }
    }

    private func volume(_ palette: KyroRadioPlayerPalette) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").accessibilityHidden(true)
                KyroRadioVolumeSlider(palette: palette).frame(height: 34)
                Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
            }
            .accessibilityElement(children: .contain)
            Label("Output: \(routeName)", systemImage: "hifispeaker")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .foregroundStyle(palette.controlIcon.opacity(0.85))
    }
}

/// Track metadata updates this panel, not the deck or its artwork task.
private struct KyroRadioStationPanel: View {
    let palette: KyroRadioPlayerPalette
    let player: KyroRadioPlayer
    private let library = KyroRadioLibrary.shared

    var body: some View {
        let station = player.station
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                KyroRadioArtwork(station: station, size: 56, decodeSize: 72)
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.panelStroke, lineWidth: 1))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    statusLine
                    Text(station?.name ?? "")
                        .font(.system(.title3, design: palette.titleDesign, weight: .semibold))
                        .foregroundStyle(palette.panelPrimary)
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if let station {
                    Button { library.toggleFavorite(station) } label: {
                        Image(systemName: library.isFavorite(station.id) ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(palette.usesWood ? Color(hex: 0x9E1B22) : palette.lamp)
                    }
                    .buttonStyle(KyroHardwareButtonStyle(palette: palette, diameter: 44))
                    .accessibilityLabel(library.isFavorite(station.id) ? "Remove from Library" : "Save to Library")
                }
            }
            if let track = player.track, player.state == .playing {
                Rectangle().fill(palette.panelStroke).frame(height: 1).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(.headline).foregroundStyle(palette.panelPrimary).lineLimit(2)
                    if let artist = track.artist {
                        Text(artist).font(.subheadline).foregroundStyle(palette.panelSecondary).lineLimit(2)
                    }
                }
                .accessibilityElement(children: .combine)
            } else if case .failed(let error) = player.state {
                Label(error.message, systemImage: "exclamationmark.circle")
                    .font(.footnote.weight(.medium)).foregroundStyle(palette.panelPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let location = station?.location, !location.isEmpty {
                Text(location).font(.subheadline).foregroundStyle(palette.panelSecondary).lineLimit(2)
            }
            if let format = station?.formatLine {
                Text(format).font(.caption.monospacedDigit()).foregroundStyle(palette.panelSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background { palette.panel() }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if player.state == .playing {
                Text("LIVE")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(palette.isModern ? palette.edgeGlow : Color(hex: 0xA5122A)))
                    .foregroundStyle(palette.isModern ? palette.transportInk : .white)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right").font(.caption2).accessibilityHidden(true)
                Text(statusTitle).font(.caption2.weight(.semibold)).tracking(0.7)
            }
        }
        .foregroundStyle(palette.panelSecondary)
    }

    private var statusTitle: String {
        switch player.state {
        case .playing: "LIVE RADIO"
        case .connecting: "CONNECTING"
        case .reconnecting(let attempt): "RECONNECTING \(attempt)/\(KyroRadioPlaybackMachine.maxReconnectAttempts)"
        case .paused: "PAUSED"
        case .failed: "UNAVAILABLE"
        case .idle: "STOPPED"
        }
    }

}

// MARK: - Settings: Player Appearance

/// Available directly on the expanded player so the current session stays open.
struct KyroAudioThemeMenu: View {
    let selection: KyroRadioPlayerTheme
    let palette: KyroRadioPlayerPalette
    let select: (KyroRadioPlayerTheme) -> Void

    var body: some View {
        Menu {
            Picker("Player Appearance", selection: Binding(get: { selection }, set: select)) {
                ForEach(KyroRadioPlayerTheme.allCases) { Text($0.title).tag($0) }
            }
        } label: {
            Image(systemName: "paintpalette")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.controlIcon)
                .frame(width: 44, height: 44)
                .background(Circle().fill(palette.plinthTop))
                .overlay(Circle().strokeBorder(palette.metalMid.opacity(0.7), lineWidth: 1))
        }
        .accessibilityLabel("Player Appearance")
        .accessibilityValue(selection.title)
    }
}

enum KyroAudioThemePreviewKind { case vinyl, cassette }

private struct KyroAudioThemePreview: View {
    let theme: KyroRadioPlayerTheme
    let kind: KyroAudioThemePreviewKind

    var body: some View {
        let palette = KyroRadioPlayerPalette.of(theme)
        ZStack {
            let shape = RoundedRectangle(cornerRadius: 10)
            shape.fill(LinearGradient(colors: [palette.backgroundTop, palette.plinthBottom],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.strokeBorder(palette.plinthEdge, lineWidth: 1))
            switch kind {
            case .vinyl:
                Circle().fill(palette.metal).frame(width: 38, height: 38).offset(x: -5)
                Circle().fill(Color(white: 0.055)).frame(width: 35, height: 35)
                    .overlay(Circle().strokeBorder(.white.opacity(0.15)).padding(4))
                    .overlay {
                        Circle().fill(Color(uiColor: palette.label))
                            .overlay(Circle().strokeBorder(Color(uiColor: palette.labelRing)))
                            .frame(width: 13, height: 13)
                    }
                    .offset(x: -5)
                Capsule().fill(palette.metalLinear).frame(width: 3, height: 28)
                    .rotationEffect(.degrees(20), anchor: .top).offset(x: 18, y: -2)
            case .cassette:
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1).fill(Color(uiColor: palette.labelRing)).frame(height: 4)
                    HStack(spacing: 11) {
                        ForEach(0..<2) { _ in
                            Circle().strokeBorder(palette.metalLight, lineWidth: 2).frame(width: 10, height: 10)
                        }
                    }
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity)
                    .background(Color.black, in: .capsule)
                }
                .padding(5)
                .frame(width: 52)
                .background(palette.plinthTop, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.metalMid))
            }
        }
        .frame(width: 72, height: 54)
        .accessibilityHidden(true)
    }
}

struct KyroAudioThemeSection: View {
    let selection: KyroRadioPlayerTheme
    let kind: KyroAudioThemePreviewKind
    let identifierPrefix: String
    let select: (KyroRadioPlayerTheme) -> Void

    var body: some View {
        Section {
            ForEach(KyroRadioPlayerTheme.allCases) { theme in
                Button { select(theme) } label: {
                    HStack(spacing: 12) {
                        KyroAudioThemePreview(theme: theme, kind: kind)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(theme.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(theme.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: theme == selection ? "checkmark.circle.fill" : "circle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(theme == selection ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(theme == selection ? .isSelected : [])
                .accessibilityIdentifier("\(identifierPrefix)-\(theme.rawValue)")
            }
        } header: {
            Text("Player Appearance")
        } footer: {
            Text("Changes apply immediately without interrupting playback.")
        }
    }
}

/// Radio Settings → Player Appearance.
struct KyroRadioPlayerAppearanceSection: View {
    private let appearance = KyroRadioPlayerAppearance.shared

    var body: some View {
        KyroAudioThemeSection(selection: appearance.theme, kind: .vinyl,
                              identifierPrefix: "kyroRadioTheme", select: appearance.select)
    }
}
#endif
