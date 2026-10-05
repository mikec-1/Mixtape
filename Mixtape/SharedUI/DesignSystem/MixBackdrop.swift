// A colour of the user's choosing, mixed into the background of the whole app:
// a faint tint plus three soft blobs (the colour and two neighbouring hues) that
// can drift in and out of the window. Sits under the artwork wash, not instead of it.

import SwiftUI
import Combine

public enum BackdropMotion: String, CaseIterable, Identifiable, Sendable {
    case still, floating
    public var id: String { rawValue }
    public var title: String { self == .still ? "Still" : "Floating" }
}

/// The setting. Stored and synced as "#RRGGBB|motion"; `offRaw` syncs turning it off.
public struct MixBackdrop: Equatable, Sendable {
    public var hex: String
    public var motion: BackdropMotion

    public static let offRaw = "none"
    public static let presets = [("Rose", "#FF4F8B"), ("Coral", "#FF8A5B"), ("Gold", "#F5B82E"),
                                 ("Mint", "#2ED3A0"), ("Sky", "#3B9EFF"), ("Indigo", "#6366F1"),
                                 ("Violet", "#A855F7")]

    public var raw: String { "\(hex)|\(motion.rawValue)" }

    public init(hex: String, motion: BackdropMotion) {
        self.hex = hex.uppercased()
        self.motion = motion
    }

    public init?(raw: String) {
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 2, parts[0].count == 7, parts[0].hasPrefix("#"),
              UInt32(parts[0].dropFirst(), radix: 16) != nil,
              let motion = BackdropMotion(rawValue: parts[1]) else { return nil }
        self.init(hex: parts[0], motion: motion)
    }

    /// "#RRGGBB" in sRGB, for the colour picker.
    static func hex(of color: Color) -> String {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        let (r, g, b) = (c.redComponent, c.greenComponent, c.blueComponent)
        #endif
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

// MARK: - Rendering

/// Draws the field once, small, for every surface to share. The blobs are wide
/// and soft, so a low-resolution image scaled up looks the same.
/// With hardware acceleration each surface draws it with a shader instead (`live`).
@MainActor
final class BackdropRenderer: ObservableObject {

    static let shared = BackdropRenderer()

    /// Nil when no colour is set, and always with hardware acceleration.
    @Published private(set) var image: CGImage?
    /// What the GPU draws; nil when no colour is set or without hardware acceleration.
    @Published private(set) var live: Live?
    /// The window in points; set by `RootView`. Every surface lays the image out against it.
    @Published var fieldSize: CGSize = .zero

    private var backdrop: MixBackdrop?
    private var size: CGSize = .zero
    private var timer: Timer?
    /// Bumped by every change, so a draw that finishes late doesn't land over a newer one.
    private var generation = 0
    private var bag = Set<AnyCancellable>()

    struct Live: Equatable {
        let palette: BackdropField.Palette
        let floating: Bool
        /// False holds the blobs where they are (Reduced motion, or the app in the background).
        let moving: Bool
    }

    private init() {
        let theme = ThemeManager.shared
        // Values from the sink, not the properties: @Published fires before the store.
        Publishers.CombineLatest4(theme.$backdrop, theme.$motion,
                                  AppVisibility.shared.$isForeground, $fieldSize.removeDuplicates())
            .sink { [weak self] backdrop, motion, foreground, size in
                self?.configure(backdrop, still: motion.isReduced || !foreground, size: size)
            }
            .store(in: &bag)
    }

    private func configure(_ backdrop: MixBackdrop?, still: Bool, size: CGSize) {
        self.backdrop = backdrop
        self.size = size
        generation &+= 1
        timer?.invalidate()
        timer = nil
        guard let backdrop, size.width > 0, size.height > 0 else {
            image = nil
            live = nil
            return
        }
        if HardwareAcceleration.isOn {
            let floating = backdrop.motion == .floating
            let next = Live(palette: BackdropField.palette(hex: backdrop.hex),
                            floating: floating, moving: floating && !still)
            if live != next { live = next }
            return
        }
        render()
        // Paused off screen and under Reduced motion; the blobs hold where they are.
        guard backdrop.motion == .floating, !still else { return }
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        // `.common`, or it stalls while a scroll view tracks.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Drawn off the main thread: floating redraws 15 times a second.
    private func render() {
        guard let backdrop else { return }
        generation &+= 1
        let gen = generation, size = size
        let time = backdrop.motion == .floating ? Date.timeIntervalSinceReferenceDate : nil
        Task {
            let drawn = await Self.draw(hex: backdrop.hex, size: size, time: time)
            if gen == generation { image = drawn }
        }
    }

    @concurrent private nonisolated static func draw(hex: String, size: CGSize, time: TimeInterval?) async -> CGImage? {
        BackdropField.image(hex: hex, size: size, time: time)
    }
}

nonisolated enum BackdropField {

    /// Pixels on the long edge.
    static let resolution: CGFloat = 256

    /// Positions are fractions of the window and may leave it.
    private struct Blob {
        /// Still layout.
        let x: Double, y: Double
        /// Floating orbit: centre, reach and period in seconds per axis.
        let cx: Double, cy: Double, ax: Double, ay: Double, px: Double, py: Double, phase: Double
        /// Of the window's long edge.
        let radius: CGFloat
        let alpha: CGFloat
        let hue: CGFloat, saturation: CGFloat, brightness: CGFloat
    }

    private static let blobs = [
        // The colour itself, top left.
        Blob(x: 0.12, y: 0.08, cx: 0.30, cy: 0.30, ax: 0.55, ay: 0.50, px: 71, py: 58, phase: 0.0,
             radius: 0.70, alpha: 0.42, hue: 0, saturation: 1, brightness: 1),
        // A lighter neighbour, right.
        Blob(x: 0.90, y: 0.35, cx: 0.70, cy: 0.45, ax: 0.55, ay: 0.55, px: 63, py: 83, phase: 2.1,
             radius: 0.60, alpha: 0.34, hue: 0.07, saturation: 0.9, brightness: 1.15),
        // A deeper neighbour, bottom.
        Blob(x: 0.35, y: 0.98, cx: 0.45, cy: 0.75, ax: 0.60, ay: 0.45, px: 89, py: 67, phase: 4.2,
             radius: 0.65, alpha: 0.38, hue: -0.08, saturation: 1.1, brightness: 0.75),
    ]

    /// The tint and each blob's colour, worked out once per colour.
    struct Palette: Equatable, Sendable {
        let tint: SIMD3<Float>
        let blobs: [SIMD3<Float>]
    }

    static func palette(hex: String) -> Palette {
        let rgb = Color(hex: hex).srgbComponents
        let base = hsv(rgb)
        func simd(_ c: RGB) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }
        return Palette(tint: simd(rgb), blobs: blobs.map { blob in
            simd(color(h: (base.h + blob.hue + 1).truncatingRemainder(dividingBy: 1),
                       s: min(base.s * blob.saturation, 1),
                       v: min(base.v * blob.brightness, 1)))
        })
    }

    /// A blob's centre as fractions of the field; `time` nil is the still layout.
    private static func centre(_ blob: Blob, time: TimeInterval?) -> (x: Double, y: Double) {
        guard let t = time else { return (blob.x, blob.y) }
        return (blob.cx + blob.ax * sin(2 * .pi * t / blob.px + blob.phase),
                blob.cy + blob.ay * sin(2 * .pi * t / blob.py + blob.phase * 1.3))
    }

    /// The `backdropField` shader's data: tint, then x, y, radius, alpha and colour per blob.
    static func shaderData(_ palette: Palette, time: TimeInterval?) -> [Float] {
        var data = [palette.tint.x, palette.tint.y, palette.tint.z]
        for (blob, c) in zip(blobs, palette.blobs) {
            let p = centre(blob, time: time)
            data += [Float(p.x), Float(p.y), Float(blob.radius), Float(blob.alpha), c.x, c.y, c.z]
        }
        return data
    }

    /// `time` nil draws the still layout.
    static func image(hex: String, size: CGSize, time: TimeInterval?) -> CGImage? {
        let scale = resolution / max(size.width, size.height)
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // y down, like the window.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        let palette = palette(hex: hex)
        let tint = palette.tint
        ctx.setFillColor(CGColor(srgbRed: CGFloat(tint.x), green: CGFloat(tint.y), blue: CGFloat(tint.z), alpha: 0.07))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let long = CGFloat(max(w, h))
        for (blob, c) in zip(blobs, palette.blobs) {
            let f = centre(blob, time: time)
            let centre = CGPoint(x: CGFloat(f.x) * CGFloat(w), y: CGFloat(f.y) * CGFloat(h))
            // Eased falloff, so no blob shows an edge. Backdrop.metal uses the same stops.
            let colours = [1, 0.62, 0.26, 0.07, 0].map {
                CGColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: blob.alpha * $0)
            }
            guard let gradient = CGGradient(colorsSpace: space, colors: colours as CFArray,
                                            locations: [0, 0.3, 0.6, 0.85, 1]) else { continue }
            ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0,
                                   endCenter: centre, endRadius: blob.radius * long, options: [])
        }
        return ctx.makeImage()
    }

    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)

    static func hsv(_ c: RGB) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), d = mx - mn
        var h: CGFloat = 0
        if d > 0 {
            if mx == c.r      { h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0) }
            else if mx == c.g { h = (c.b - c.r) / d + 2 }
            else              { h = (c.r - c.g) / d + 4 }
            h /= 6
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    static func color(h: CGFloat, s: CGFloat, v: CGFloat) -> RGB {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0:  return (v, t, p)
        case 1:  return (q, v, p)
        case 2:  return (p, v, t)
        case 3:  return (p, q, v)
        case 4:  return (t, p, v)
        default: return (v, p, q)
        }
    }
}

private nonisolated extension Color {
    var srgbComponents: BackdropField.RGB {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b)
        #else
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return (c.redComponent, c.greenComponent, c.blueComponent)
        #endif
    }
}

// MARK: - Views

/// `Color.mixBackground` with the custom colour over it, laid out against the
/// window so neighbouring surfaces join up. Plain `mixBackground` when unset.
struct MixPageBackground: View {

    @ObservedObject private var renderer = BackdropRenderer.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.mixBackground
            .overlay(alignment: .topLeading) {
                if renderer.image != nil || renderer.live != nil {
                    GeometryReader { proxy in
                        let global = proxy.frame(in: .global)
                        // Under the Mac's zoom, global points are scaled; divide back to local ones.
                        let k = proxy.size.width > 0 ? global.width / proxy.size.width : 1
                        let field = CGSize(width: renderer.fieldSize.width / k,
                                           height: renderer.fieldSize.height / k)
                        if let image = renderer.image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: field.width, height: field.height)
                                .offset(x: -global.minX / k, y: -global.minY / k)
                                .opacity(Self.opacity(dark: scheme == .dark))
                        } else {
                            BackdropFieldView(origin: CGPoint(x: global.minX / k, y: global.minY / k), size: field)
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
            .ignoresSafeArea()
    }

    /// Softer on white, where the same alpha reads much stronger.
    static func opacity(dark: Bool) -> Double { dark ? 1 : 0.7 }
}

/// The field drawn per pixel by the GPU (hardware acceleration on). `origin` is this
/// view's top left within a field of `size`, both in its own points.
struct BackdropFieldView: View {

    var origin: CGPoint
    var size: CGSize

    @ObservedObject private var renderer = BackdropRenderer.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let live = renderer.live {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live.moving)) { context in
                let time = live.floating ? context.date.timeIntervalSinceReferenceDate : nil
                Rectangle()
                    .colorEffect(ShaderLibrary.backdropField(
                        .float2(origin), .float2(size),
                        .floatArray(BackdropField.shaderData(live.palette, time: time))))
            }
            .opacity(MixPageBackground.opacity(dark: scheme == .dark))
            .allowsHitTesting(false)
        }
    }
}

/// For list rows: clear over a custom colour so the page shows through, else the page colour.
struct MixRowBackground: View {
    @ObservedObject private var theme = ThemeManager.shared
    var body: some View {
        theme.backdrop == nil ? Color.mixBackground : Color.clear
    }
}
