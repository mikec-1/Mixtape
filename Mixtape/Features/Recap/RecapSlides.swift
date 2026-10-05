// The recap's slides. Every piece is drawn from the seconds since its slide began,
// so pausing freezes it and a slide that's leaving can be held still under the
// next one coming in.

import SwiftUI
#if os(macOS)
import AppKit
private typealias RecapFont = NSFont
#else
import UIKit
private typealias RecapFont = UIFont
#endif

// MARK: - Themes and slides

struct RecapTheme {
    let bg: Color, fg: Color, acc: Color
    /// Stickers and stripes.
    let shape: Color
    /// A second sticker colour. Never the text colour, so shapes can't swallow text.
    let alt: Color
    var soft: Color { fg.opacity(0.65) }

    init(_ bg: String, _ fg: String, _ acc: String, _ shape: String? = nil, _ alt: String? = nil) {
        self.bg = Color(hex: bg); self.fg = Color(hex: fg); self.acc = Color(hex: acc)
        self.shape = Color(hex: shape ?? acc)
        self.alt = Color(hex: alt ?? shape ?? acc)
    }

    static let ink    = RecapTheme("121212", "F4EEE7", "FF6B00", "FF6B00", "FF5CA8")
    static let violet = RecapTheme("4B1FE0", "FFFFFF", "D7FF3C", "FF5CA8", "FF8A3D")
    static let cobalt = RecapTheme("2F45FF", "FFFFFF", "FFC93C", "FF5CA8", "8BE3C0")
    static let orange = RecapTheme("FF6B00", "140B05", "140B05", "FFD1E6", "4B1FE0")
    static let plum   = RecapTheme("2D0B4E", "FBEAF3", "FF5C9E", "5B1FB0", "FF8A3D")
    static let pink   = RecapTheme("FF5C9E", "1E0612", "1E0612", "FFE14D", "4B1FE0")
    static let mint   = RecapTheme("8BE3C0", "06261B", "06261B", "FF8A5C", "2F45FF")
    static let night  = RecapTheme("0C1033", "EEF0FF", "FFC93C", "2B2FA8", "FF5CA8")
    static let sun    = RecapTheme("FFC93C", "1D1400", "1D1400", "FF6B1A", "FF5CA8")
    static let moss   = RecapTheme("0E3B2B", "E9F7EE", "5EE08C", "1F7A52", "D7FF3C")
    static let rose   = RecapTheme("FFD1E6", "2A0A1A", "D6105A", "D6105A", "4B1FE0")
    static let dusk   = RecapTheme("170A30", "F1EAFF", "B9A4FF", "4A2AA8", "FF8A5C")
    static let red    = RecapTheme("FF4B3A", "1C0503", "1C0503", "FFD84D", "4B1FE0")
    static let sky    = RecapTheme("7FD0FF", "04182A", "04182A", "FF6B00", "FF5CA8")
    static let ember  = RecapTheme("0A0205", "FFFFFF", "FF3D8B", "E0162B", "FF7AD9")
}

enum RecapSlide: Hashable {
    case hello, intro, genre, artist, hooked, songs, spotify, onRepeat, lateNight, fresh, find, social, clock, type, tape, card

    var theme: RecapTheme {
        switch self {
        case .hello:    .ember
        case .intro:    .violet
        case .card:     .ink
        case .genre:    .cobalt
        case .artist:   .orange
        case .hooked:   .rose
        case .songs:    .plum
        case .spotify:  .moss
        case .onRepeat: .pink
        case .lateNight: .dusk
        case .fresh:    .red
        case .find:     .mint
        case .social:   .sky
        case .clock:    .night
        case .type:     .sun
        case .tape:     .violet
        }
    }

    /// The card waits for the viewer.
    var duration: TimeInterval? {
        switch self {
        case .card:  nil
        case .hello: 5.5
        case .intro: 8.5
        case .songs, .spotify, .lateNight, .fresh, .social: 9
        default:     7.5
        }
    }

    /// Slides without data to show are left out. `tape` when the month's tape is there to open.
    static func slides(for r: RecapSnapshot, tape: Bool = false) -> [RecapSlide] {
        var s: [RecapSlide] = [.hello, .intro]
        if !r.genres.isEmpty { s.append(.genre) }
        if !r.topArtists.isEmpty { s.append(.artist) }
        if r.hooked != nil { s.append(.hooked) }
        if !r.topSongs.isEmpty { s.append(.songs) }
        if r.spotifyTop != nil { s.append(.spotify) }
        if r.onRepeat != nil { s.append(.onRepeat) }
        if r.lateNight != nil { s.append(.lateNight) }
        if r.newSongs >= 5 { s.append(.fresh) }
        if r.find != nil { s.append(.find) }
        if r.social?.isEmpty == false { s.append(.social) }
        return s + [.clock, .type] + (tape ? [.tape] : []) + [.card]
    }

    func clipWant(_ r: RecapSnapshot) -> RecapMath.ClipWant {
        switch self {
        case .songs:    r.topSongs.first.map { .song($0.trackID) } ?? .any
        case .artist:   r.topArtists.first.map { .artist($0.name) } ?? .any
        case .genre:    r.genres.first.map { .genre($0.name) } ?? .any
        case .spotify:  r.spotifyTop.map { .named($0.songs) } ?? .any
        case .onRepeat: r.onRepeat.map { .song($0.song.trackID) } ?? .any
        case .find, .fresh: r.find.map { .song($0.song.trackID) } ?? .any
        case .hooked:   r.hooked.map { .song($0.song.trackID) } ?? .any
        case .lateNight: r.lateNight.map { .song($0.song.trackID) } ?? .any
        case .intro, .clock, .type, .social, .tape: .any
        // The greeting borrows the cassette's song, see RecapClips.plan.
        case .card, .hello: .silent
        }
    }
}

struct RecapPictures {
    var songs: [UUID: PlatformImage] = [:]
    var artists: [String: PlatformImage] = [:]
    /// Spotify's top list, by image URL.
    var spotify: [String: PlatformImage] = [:]
}

// MARK: - Timing

/// Where a slide is: seconds in, the story's unit of size, and whether motion is off.
struct RecapBeat {
    let t: Double
    let u: CGFloat
    /// Reduce Motion: things still fade in and count up on time, but nothing
    /// slides, bounces, spins or drifts.
    let calm: Bool

    private func x(_ delay: Double, _ length: Double) -> Double { min(max((t - delay) / length, 0), 1) }

    /// 0 to 1 over `length` seconds from `delay`, slowing into place.
    func ease(_ delay: Double, _ length: Double = 0.7) -> Double {
        1 - pow(1 - x(delay, length), 3)
    }

    /// `ease` for something moving into place, which is already there when calm.
    func glide(_ delay: Double, _ length: Double = 0.7) -> Double {
        calm ? 1 : ease(delay, length)
    }

    /// 0 to 1 with a little overshoot.
    func pop(_ delay: Double, _ length: Double = 0.7) -> Double {
        guard !calm else { return 1 }
        let v = x(delay, length) - 1
        return 1 + 2.7 * v * v * v + 1.7 * v * v
    }

    /// A dying wiggle from `delay`, 0 before it and once it's settled.
    func wobble(_ delay: Double, freq: Double = 3, decay: Double = 5) -> Double {
        guard !calm, t > delay else { return 0 }
        let s = t - delay
        return exp(-decay * s) * sin(2 * .pi * freq * s)
    }

    /// 0 to 1, slow at both ends, for a turn that just doesn't happen when calm.
    func turn(_ delay: Double, _ length: Double) -> Double {
        guard !calm else { return 0 }
        let v = x(delay, length)
        return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2
    }

    /// Seconds of idle motion. Zero when calm, so drifting shapes rest.
    var drift: Double { calm ? 0 : t }

    /// `value` counting up from the smallest number with as many digits, so the width holds.
    func count(_ value: Int, _ delay: Double, _ length: Double = 1.1) -> String {
        let low = value < 10 ? 0 : Int(pow(10, Double(String(value).count - 1)))
        return Int((Double(low) + Double(value - low) * ease(delay, length)).rounded()).formatted()
    }
}

extension View {
    /// Fades up into place.
    fileprivate func rise(_ b: RecapBeat, _ delay: Double) -> some View {
        opacity(min(1, b.ease(delay, 0.6) * 1.8)).offset(y: (1 - b.glide(delay, 0.6)) * 7 * b.u)
    }

    /// Scales up from nothing, or fades in when calm.
    func popIn(_ b: RecapBeat, _ delay: Double, _ length: Double = 0.7) -> some View {
        scaleEffect(b.pop(delay, length)).calmFade(b, delay, length)
    }

    /// Fades in over the time it would have taken to move in, when calm.
    func calmFade(_ b: RecapBeat, _ delay: Double, _ length: Double) -> some View {
        opacity(b.calm ? b.ease(delay, length) : 1)
    }
}

/// A display face. Stretch and the flicker lean on SF's widths, so they stay on `.sans`.
private enum RecapFace {
    case sans, serif, rounded, slab, didot, poster

    private var name: String? {
        switch self {
        case .slab: "Superclarendon-Black"
        case .didot: "Didot-Italic"
        case .poster: "Futura-CondensedExtraBold"
        default: nil
        }
    }

    func font(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        switch self {
        case .serif: .system(size: size, weight: weight, design: .serif).italic()
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        default: name.map { .custom($0, fixedSize: size) } ?? .system(size: size, weight: weight)
        }
    }

    /// For measuring. An italic runs narrower than its upright, so the upright is the safe guess.
    func measured(_ size: CGFloat, _ weight: RecapFont.Weight, condensed: Bool) -> RecapFont {
        let system = RecapFont.systemFont(ofSize: size, weight: weight, width: condensed ? .condensed : .standard)
        if self == .serif { return system.fontDescriptor.withDesign(.serif).flatMap { RecapFont(descriptor: $0, size: size) } ?? system }
        return name.flatMap { RecapFont(name: $0, size: size) } ?? system
    }
}

private enum Measure {
    static func width(_ s: String, _ size: CGFloat, _ weight: RecapFont.Weight, condensed: Bool = false,
                      face: RecapFace = .sans) -> CGFloat {
        let f = face.measured(size, weight, condensed: condensed)
        return ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }

    /// The biggest size up to `max` at which every word fits `width` and the whole
    /// runs to about `lines` lines.
    static func fit(_ s: String, max: CGFloat, width: CGFloat, lines: Int,
                    weight: RecapFont.Weight = .heavy, condensed: Bool = false, face: RecapFace = .sans) -> CGFloat {
        let longest = s.split(separator: " ").map { Self.width(String($0), 100, weight, condensed: condensed, face: face) }.max() ?? 1
        let total = Self.width(s, 100, weight, condensed: condensed, face: face)
        return min(max, width * 0.96 / longest * 100, width * CGFloat(lines) * 0.85 / total * 100)
    }
}

// MARK: - Type

/// A line that lands a word at a time. Each drops in and squashes on landing, and
/// can flick through widths on the way down.
private struct Words: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .heavy
    var face = RecapFace.sans
    let delay: Double
    var centred = false
    var flicker = false
    let b: RecapBeat

    private static let widths: [Font.Width] = [.expanded, .compressed, .expanded, .condensed]

    var body: some View {
        WordFlow(spacing: size * 0.24, lineSpacing: -size * 0.1, centred: centred) {
            ForEach(Array(text.split(separator: " ").enumerated()), id: \.offset) { i, w in
                word(String(w), delay + Double(i) * 0.085)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    private func word(_ w: String, _ d: Double) -> some View {
        let step = b.t >= d ? Int((b.t - d) / 0.09) : 0
        let flick = flicker && !b.calm && b.t >= d && step < Self.widths.count
        let squash = b.wobble(d + 0.32, freq: 2.4, decay: 6)
        return Text(w)
            .font(face.font(size, weight))
            .tracking(-size * 0.02)
            .opacity(flick ? 0 : 1)
            .overlay {
                if flick {
                    Text(w).font(.system(size: size, weight: weight).width(Self.widths[step])).fixedSize()
                }
            }
            .scaleEffect(x: 1 + 0.06 * squash, y: 1 - 0.1 * squash, anchor: .bottom)
            .offset(y: -(1 - b.pop(d, 0.5)) * size * 0.6)
            .opacity(b.ease(d, 0.18))
    }
}

/// Words laid out a letter at a time, `letter` getting each character and its
/// index across the whole line.
private struct Lettering<L: View>: View {
    let text: String
    let size: CGFloat
    var centred = false
    let letter: (Character, Int) -> L

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        let starts = words.indices.map { i in words[..<i].reduce(0) { $0 + $1.count } }
        WordFlow(spacing: size * 0.22, lineSpacing: -size * 0.1, centred: centred) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                HStack(spacing: 0) {
                    ForEach(Array(w.enumerated()), id: \.offset) { j, ch in letter(ch, starts[i] + j) }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(text)
    }
}

/// A name that arrives mirrored and cut in two: each letter turns to face you while
/// its halves slide together, then a tumble runs through the letters once.
private struct Flip: View {
    let text: String
    let size: CGFloat
    var face = RecapFace.sans
    let delay: Double
    var centred = false
    let b: RecapBeat

    var body: some View {
        Lettering(text: text, size: size, centred: centred) { ch, k in letter(ch, k) }
    }

    private func letter(_ ch: Character, _ k: Int) -> some View {
        let d = delay + Double(k) * 0.05
        let p = b.glide(d, 0.75)
        let gap = (1 - p) * size * 0.45
        let glyph = Text(String(ch)).font(face.font(size))
        return glyph.hidden()
            .overlay { glyph.mask { VStack(spacing: 0) { Color.black; Color.clear } }.offset(x: -gap) }
            .overlay { glyph.mask { VStack(spacing: 0) { Color.clear; Color.black } }.offset(x: gap) }
            .rotation3DEffect(.degrees(180 * (1 - p)), axis: (x: 0, y: 1, z: 0))
            .rotation3DEffect(.degrees(360 * b.turn(delay + 1.8 + Double(k) * 0.06, 0.55)), axis: (x: 1, y: 0, z: 0))
            .opacity(b.ease(d, 0.2))
    }
}

/// A word whose letters change width, a wave running through it for a few seconds once it lands.
private struct Stretch: View {
    let text: String
    let size: CGFloat
    let delay: Double
    var centred = false
    let b: RecapBeat

    var body: some View {
        Lettering(text: text, size: size, centred: centred) { ch, k in letter(ch, k) }
    }

    private func letter(_ ch: Character, _ k: Int) -> some View {
        let d = delay + Double(k) * 0.05
        let p = b.pop(d, 0.6)
        // Lands squeezed, breathes, then rests. Stepped, so the font cache isn't handed a new width every frame.
        let rest = b.calm ? 1 : 1 - b.ease(d + 3.2, 1.2)
        let wave = sin(b.drift * 2.2 - Double(k) * 0.9) * 0.3 * b.glide(d + 0.6, 0.8) * rest
        let width = ((-0.3 * (1 - p) + wave) * 50).rounded() / 50
        return Text(String(ch))
            .font(.system(size: size, weight: .heavy).width(Font.Width(width)))
            .scaleEffect(x: 1, y: 1 + 0.3 * (1 - p), anchor: .bottom)
            .opacity(b.ease(d, 0.15))
    }
}

/// A line set letter by letter, each moving on its own before it settles.
private struct Letters: View {
    enum Move {
        /// Turns over twice like a ribbon, each letter a beat behind the last.
        case twist
        /// Bounces up out of the line and comes to rest.
        case hop
        /// Flies in from all over and falls into place.
        case scatter

        /// Seconds between one letter starting and the next.
        var stagger: Double {
            switch self {
            case .twist: 0.06
            case .hop: 0.04
            case .scatter: 0.025
            }
        }
    }

    let text: String
    let size: CGFloat
    var face = RecapFace.sans
    let move: Move
    let delay: Double
    var centred = false
    let b: RecapBeat

    var body: some View {
        Lettering(text: text, size: size, centred: centred) { ch, k in letter(ch, k) }
    }

    private func letter(_ ch: Character, _ k: Int) -> some View {
        let i = Double(k)
        let d = delay + i * move.stagger
        // The same scramble every frame for a given letter.
        let rx = (sin(i * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
        let ry = (sin(i * 78.233) * 12543.117).truncatingRemainder(dividingBy: 1)
        let fly = move == .scatter ? 1 - b.pop(d, 0.9) : 0
        let spin = move == .twist ? 720 * b.turn(d, 2.2) : 0
        let hop = move == .hop ? abs(b.wobble(d, freq: 1.4, decay: 2.4)) : 0
        return Text(String(ch)).font(face.font(size))
            .rotation3DEffect(.degrees(spin), axis: (x: 1, y: 0, z: 0))
            .rotationEffect(.degrees(fly * 220 * rx))
            .scaleEffect(1 - 0.5 * fly)
            .offset(x: fly * size * 4 * rx, y: fly * size * 3 * ry - hop * size * 0.6)
            .opacity(b.ease(d, 0.2))
    }
}

/// Squares inside squares, each turned a little further, like looking down a tunnel.
/// `depth` flies down it: a whole step brings every square to where the one outside
/// it was, so it loops without a seam.
private struct Tunnel: View {
    /// Degrees between one square and the next.
    let twist: Double
    let spin: Double
    let depth: Double

    /// Pink at the mouth to black at the end.
    private static let stops: [(Double, Double, Double)] = [
        (1, 0.48, 0.85), (1, 0.24, 0.55), (0.88, 0.09, 0.17), (0.35, 0.02, 0.06), (0.04, 0.01, 0.02),
    ]
    private static let count = 26

    private static func colour(_ x: Double, dim: Double = 1) -> Color {
        let p = min(max(x, 0), 1) * Double(stops.count - 1)
        let i = min(Int(p), stops.count - 2), f = p - Double(i)
        let (a, b) = (stops[i], stops[i + 1])
        return Color(red: (a.0 + (b.0 - a.0) * f) * dim, green: (a.1 + (b.1 - a.1) * f) * dim,
                     blue: (a.2 + (b.2 - a.2) * f) * dim)
    }

    var body: some View {
        Canvas { ctx, size in
            let side = hypot(size.width, size.height) * 1.1
            let end = CGPoint(x: -size.width * 0.16, y: -size.height * 0.18)
            let step = depth - depth.rounded(.down)
            for k in 0..<Self.count {
                let level = Double(k) - step
                let scale = pow(0.84, level)
                let s = side * scale
                let shade = level / Double(Self.count - 1)
                var layer = ctx
                // Big squares fill the screen, small ones bend away up and to the left.
                layer.translateBy(x: size.width / 2 + end.x * (1 - scale), y: size.height / 2 + end.y * (1 - scale))
                layer.rotate(by: .degrees(level * twist + spin))
                layer.fill(Path(CGRect(x: -s / 2, y: -s / 2, width: s, height: s)), with: .linearGradient(
                    Gradient(colors: [Self.colour(shade), Self.colour(shade + 0.08, dim: 0.55)]),
                    startPoint: CGPoint(x: -s / 2, y: -s / 2), endPoint: CGPoint(x: s / 2, y: s / 2)))
            }
        }
        .gpuRendered()
        .accessibilityHidden(true)
    }
}

/// A phrase set round a circle, repeated until it goes all the way round, spun in
/// and brought to a stop.
private struct Ring: View {
    let phrase: String
    let radius: CGFloat
    /// The biggest the letters can be.
    let size: CGFloat
    let delay: Double
    let b: RecapBeat

    var body: some View {
        let one = Measure.width(phrase + " • ", 100, .bold)
        let round = 2 * .pi * radius * 100
        let chars = Array(String(repeating: phrase + " • ", count: max(1, Int((round / (one * size)).rounded(.up)))))
        let advance = chars.map { Measure.width(String($0), 100, .bold) }
        let total = advance.reduce(0, +)
        let angles = advance.indices.map { i in Double((advance[..<i].reduce(0, +) + advance[i] / 2) / total * 360) }
        return ZStack {
            ForEach(chars.indices, id: \.self) { i in
                Text(String(chars[i])).font(.system(size: round / total, weight: .bold))
                    .offset(y: -radius)
                    .rotationEffect(.degrees(angles[i]))
            }
        }
        .rotationEffect(.degrees(-300 * (1 - b.glide(delay, 3.5))))
        .opacity(b.ease(delay, 0.4))
        .frame(width: radius * 2, height: radius * 2)
        .accessibilityHidden(true)
    }
}

/// A number rolled up like a tape counter. Every digit is a wheel, and each one
/// turns while the wheel to its right passes 9.
private struct Odometer: View {
    let value: Int
    let size: CGFloat
    let delay: Double
    var length = 1.6
    var anchor: UnitPoint = .leading
    let b: RecapBeat

    var body: some View {
        let p = b.ease(delay, length)
        let n = Double(value) * p
        let count = String(value).count
        let wheels = Self.wheels(n, count: count)
        let land = b.wobble(delay + length * 0.72, freq: 2.6, decay: 5.5)
        let separator = Locale.current.groupingSeparator ?? ","
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                let k = count - 1 - i
                let shown = k == 0 ? 1 : min(1, n / pow(10, Double(k)))
                Wheel(position: wheels[k]).opacity(shown)
                if k > 0, k % 3 == 0 { Text(separator).opacity(shown) }
            }
        }
        .font(.system(size: size, weight: .heavy).width(.condensed).monospacedDigit())
        .scaleEffect((0.72 + 0.28 * b.glide(delay, length)) * (1 + 0.07 * land), anchor: anchor)
        .opacity(b.ease(delay, 0.2))
        .accessibilityElement()
        .accessibilityLabel(value.formatted())
    }

    /// Each wheel's position, ones first: its digit plus how far it has turned to the next.
    static func wheels(_ n: Double, count: Int) -> [Double] {
        var out: [Double] = []
        var below = 0.0
        for k in 0..<count {
            let whole = floor(n / pow(10, Double(k))).truncatingRemainder(dividingBy: 10)
            let pos = k == 0 ? n.truncatingRemainder(dividingBy: 10) : whole + max(0, below - 9)
            out.append(pos)
            below = pos
        }
        return out
    }

    private struct Wheel: View {
        let position: Double

        var body: some View {
            let d = Int(position) % 10
            Text(verbatim: "0").hidden()
                .overlay {
                    GeometryReader { g in
                        VStack(spacing: 0) {
                            Text(verbatim: "\(d)")
                            Text(verbatim: "\((d + 1) % 10)")
                        }
                        .offset(y: -(position - floor(position)) * g.size.height)
                    }
                }
                // The line box is taller than a digit, so fade the window to the glyph.
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0.06), .init(color: .black, location: 0.26),
                                             .init(color: .black, location: 0.78), .init(color: .clear, location: 0.96)],
                                     startPoint: .top, endPoint: .bottom))
        }
    }
}

// MARK: - Bands

/// A band of colour across the whole width with the number running along it.
private struct EchoStripe: View {
    let text: String
    let fill: Color
    let ink: Color
    let height: CGFloat
    let delay: Double
    /// The side it slides in from. It runs away from that side.
    let fromLeft: Bool
    let b: RecapBeat

    var body: some View {
        let size = height * 0.8
        let gap = height * 0.9
        let item = Measure.width(text, size, .heavy, condensed: true) + gap
        let shift = (CGFloat(b.drift) * height * 1.6).truncatingRemainder(dividingBy: item)
        GeometryReader { g in
            let w = g.size.width
            HStack(spacing: gap) {
                ForEach(0..<(Int(w / item) + 3), id: \.self) { _ in Text(text) }
            }
            .font(.system(size: size, weight: .heavy).width(.condensed).monospacedDigit())
            .foregroundStyle(ink)
            .fixedSize()
            .offset(x: fromLeft ? shift - item : -shift)
            .frame(width: w, height: height, alignment: .leading)
            .background(fill)
            .clipped()
            .offset(x: (1 - b.glide(delay, 0.7)) * (fromLeft ? -w : w) * 1.05)
            .calmFade(b, delay, 0.7)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The genre mix as rows of pills gliding past, the top genre filled in.
private struct PillMarquee: View {
    let genres: [RecapSnapshot.Genre]
    let theme: RecapTheme
    let size: CGFloat
    let width: CGFloat
    let delay: Double
    let b: RecapBeat

    var body: some View {
        VStack(spacing: size * 0.7) {
            ForEach(0..<4, id: \.self) { row in rowView(row) }
        }
        .frame(width: width)
        .rotationEffect(.degrees(-4))
        .accessibilityHidden(true)
    }

    private func rowView(_ row: Int) -> some View {
        let dir: CGFloat = row % 2 == 0 ? -1 : 1
        let arrive = 1 - b.glide(delay + Double(row) * 0.12, 0.9)
        return HStack(spacing: size * 0.6) {
            ForEach(0..<14, id: \.self) { i in
                pill((i + row * 2) % genres.count)
            }
        }
        .fixedSize()
        .frame(width: width)
        .offset(x: CGFloat(row) * size * 2.6 + dir * CGFloat(b.drift) * size * 1.1 - dir * arrive * width)
        .calmFade(b, delay + Double(row) * 0.12, 0.9)
    }

    private func pill(_ i: Int) -> some View {
        let g = genres[i]
        let filled: Color? = i == 0 ? theme.acc : i % 3 == 2 ? theme.alt : nil
        return HStack(spacing: size * 0.4) {
            Text(g.name).fontWeight(.bold)
            Text("\(Int((g.share * 100).rounded()))%").opacity(0.7)
        }
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(filled == nil ? theme.fg : theme.bg)
        .padding(.horizontal, size * 0.9)
        .padding(.vertical, size * 0.45)
        .background {
            if let filled {
                Capsule().fill(filled)
            } else {
                Capsule().strokeBorder(theme.fg, lineWidth: size * 0.08)
            }
        }
    }
}

// MARK: - Shapes

/// A circle with rounded bumps round its edge: a badge, or a flower when deep.
private struct Burst: Shape {
    var bumps = 12
    var depth = 0.1

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY), radius = min(rect.width, rect.height) / 2
        let n = bumps * 12
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = radius * (1 - depth + depth * abs(cos(Double(bumps) * a / 2)))
            let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        p.closeSubpath()
        return p
    }
}

/// A four-pointed twinkle.
struct RecapSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: c)
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: c)
        return p
    }
}

private struct Zigzag: Shape {
    var peaks = 5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step = rect.width / CGFloat(peaks * 2)
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for i in 1...(peaks * 2) {
            p.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * step, y: i % 2 == 1 ? rect.minY : rect.maxY))
        }
        return p
    }
}

/// A pen loop, a little more than once round, for circling a number.
private struct Scribble: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        for i in 0...120 {
            let s = Double(i) / 120
            let a = -0.6 * .pi + s * 2.25 * .pi
            // Widens as it goes so the ends overlap instead of meeting.
            let k = 1 + 0.04 * sin(a * 3) + 0.07 * s
            let pt = CGPoint(x: c.x + rect.width / 2 * k * cos(a), y: c.y + rect.height / 2 * k * sin(a))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }
}

/// A moon a few days from new.
private struct Crescent: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: rect).subtracting(Path(ellipseIn: rect.offsetBy(dx: rect.width * 0.32, dy: -rect.height * 0.2)))
    }
}

/// A record, turned `turn` degrees.
private struct Vinyl: View {
    let label: Color
    let turn: Double

    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            func disc(_ radius: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            }
            let black = Color(hex: "151515")
            ctx.fill(disc(r), with: .color(black))
            for k in stride(from: 0.42, to: 0.97, by: 0.055) {
                ctx.stroke(disc(r * k), with: .color(.white.opacity(0.07)), lineWidth: 1)
            }
            let sheen = Gradient(colors: [.clear, .white.opacity(0.13), .clear, .clear, .white.opacity(0.13), .clear])
            ctx.fill(disc(r), with: .conicGradient(sheen, center: c, angle: .degrees(turn)))
            ctx.fill(disc(r * 0.34), with: .color(label))
            var mark = ctx
            mark.translateBy(x: c.x, y: c.y)
            mark.rotate(by: .degrees(turn))
            mark.fill(Path(roundedRect: CGRect(x: r * 0.1, y: -r * 0.025, width: r * 0.17, height: r * 0.05),
                           cornerRadius: r * 0.025), with: .color(.black.opacity(0.35)))
            ctx.fill(disc(r * 0.04), with: .color(black))
        }
        .gpuRendered()
        .accessibilityHidden(true)
    }
}

/// Cover art, or the title's initial while there's none.
struct SongCover: View {
    let image: PlatformImage?
    let title: String
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.black.opacity(0.18))
                    .overlay {
                        GeometryReader { g in
                            Text(title.prefix(1).uppercased())
                                .font(.system(size: g.size.width * 0.4, weight: .heavy))
                                .opacity(0.6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Slide changes

/// How the next slide comes in: through shapes that grow until they cover the
/// screen, with bands of its colours running just ahead of their edges.
enum RecapChange: CaseIterable {
    /// Strips painted across.
    case brush
    /// Light-speed rays out of the middle, then a circle opening.
    case warp
    /// Columns rising like a level meter.
    case bars
    /// Dots growing into square tiles, corner to corner.
    case tiles

    static let total = 1.0
    /// How far ahead of an edge each colour band runs, in seconds.
    private static let lead = 0.06

    /// Cycled, so two slides in a row never change the same way. The first change is the brush.
    static func into(_ index: Int) -> RecapChange { allCases[(index + 3) % allCases.count] }

    private static func ease(_ t: Double, _ delay: Double, _ length: Double) -> Double {
        let x = min(max((t - delay) / length, 0), 1)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    /// What of the new slide shows at `t`, always the same shapes in the same order.
        private func shapes(_ t: Double, _ size: CGSize, _ forward: Bool) -> [Path] {
        let w = size.width, h = size.height
        switch self {
        case .brush:
            let delays: [Double] = [0, 0.13, 0.04, 0.2, 0.07, 0.15, 0.03, 0.17, 0.1]
            let sh = h / 27, r = sh / 2
            return (0..<27).map { i in
                let p = Self.ease(t, delays[i / 3] + [0, 0.05, 0.017][i % 3], 0.75)
                let edge = -r + (w + 2 * r) * (1 - p)
                var rect = CGRect(x: edge, y: CGFloat(i) * sh, width: w + 3 * r - edge, height: sh + 0.5)
                if !forward { rect.origin.x = w - rect.maxX }
                return Path(roundedRect: rect, cornerRadius: rect.height / 2)
            }
        case .warp:
            let reach = hypot(w, h) / 2 + 2
            let middle = CGAffineTransform(translationX: w / 2, y: h / 2)
            let rays = (0..<24).map { k in
                let thick = reach * (0.008 + 0.006 * Double(k % 3))
                let rect = CGRect(x: reach * 0.1, y: -thick / 2, width: reach * Self.ease(t, Double(k * 7 % 24) / 24 * 0.25, 0.45),
                                  height: thick)
                return Path(roundedRect: rect, cornerRadius: thick / 2)
                    .applying(CGAffineTransform(rotationAngle: (Double(k) + 0.4) / 24 * 2 * .pi).concatenating(middle))
            }
            let r = reach * Self.ease(t, 0.3, 0.7)
            return rays + [Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)).applying(middle)]
        case .bars:
            let n = max(6, Int(w / 64)), cw = w / CGFloat(n)
            return (0..<n).map { k in
                let p = Self.ease(t, Double(k * 37 % 11) / 10 * 0.3, 0.7)
                let top = h + cw / 2 - (h + cw) * p
                var rect = CGRect(x: CGFloat(k) * cw - 0.5, y: top, width: cw + 1, height: 2 * h - top)
                if !forward { rect.origin.y = h - rect.maxY }
                return Path(roundedRect: rect, cornerRadius: cw / 2)
            }
        case .tiles:
            let side = min(w, h) / 8
            let cols = Int(ceil(w / side)), rows = Int(ceil(h / side))
            return (0..<rows * cols).map { i in
                let (row, col) = i.quotientAndRemainder(dividingBy: cols)
                let along = Double(row + col) / Double(max(rows + cols - 2, 1))
                let p = Self.ease(t, (forward ? along : 1 - along) * 0.4, 0.6)
                let s = (side + 1) * p
                let rect = CGRect(x: (CGFloat(col) + 0.5) * side - s / 2, y: (CGFloat(row) + 0.5) * side - s / 2, width: s, height: s)
                return Path(roundedRect: rect, cornerRadius: s / 2 * (1 - p))
            }
        }
    }

    /// Shows the new slide where the shapes have reached.
    struct Mask: View {
        let change: RecapChange
        let t: Double
        let forward: Bool

        var body: some View {
            Canvas { ctx, size in
                for s in change.shapes(t, size, forward) { ctx.fill(s, with: .color(.black)) }
            }
            .gpuRendered()
        }
    }

    /// Three bands of colour ahead of every edge. Goes under the new slide, which
    /// covers all but the part running ahead.
    struct Edges: View {
        let change: RecapChange
        let t: Double
        let forward: Bool
        let colours: [Color]

        var body: some View {
            Canvas { ctx, size in
                for k in (0..<3).reversed() {
                    for (i, s) in change.shapes(t + Double(k + 1) * RecapChange.lead, size, forward).enumerated() {
                        ctx.fill(s, with: .color(colours[(i + k) % colours.count]))
                    }
                }
            }
            .gpuRendered()
        }
    }
}

// MARK: - Page

/// One slide, drawn `b.t` seconds in.
struct RecapSlidePage: View {
    let slide: RecapSlide
    let r: RecapSnapshot
    let pictures: RecapPictures
    /// The listener's first name.
    let name: String
    /// False for a friend's recap.
    var mine = true
    let b: RecapBeat
    let size: CGSize
    let mac: Bool

    private var theme: RecapTheme { slide.theme }
    private var u: CGFloat { b.u }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            if mac {
                RadialGradient(colors: [theme.fg.opacity(0.07), .clear],
                               center: UnitPoint(x: 0.5, y: 0.45), startRadius: 0,
                               endRadius: max(size.width, size.height) * 0.55)
                    .ignoresSafeArea()
            }
            content
        }
        .foregroundStyle(theme.fg)
    }

    @ViewBuilder private var content: some View {
        switch slide {
        case .hello:    hello
        case .intro:    intro
        case .genre:    genre
        case .artist:   artist
        case .songs:    songs
        case .spotify:  spotify
        case .onRepeat: onRepeat
        case .find:     find
        case .hooked:   hooked
        case .lateNight: lateNight
        case .fresh:    fresh
        case .social:   social
        case .clock:    clock
        case .type:     type
        case .tape:     tape
        case .card:     EmptyView()
        }
    }

    // MARK: Type scale

    private var labelSize: CGFloat { (mac ? 3.1 : 4.2) * u }
    private var bodySize: CGFloat { (mac ? 3.7 : 4.6) * u }
    private var titleMax: CGFloat { (mac ? 12 : 15) * u }
    /// The text column's width.
    private var column: CGFloat { mac ? (size.width - 208 - 64) / 2 : size.width - 14 * u }
    private var gap: CGFloat { size.height * 0.022 }
    private var monthName: String { Calendar.current.monthSymbols[r.monthNumber - 1] }

    private func label(_ s: String, _ d: Double) -> some View {
        Text(s).font(.system(size: labelSize, weight: .semibold)).foregroundStyle(theme.soft).rise(b, d)
    }

    /// A sentence. `say` is what VoiceOver reads while a number in it is still counting.
    private func line(_ s: String, _ d: Double, soft: Bool = false, say: String? = nil) -> some View {
        Text(s).font(.system(size: bodySize, weight: .medium)).monospacedDigit()
            .foregroundStyle(soft ? theme.soft : theme.fg)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(say ?? s)
            .rise(b, d)
    }

    /// Big words, dropped in a word at a time, or a letter at a time with `move`.
    @ViewBuilder
    private func title(_ s: String, _ d: Double, max: CGFloat? = nil, width: CGFloat? = nil, lines: Int = 2,
                       face: RecapFace = .sans, move: Letters.Move? = nil,
                       flicker: Bool = false, centred: Bool = false) -> some View {
        // Letters set one by one lose their kerning, so they get a little more room.
        let size = Measure.fit(s, max: max ?? titleMax, width: (width ?? column) * (move == nil ? 1 : 0.94),
                               lines: lines, face: face)
        if let move {
            Letters(text: s, size: size, face: face, move: move, delay: d, centred: centred, b: b)
        } else {
            Words(text: s, size: size, face: face, delay: d, centred: centred, flicker: flicker, b: b)
        }
    }

    /// A song name on one line, and what it did underneath.
    private func headline(_ song: String, _ phrase: String, _ d: Double, face: RecapFace) -> some View {
        VStack(alignment: .leading, spacing: 1.2 * u) {
            title(song, d, lines: 1, face: face)
            Text(phrase).font(.system(size: 5.5 * u, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .rise(b, d + 0.5)
        }
    }

    /// Cover art on the slide's colour, so a missing picture doesn't show what's behind it.
    private func cover(_ image: PlatformImage?, _ title: String, _ side: CGFloat, radius: CGFloat) -> some View {
        SongCover(image: image, title: title, radius: radius)
            .frame(width: side, height: side)
            .background(theme.bg, in: RoundedRectangle(cornerRadius: radius))
    }

    /// iOS: one column. Mac: text and artwork side by side.
    private func split<T: View, A: View>(artFirst: Bool, centred: Bool = false,
                                         @ViewBuilder text: () -> T, @ViewBuilder art: () -> A) -> some View {
        let words = VStack(alignment: centred ? .center : .leading, spacing: gap) { text() }
            .multilineTextAlignment(centred ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
        let picture = art().frame(maxWidth: .infinity)
        return Group {
            if mac {
                HStack(spacing: 64) {
                    if artFirst { picture; words } else { words; picture }
                }
                .padding(.top, 84).padding(.horizontal, 104).padding(.bottom, 92)
            } else {
                VStack(spacing: gap * 1.6) {
                    if artFirst { picture; words } else { words; picture }
                }
                .padding(.top, 68).padding(.horizontal, 7 * u).padding(.bottom, 76)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hello

    private var hello: some View {
        let greeting = mine ? (name.isEmpty ? "Hi there" : "Hi \(name)") : "\(name)'s \(monthName)"
        let wide = mac ? size.width * 0.5 : size.width - 14 * u
        // Unwinds out of the dark, drifts inward, then dives in before the cassette.
        let depth = b.drift * 0.3 - 2 * (1 - b.glide(0, 1.6)) + 3 * b.glide(4.2, 1.2)
        return ZStack {
            Tunnel(twist: 9 * b.glide(0, 1.6), spin: b.drift * 5, depth: depth)
                .ignoresSafeArea()
            RadialGradient(colors: [theme.bg.opacity(0.75), .clear], center: .center,
                           startRadius: 0, endRadius: max(wide, size.height * 0.3) * 0.7)
                .ignoresSafeArea()
            VStack(spacing: 3 * u) {
                Words(text: greeting, size: Measure.fit(greeting, max: (mac ? 13 : 16) * u, width: wide, lines: 2),
                      delay: 0.9, centred: true, b: b)
                    .frame(maxWidth: wide)
                Text(mine ? "Your \(monthName) recap is ready. Are you?" : "Here's how their month sounded.")
                    .font(.system(size: bodySize, weight: .medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: wide)
                    .rise(b, 1.7)
            }
        }
    }

    // MARK: Intro

    private var intro: some View {
        let exit = b.ease(2.15, 0.45)
        return ZStack {
            if exit < 1 {
                introTape
                    .opacity(1 - exit)
                    .scaleEffect(1 + (b.calm ? 0 : 0.25 * exit))
                    .offset(y: b.calm ? 0 : -exit * size.height * 0.12)
            }
            if b.t > 2.3 { introMinutes }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A cassette rewinding through the month.
    private var introTape: some View {
        let width = mac ? min(size.width * 0.4, size.height * 0.62) : 74 * u
        return VStack(spacing: 5 * u) {
            RecapCassette(month: "\(monthName) \(r.year)", name: name, reel: -b.drift * 3.2, wound: 1 - b.ease(0.3, 1.8))
                .frame(width: width)
                .overlay(alignment: .topTrailing) {
                    RecapSparkle().fill(theme.acc)
                        .frame(width: 14 * u, height: 14 * u)
                        .rotationEffect(.degrees(b.drift * 40))
                        .popIn(b, 0.5, 0.6)
                        .offset(x: 5 * u, y: -6 * u)
                }
                .overlay(alignment: .topLeading) {
                    Zigzag().trim(from: 0, to: b.ease(0.7, 0.6))
                        .stroke(theme.shape, style: StrokeStyle(lineWidth: 1.6 * u, lineCap: .round, lineJoin: .round))
                        .frame(width: 20 * u, height: 5 * u)
                        .offset(x: -3 * u, y: -9 * u)
                }
                .popIn(b, 0.05, 0.7)
                .rotationEffect(.degrees(-4 + 3 * b.wobble(0.4, freq: 1.6, decay: 3)))
            Words(text: "Rewinding your \(monthName)", size: (mac ? 6 : 8) * u, weight: .bold, face: .serif,
                  delay: 0.55, centred: true, b: b)
                .frame(maxWidth: width * 1.3)
        }
    }

    private var introMinutes: some View {
        let stripe = (mac ? 5.2 : 6.4) * u
        let number = r.minutes.formatted()
        let wide = mac ? size.width * 0.6 : size.width - 14 * u
        let numSize = Measure.fit(number, max: (mac ? 24 : 30) * u, width: wide, lines: 1, condensed: true)
        let lead = (mac ? 5.5 : 8) * u
        return VStack(spacing: 2.4 * u) {
            Words(text: "You listened for", size: lead, weight: .bold, delay: 2.45, centred: true, b: b)
            VStack(spacing: 1.2 * u) {
                EchoStripe(text: number, fill: theme.fg, ink: theme.bg, height: stripe, delay: 4.2, fromLeft: true, b: b)
                EchoStripe(text: number, fill: theme.shape, ink: theme.bg, height: stripe, delay: 4.3, fromLeft: false, b: b)
            }
            Odometer(value: r.minutes, size: numSize, delay: 2.8, anchor: .center, b: b)
                .foregroundStyle(theme.acc)
            VStack(spacing: 1.2 * u) {
                EchoStripe(text: number, fill: theme.alt, ink: theme.bg, height: stripe, delay: 4.35, fromLeft: true, b: b)
                EchoStripe(text: number, fill: theme.acc, ink: theme.bg, height: stripe, delay: 4.45, fromLeft: false, b: b)
            }
            Words(text: r.minutes == 1 ? "minute" : "minutes", size: lead, weight: .bold, delay: 4.35, centred: true, b: b)
            Text(introFoot)
                .font(.system(size: bodySize, weight: .medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: mac ? 560 : .infinity)
                .padding(.horizontal, 7 * u)
                .rise(b, 5.0)
        }
        .padding(.top, mac ? 84 : 68).padding(.bottom, mac ? 92 : 76)
    }

    private var introFoot: String {
        let days = r.minutes / 1440, hours = r.minutes % 1440 / 60
        let parts = [days > 0 ? plural(days, "day") : nil, hours > 0 ? plural(hours, "hour") : nil].compactMap { $0 }
        let tail = "over \(plural(r.plays, "play")) of \(r.songs.formatted()) different songs."
        return parts.isEmpty ? "That's \(tail)" : "That's \(parts.joined(separator: " and ")), \(tail)"
    }

    // MARK: Genre

    private var genre: some View {
        let top = r.genres[0]
        let pct = Int((top.share * 100).rounded())
        let wide = mac ? size.width * 0.62 : column
        let say = { (n: String) in "That's \(n)% of your genre mix." }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: gap) {
                label("Your top genre", 0.1)
                // Room left for the widest breath of the wave.
                Stretch(text: top.name, size: Measure.fit(top.name, max: titleMax, width: wide * 0.85, lines: 2), delay: 0.3, b: b)
                line(say(b.count(pct, 0.9, 0.8)), 0.8, say: say("\(pct)"))
            }
            .frame(maxWidth: wide, alignment: .leading)
            .padding(.horizontal, mac ? 104 : 7 * u)
            .padding(.top, mac ? 108 : 96)
            Spacer(minLength: 0)
            PillMarquee(genres: r.genres, theme: theme, size: (mac ? 3.4 : 6) * u, width: size.width, delay: 1.3, b: b)
            Spacer(minLength: 0)
            Spacer(minLength: 0).frame(height: mac ? 60 : 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Artist

    private var artist: some View {
        let a = r.topArtists[0]
        let say = { (m: String, s: String) in
            "You spent \(m) minute\(a.minutes == 1 ? "" : "s") with them, across \(s) song\(a.songs == 1 ? "" : "s")."
        }
        return split(artFirst: true, centred: !mac) {
            label("Your top artist", 0.1)
            Flip(text: a.name, size: Measure.fit(a.name, max: titleMax, width: column * 0.94, lines: 2, face: .slab),
                 face: .slab, delay: 0.9, centred: !mac, b: b)
            line(say(b.count(a.minutes, 1.6), b.count(a.songs, 1.6)), 1.5,
                 say: say(a.minutes.formatted(), a.songs.formatted()))
            line(moveLine(a.move), 2.2, soft: true)
        } art: {
            artistArt(a)
        }
    }

    private func moveLine(_ move: Int?) -> String {
        let last = Calendar.current.monthSymbols[(r.monthNumber + 10) % 12]
        guard let move else { return "New to your top artists this month." }
        if move > 0 { return "Up \(plural(move, "place")) on \(last)." }
        if move < 0 { return "Down \(plural(-move, "place")) from \(last)." }
        return "Same spot as \(last)."
    }

    private func artistArt(_ a: RecapSnapshot.Artist) -> some View {
        let side = (mac ? 40 : 46) * u
        let orbit = b.drift * 0.8 + .pi * 0.85
        return ZStack {
            RoundedRectangle(cornerRadius: 3 * u).fill(theme.alt)
                .frame(width: side, height: side)
                .rotationEffect(.degrees(7 + 2 * sin(b.drift * 0.9)))
                .offset(x: 3.5 * u, y: 3.5 * u)
                .popIn(b, 0.1, 0.7)
            cover(pictures.artists[a.name], a.name, side, radius: 2 * u)
                .shadow(color: .black.opacity(0.25), radius: 4 * u, y: 3 * u)
                .rotationEffect(.degrees(-3))
                .popIn(b, 0.2, 0.7)
            ZStack {
                Burst(bumps: 12, depth: 0.12).fill(theme.shape)
                    .rotationEffect(.degrees(b.drift * 18))
                Text("#1").font(.system(size: 5.2 * u, weight: .heavy))
            }
            .frame(width: 15 * u, height: 15 * u)
            .rotationEffect(.degrees(-10))
            .popIn(b, 0.75, 0.6)
            .offset(x: side * 0.5, y: -side * 0.48)
            RecapSparkle().fill(theme.fg)
                .frame(width: 6 * u, height: 6 * u)
                .scaleEffect(1 + 0.15 * sin(b.drift * 4))
                .popIn(b, 1.0, 0.5)
                .offset(x: cos(orbit) * side * 0.74, y: sin(orbit) * side * 0.68)
        }
        .frame(width: side * 1.4, height: side * 1.3)
    }

    // MARK: Songs

    private struct Row {
        let title: String
        let artist: String
        let image: PlatformImage?
        let plays: Int?
    }

    /// Row size: the Mac list sits in half the width.
    private var su: CGFloat { mac ? min(size.height * 0.007, size.width * 0.004) : u }

    private var songs: some View {
        let first = r.topSongs[0]
        let list = r.topSongs.map { Row(title: $0.title, artist: $0.artist, image: pictures.songs[$0.trackID], plays: $0.plays) }
        return split(artFirst: false) {
            label("Your top songs", 0.1)
            if mac {
                headline(first.title, "was the one.", 0.3, face: .poster)
                line(plural(first.plays, "play") + "."
                     + (r.tapeMatches ? " Your \(monthName) Tape starts with these five." : ""), 1.1, soft: true)
            }
        } art: {
            rows(list)
        }
    }

    private var spotify: some View {
        let top = r.spotifyTop!
        let artists = ListFormatter.localizedString(byJoining: top.artists.prefix(3).map(\.name))
        let list = top.songs.map { Row(title: $0.title, artist: $0.artist, image: $0.image.flatMap { pictures.spotify[$0] }, plays: nil) }
        return split(artFirst: false) {
            label("On Spotify", 0.1)
            if mac, let first = top.songs.first {
                headline(first.title, "by \(first.artist) topped your Spotify.", 0.3, face: .serif)
            }
            if !artists.isEmpty { line("Your top artists there: \(artists).", 3.4, soft: mac) }
        } art: {
            rows(list)
        }
    }

    /// A countdown: fifth place slides in first, the top song last.
    private func rows(_ list: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 3.2 * su) {
            ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { i, row in
                let d = [3.0, 2.3, 1.7, 1.1, 0.5][i]
                rowView(row, rank: i + 1, delay: d)
                    .offset(x: (1 - b.pop(d, 0.6)) * 30 * su)
                    .opacity(b.ease(d, 0.25))
            }
        }
    }

    private func rowView(_ row: Row, rank: Int, delay: Double) -> some View {
        let first = rank == 1
        let side = (first ? 22 : 15) * su
        return HStack(spacing: 3.2 * su) {
            Text("\(rank)")
                .font(.system(size: (first ? 12 : 7.5) * su, weight: .heavy).width(.condensed))
                .foregroundStyle(first ? theme.acc : theme.soft)
                .frame(width: 8 * su)
            ZStack {
                if first {
                    Burst(bumps: 10, depth: 0.14).fill(theme.alt)
                        .frame(width: side * 1.2, height: side * 1.2)
                        .rotationEffect(.degrees(b.drift * 22))
                        .popIn(b, delay + 0.25, 0.6)
                }
                cover(row.image, row.title, side, radius: 1.4 * su)
            }
            .frame(width: side, height: side)
            VStack(alignment: .leading, spacing: 0.3 * su) {
                Text(row.title).font(.system(size: (first ? 6.4 : 4.7) * su, weight: .bold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.artist).font(.system(size: 3.6 * su, weight: .medium)).foregroundStyle(theme.soft).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let plays = row.plays {
                Text(plural(plays, "play"))
                    .font(.system(size: 3.4 * su, weight: .medium)).monospacedDigit()
                    .foregroundStyle(theme.soft)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: On repeat

    private var onRepeat: some View {
        let rep = r.onRepeat!
        return split(artFirst: true) {
            label("On repeat", 0.1)
            songName(rep.song, 0.5, face: .poster, move: .twist)
            HStack(alignment: .lastTextBaseline, spacing: 2 * u) {
                Odometer(value: rep.count, size: (mac ? 18 : 20) * u, delay: 1.3, length: 1.0, b: b)
                    .foregroundStyle(theme.acc)
                Words(text: rep.count == 1 ? "time" : "times", size: (mac ? 7 : 8) * u, delay: 2.1, b: b)
                    .fixedSize()
            }
            .padding(.horizontal, 3 * u)
            .background {
                Scribble().trim(from: 0, to: b.ease(2.4, 0.7))
                    .stroke(theme.alt, style: StrokeStyle(lineWidth: 0.9 * u, lineCap: .round, lineJoin: .round))
                    .padding(.horizontal, -1.5 * u).padding(.vertical, -0.5 * u)
            }
            line("in one day, on \(longDate(rep.day)).", 2.6)
            line("We're not judging.", 3.3, soft: true)
        } art: {
            repeatArt(rep.song)
        }
    }

    private func songName(_ song: RecapSnapshot.Song, _ d: Double, face: RecapFace = .sans,
                          move: Letters.Move? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0.6 * u) {
            title(song.title, d, max: (mac ? 10 : 11) * u, face: face, move: move)
            Text(song.artist).font(.system(size: bodySize, weight: .semibold)).foregroundStyle(theme.soft)
                .rise(b, d + 0.3)
        }
    }

    private func repeatArt(_ song: RecapSnapshot.Song) -> some View {
        let side = (mac ? 38 : 44) * u
        let out = b.glide(0.6, 0.9)
        return ZStack {
            Vinyl(label: theme.shape, turn: b.drift * 200)
                .frame(width: side * 0.94, height: side * 0.94)
                .offset(x: side * 0.42 * out)
                .opacity(b.ease(0.5, 0.2))
            cover(pictures.songs[song.trackID], song.title, side, radius: 2 * u)
                .shadow(color: .black.opacity(0.28), radius: 5 * u, y: 4 * u)
                .rotationEffect(.degrees(-4))
                .popIn(b, 0.15, 0.6)
            RecapSparkle().fill(theme.shape)
                .frame(width: 9 * u, height: 9 * u)
                .scaleEffect(1 + 0.14 * sin(b.drift * 4))
                .popIn(b, 1.0, 0.5)
                .rotationEffect(.degrees(b.drift * 30))
                .offset(x: -side * 0.55, y: -side * 0.5)
        }
        .offset(x: -side * 0.2 * out)
        .frame(width: side * 1.5, height: side * 1.15)
    }

    // MARK: Find

    private var find: some View {
        let f = r.find!
        return split(artFirst: true) {
            label("Find of the month", 0.1)
            songName(f.song, 0.5, face: .rounded, move: .scatter)
            line("First played on \(longDate(f.firstPlayed)), and \(plural(f.song.plays, "play")) since.", 1.4)
            line(r.newSongs > 1 ? "Your most played of the \(r.newSongs.formatted()) new ones."
                                : "The only new song you heard this month.", 2.0, soft: true)
        } art: {
            findArt(f.song)
        }
    }

    private func findArt(_ song: RecapSnapshot.Song) -> some View {
        let side = (mac ? 38 : 44) * u
        return ZStack {
            Burst(bumps: 8, depth: 0.3).fill(theme.shape)
                .frame(width: side * 1.45, height: side * 1.45)
                .rotationEffect(.degrees(b.drift * 14))
                .popIn(b, 0.05, 0.8)
            cover(pictures.songs[song.trackID], song.title, side, radius: 2 * u)
                .shadow(color: .black.opacity(0.25), radius: 5 * u, y: 4 * u)
                .rotationEffect(.degrees(3))
                .popIn(b, 0.25, 0.6)
            ZStack {
                Burst(bumps: 14, depth: 0.1).fill(theme.alt)
                    .rotationEffect(.degrees(-b.drift * 30))
                Text("New").font(.system(size: 4.2 * u, weight: .heavy)).foregroundStyle(.white)
            }
            .frame(width: 15 * u, height: 15 * u)
            .rotationEffect(.degrees(-12))
            .popIn(b, 0.9, 0.5)
            .offset(x: side * 0.48, y: -side * 0.48)
        }
        .frame(width: side * 1.5, height: side * 1.5)
    }

    // MARK: Setup and payoff

    /// A line on its own, big and centred, that clears away at `out` for what it sets up.
    private func setup<C: View>(_ s: String, out: Double, face: RecapFace, move: Letters.Move? = nil,
                                @ViewBuilder then: () -> C) -> some View {
        let exit = b.ease(out, 0.45)
        let wide = mac ? size.width * 0.6 : column
        return ZStack {
            if exit < 1 {
                title(s, 0.2, max: (mac ? 9 : 11) * u, width: wide, lines: 3, face: face, move: move, centred: true)
                    .frame(width: wide)
                    .opacity(1 - exit)
                    .scaleEffect(1 + (b.calm ? 0 : 0.1 * exit))
                    .offset(y: b.calm ? 0 : -exit * size.height * 0.08)
            }
            if b.t > out { then() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Hooked

    private var hooked: some View {
        let h = r.hooked!
        let wide = mac ? size.width * 0.56 : column
        let numSize = (mac ? 24 : 32) * u
        let side = (mac ? 20 : 26) * u
        let sentence = "of your \(h.artist) plays were one song."
        return VStack(spacing: gap * 1.4) {
            label("Hooked", 0.1)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Odometer(value: h.pct, size: numSize, delay: 0.3, length: 1.2, anchor: .center, b: b)
                Text("%").font(.system(size: numSize * 0.45, weight: .heavy)).rise(b, 1.1)
            }
            .foregroundStyle(theme.acc)
            Words(text: sentence, size: Measure.fit(sentence, max: (mac ? 7 : 8.5) * u, width: wide, lines: 2, face: .serif),
                  face: .serif, delay: 1.2, centred: true, b: b)
                .frame(width: wide)
            let row = mac ? AnyLayout(HStackLayout(spacing: 4 * u)) : AnyLayout(VStackLayout(spacing: 2 * u))
            row {
                ZStack {
                    Ring(phrase: "on a loop", radius: side * 0.98, size: (mac ? 2.6 : 3.4) * u, delay: 2.2, b: b)
                    Burst(bumps: 10, depth: 0.14).fill(theme.alt)
                        .frame(width: side * 1.4, height: side * 1.4)
                        .rotationEffect(.degrees(b.drift * 22))
                        .popIn(b, 2.3, 0.6)
                    cover(pictures.songs[h.song.trackID], h.song.title, side, radius: 1.6 * u)
                        .rotationEffect(.degrees(-4))
                        .popIn(b, 2.1, 0.6)
                }
                VStack(alignment: mac ? .leading : .center, spacing: 0.4 * u) {
                    Text(h.song.title).font(.system(size: bodySize * 1.3, weight: .heavy)).lineLimit(2)
                    Text(plural(h.song.plays, "play")).font(.system(size: bodySize, weight: .medium))
                        .foregroundStyle(theme.soft)
                }
                .multilineTextAlignment(mac ? .leading : .center)
                .rise(b, 2.4)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, mac ? 84 : 68).padding(.bottom, mac ? 92 : 76)
    }

    // MARK: Late night

    private var lateNight: some View {
        let l = r.lateNight!
        let o = 2.6
        return setup("Some songs only make sense after dark.", out: 2.3, face: .didot) {
            split(artFirst: true) {
                label("Your late-night anthem", o)
                songName(l.song, o + 0.3, face: .serif)
                line("Played \(plural(l.plays, "time")) between \(RecapClock.hourName(RecapMath.lateStart)) and 4am.", o + 1.1)
                line("Sleep can wait.", o + 1.8, soft: true)
            } art: {
                nightArt(l.song, o)
            }
        }
    }

    private func nightArt(_ song: RecapSnapshot.Song, _ d: Double) -> some View {
        let side = (mac ? 36 : 42) * u
        let stars: [(x: CGFloat, y: CGFloat, size: CGFloat)] = [(-0.62, -0.42, 5), (0.7, 0.12, 4), (-0.52, 0.6, 3.5), (0.2, -0.72, 3)]
        return ZStack {
            Crescent().fill(theme.acc)
                .frame(width: side * 0.5, height: side * 0.5)
                .rotationEffect(.degrees(-20 + 6 * sin(b.drift * 0.8)))
                .offset(x: side * 0.62, y: -side * 0.5)
                .popIn(b, d + 0.5, 0.7)
            cover(pictures.songs[song.trackID], song.title, side, radius: 2 * u)
                .shadow(color: .black.opacity(0.4), radius: 5 * u, y: 4 * u)
                .rotationEffect(.degrees(-3))
                .popIn(b, d, 0.6)
            ForEach(stars.indices, id: \.self) { i in
                RecapSparkle().fill(i % 2 == 0 ? theme.fg : theme.alt)
                    .frame(width: stars[i].size * u, height: stars[i].size * u)
                    .scaleEffect(0.7 + 0.3 * abs(sin(b.drift * 1.8 + Double(i) * 1.3)))
                    .popIn(b, d + 0.8 + Double(i) * 0.15, 0.5)
                    .offset(x: side * stars[i].x, y: side * stars[i].y)
            }
        }
        .frame(width: side * 1.8, height: side * 1.5)
    }

    // MARK: New songs

    private var fresh: some View {
        let o = 3.0
        let wide = mac ? size.width * 0.6 : column
        let numSize = Measure.fit(r.newSongs.formatted(), max: (mac ? 26 : 34) * u, width: wide, lines: 1, condensed: true)
        let corners: [Alignment] = [.topLeading, .topTrailing, .bottomTrailing, .bottomLeading]
        return setup("You went looking for something new.", out: 2.7, face: .poster, move: .scatter) {
            VStack(spacing: gap) {
                label("New to you", o)
                Odometer(value: r.newSongs, size: numSize, delay: o + 0.1, anchor: .center, b: b)
                    .overlay {
                        ForEach(0..<4, id: \.self) { i in
                            RecapSparkle().fill(i % 2 == 0 ? theme.shape : theme.alt)
                                .frame(width: (i % 2 == 0 ? 9 : 6) * u, height: (i % 2 == 0 ? 9 : 6) * u)
                                .rotationEffect(.degrees(b.drift * (i % 2 == 0 ? 25 : -35)))
                                .popIn(b, o + 1.0 + Double(i) * 0.12, 0.5)
                                .offset(x: (i == 0 || i == 3 ? -6 : 6) * u, y: (i < 2 ? 0 : 1) * 3 * u)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corners[i])
                        }
                    }
                Words(text: "songs you'd never played before", size: (mac ? 6 : 7.5) * u, weight: .bold,
                      delay: o + 1.3, centred: true, b: b)
                    .frame(width: wide)
                line(perDay, o + 2.0, soft: true)
            }
            .multilineTextAlignment(.center)
        }
    }

    private var perDay: String {
        let start = Calendar.current.date(from: DateComponents(year: r.year, month: r.monthNumber)) ?? .now
        let rate = Double(r.newSongs) / Double(Calendar.current.range(of: .day, in: .month, for: start)?.count ?? 30)
        if rate >= 1.5 { return "About \(Int(rate.rounded())) a day." }
        return rate >= 0.75 ? "About one a day." : "About one every \(Int((1 / rate).rounded())) days."
    }

    // MARK: Together

    private var social: some View {
        let s = r.social!
        let o = 2.9
        let width = mac ? min(size.width * 0.5, 64 * u) : column
        let rows = [(n: s.hosted, one: "Jam you started", many: "Jams you started"),
                    (n: s.joined, one: "Jam you joined", many: "Jams you joined"),
                    (n: s.shared, one: "song you sent a friend", many: "songs you sent to friends")].filter { $0.n > 0 }
        let fills = [(theme.shape, theme.fg), (theme.fg, theme.bg), (theme.alt, theme.fg)]
        return setup("You didn't listen alone.", out: 2.6, face: .rounded, move: .hop) {
            VStack(spacing: 2.4 * u) {
                label("Together", o)
                ForEach(rows.indices, id: \.self) { i in
                    let row = rows[i], d = o + 0.3 + Double(i) * 0.3
                    tile(b.count(row.n, d + 0.1, 0.6), row.n == 1 ? row.one : row.many, say: "\(row.n)",
                         fill: fills[i].0, ink: fills[i].1, tilt: [-3, 2.5, -1.5][i], x: [-2.5, 2.5, -1][i] * u,
                         delay: d, width: width)
                }
            }
        }
    }

    // MARK: Clock

    private var clock: some View {
        let block = RecapMath.clockBlock(r.playsByHour)
        let say = { (n: String) in "\(n)% of your plays were \(block.block.span)." }
        return split(artFirst: true) {
            label("When you listen", 0.1)
            title(block.block.title, 1.6, flicker: true)
            line(say(b.count(block.pct, 1.9, 0.8)), 1.9, say: say("\(block.pct)"))
        } art: {
            RecapClock(playsByHour: r.playsByHour, hot: Set(block.block.hours),
                       size: mac ? min(column, 62 * u) : 76 * u, theme: theme, b: b)
        }
    }

    // MARK: Type

    private var type: some View {
        let loyal = r.loyalPct >= 50
        let pct = loyal ? r.loyalPct : 100 - r.loyalPct
        let numSize = (mac ? 20 : 24) * u
        return split(artFirst: false) {
            label("Your listening type", 0.1)
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Odometer(value: pct, size: numSize, delay: 0.3, length: 1.2, b: b)
                Text("%").font(.system(size: numSize * 0.45, weight: .heavy)).rise(b, 1.1)
            }
            .foregroundStyle(theme.acc)
            .padding(.horizontal, 3 * u)
            .background {
                Scribble().trim(from: 0, to: b.ease(1.3, 0.7))
                    .stroke(theme.shape, style: StrokeStyle(lineWidth: 0.9 * u, lineCap: .round, lineJoin: .round))
                    .padding(.horizontal, -1.5 * u).padding(.vertical, -0.5 * u)
            }
            Stretch(text: loyal ? "loyal" : "new", size: (mac ? 11 : 13) * u, delay: 1.4, b: b)
            line("Most of \(monthName) was "
                 + (loyal ? "songs you already knew." : "songs you'd never played before."), 1.9)
        } art: {
            tiles
        }
    }

    /// Three stickers, one per quirk.
    private var tiles: some View {
        let width = mac ? min(column, 64 * u) : column
        let day = Calendar.current.weekdaySymbols[r.busiestWeekday - 1]
        return VStack(spacing: 2.4 * u) {
            tile(b.count(r.bestStreak, 2.4, 0.6), r.bestStreak == 1 ? "day in a row, your longest streak" : "days in a row, your longest streak",
                 say: "\(r.bestStreak)", fill: theme.shape, ink: theme.fg, tilt: -3, x: -2.5 * u, delay: 2.3, width: width)
            tile(day, "was your busiest day of the week",
                 say: day, fill: theme.fg, ink: theme.bg, tilt: 2.5, x: 2.5 * u, delay: 2.6, width: width)
            tile("\(b.count(r.topDevicePct, 3.0, 0.6))%", "of your plays were on \(r.topDevice)",
                 say: "\(r.topDevicePct)%", fill: theme.alt, ink: theme.fg, tilt: -1.5, x: -1 * u, delay: 2.9, width: width)
        }
    }

    private func tile(_ value: String, _ text: String, say: String, fill: Color, ink: Color,
                      tilt: Double, x: CGFloat, delay: Double, width: CGFloat) -> some View {
        let p = b.pop(delay, 0.6)
        return HStack(alignment: .center, spacing: 3 * u) {
            Text(value)
                .font(.system(size: (mac ? 7 : 8) * u, weight: .heavy).width(.condensed)).monospacedDigit()
                .lineLimit(1).fixedSize()
            Text(text)
                .font(.system(size: (mac ? 3.2 : 3.9) * u, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 4 * u).padding(.vertical, 3 * u)
        .frame(width: width * 0.9, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 3 * u))
        .rotationEffect(.degrees(tilt + (1 - p) * 8))
        .scaleEffect(p)
        .offset(x: x)
        .opacity(b.ease(delay, 0.2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(say) \(text)")
    }

    // MARK: Tape

    /// The month's top 25 as a playlist, leaving the bottom for the story's button.
    private var tape: some View {
        let side = mac ? min(size.height * 0.3, size.width * 0.2) : 56 * u
        let wide = mac ? size.width * 0.5 : column
        // The top three fan out from behind it, like on the Home card.
        let spots: [(x: CGFloat, y: CGFloat, tilt: Double)] = [(-0.42, -0.12, -12), (0.44, -0.2, 10), (0.3, 0.34, 5)]
        return VStack(spacing: gap * 1.4) {
            ZStack {
                ForEach(Array(r.topSongs.prefix(3).enumerated()), id: \.offset) { i, song in
                    let out = b.glide(0.5 + Double(i) * 0.12, 0.8)
                    cover(pictures.songs[song.trackID], song.title, side * 0.6, radius: 1.2 * u)
                        .rotationEffect(.degrees(spots[i].tilt * out))
                        .offset(x: spots[i].x * side * out, y: spots[i].y * side * out)
                        .opacity(b.ease(0.5 + Double(i) * 0.12, 0.3))
                }
                RoundedRectangle(cornerRadius: side * 0.06, style: .continuous)
                    .fill(theme.acc)
                    .frame(width: side, height: side)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(Calendar.current.shortMonthSymbols[r.monthNumber - 1].uppercased())
                                .font(.system(size: side * 0.3, weight: .heavy))
                            Text(String(r.year))
                                .font(.system(size: side * 0.13, weight: .semibold))
                                .opacity(0.8)
                        }
                        .foregroundStyle(theme.bg)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 3 * u, y: 1.5 * u)
                    .rotationEffect(.degrees(-3 + 4 * b.wobble(0.1, freq: 1.4, decay: 3)))
                    .popIn(b, 0.1, 0.7)
            }
            .frame(width: side * 1.8, height: side * 1.4)
            .accessibilityHidden(true)
            title("Your \(monthName) Tape", 0.9, width: wide, face: .serif, centred: true)
                .frame(maxWidth: wide)
            line("The \(min(25, r.songs)) songs you played most in \(monthName).", 1.6, soft: true)
                .multilineTextAlignment(.center)
                .frame(maxWidth: wide)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, mac ? 60 : 56)
        .padding(.bottom, RecapTapeButton.room(mac: mac))
    }

    // MARK: Words

    private func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func plural(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }
}

/// The tape slide's way to the playlist. The story draws it over its tap layer, in
/// the room the slide leaves at the bottom.
struct RecapTapeButton: View {
    let theme: RecapTheme
    let mac: Bool
    let action: () -> Void

    private static let height: CGFloat = 48
    private static func bottom(mac: Bool) -> CGFloat { mac ? 64 : 48 }
    static func room(mac: Bool) -> CGFloat { bottom(mac: mac) + height + 24 }

    var body: some View {
        Button(action: action) {
            Text("Open your tape")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(theme.bg)
                .padding(.horizontal, 28)
                .frame(height: Self.height)
                .background(theme.fg, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, Self.bottom(mac: mac))
    }
}
