// The recap's drawn pieces: the cassette on the first slide and the 24-hour clock.

import SwiftUI

// MARK: - Cassette

/// A C90. The slide turns the reels, so pausing the story stops them.
struct RecapCassette: View {
    /// "September 2026".
    let month: String
    let name: String
    /// How far the reels have turned, in seconds of play.
    let reel: Double
    /// 0 with the tape on the left reel, 1 with it all on the right.
    let wound: Double

    private static let ink = Color(hex: "140B05")
    private static let mono = Font.system(size: 10, weight: .medium, design: .monospaced)

    /// Drawn in layers so a frame redraws nothing: the hubs spin as whole layers, and the packs only
    /// redraw while the tape winds. One canvas used to redraw the label text every frame.
    var body: some View {
        ZStack {
            Back(wound: wound)
                .shadow(color: .black.opacity(0.55), radius: 10, y: 8)
            Hub(x: 148).rotationEffect(.degrees(reel / 2.6 * 360), anchor: UnitPoint(x: 148.0 / 400, y: 122.0 / 256))
            Hub(x: 252).rotationEffect(.degrees(reel / 1.6 * 360), anchor: UnitPoint(x: 252.0 / 400, y: 122.0 / 256))
            Face(month: month, name: name).equatable()
        }
        .aspectRatio(400 / 256, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// A canvas in the cassette's own 400 x 256 space.
    private static func layer(_ draw: @escaping (inout GraphicsContext) -> Void) -> some View {
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 400, y: size.height / 256)
            draw(&ctx)
        }
    }

    private struct Back: View {
        let wound: Double
        var body: some View { RecapCassette.layer { RecapCassette.drawBack(&$0, wound: wound) } }
    }

    private struct Hub: View {
        let x: CGFloat
        var body: some View { RecapCassette.layer { RecapCassette.drawHub(&$0, x: x) } }
    }

    private struct Face: View, Equatable {
        let month: String
        let name: String
        var body: some View { RecapCassette.layer { RecapCassette.drawFace(&$0, month: month, name: name) } }
    }

    private static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: r)
    }

    private static func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    /// Shell, window and tape packs.
    private static func drawBack(_ ctx: inout GraphicsContext, wound: Double) {
        ctx.fill(rr(1, 1, 398, 254, 16), with: .linearGradient(
            Gradient(colors: [Color(hex: "3C3C42"), Color(hex: "1B1B1F")]),
            startPoint: CGPoint(x: 0, y: 1), endPoint: CGPoint(x: 0, y: 255)))
        ctx.stroke(rr(1.5, 1.5, 397, 253, 15.5), with: .color(.white.opacity(0.14)), lineWidth: 1)

        // Window, packs and hubs.
        let window = rr(92, 88, 216, 68, 34)
        ctx.fill(window, with: .color(Color(hex: "0D0D0F")))
        var packs = ctx
        packs.clip(to: window)
        let pack = Gradient(stops: [.init(color: Color(hex: "704328"), location: 0.3),
                                    .init(color: Color(hex: "43271A"), location: 0.9),
                                    .init(color: Color(hex: "2A170E"), location: 1)])
        for (x, r) in [(148.0, 46 * (1 - 0.26 * wound)), (252.0, 29 * (1 + 0.3 * wound))] {
            let c = CGPoint(x: x, y: 122)
            packs.fill(circle(x, 122, r), with: .radialGradient(pack, center: c, startRadius: 0, endRadius: r))
        }
    }

    /// One hub, unturned; its layer does the turning.
    private static func drawHub(_ ctx: inout GraphicsContext, x: CGFloat) {
        var hub = ctx
        hub.translateBy(x: x, y: 122)
        let cream = Color(hex: "EEE7DB")
        hub.fill(circle(0, 0, 17), with: .color(cream))
        hub.fill(circle(0, 0, 10.5), with: .color(Color(hex: "101012")))
        for k in 0..<6 {
            var tooth = hub
            tooth.rotate(by: .degrees(Double(k) * 60))
            tooth.fill(rr(-2, -11, 4, 5, 1), with: .color(cream))
        }
    }

    /// Window glass, label, text and the bottom of the shell.
    private static func drawFace(_ ctx: inout GraphicsContext, month: String, name: String) {
        let window = rr(92, 88, 216, 68, 34)
        ctx.fill(window, with: .linearGradient(
            Gradient(stops: [.init(color: .white.opacity(0.2), location: 0),
                             .init(color: .white.opacity(0.02), location: 0.5),
                             .init(color: .white.opacity(0.1), location: 1)]),
            startPoint: CGPoint(x: 92, y: 88), endPoint: CGPoint(x: 308, y: 156)))
        ctx.stroke(window, with: .color(.black.opacity(0.6)), lineWidth: 1.5)

        // Label, with the window cut out.
        var label = rr(22, 16, 356, 162, 8)
        label.addPath(rr(88, 84, 224, 76, 38))
        ctx.fill(label, with: .color(Color(hex: "F2EADC")), style: FillStyle(eoFill: true))
        let strip = UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
            .path(in: CGRect(x: 22, y: 16, width: 356, height: 28))
        ctx.fill(strip, with: .color(Color(hex: "FF6B00")))
        ctx.fill(circle(40, 30, 9), with: .color(Self.ink))
        ctx.draw(Text("A").font(.system(size: 12, weight: .heavy)).foregroundStyle(.white),
                 at: CGPoint(x: 40, y: 30))
        ctx.draw(Text("MIXTAPE").font(Self.mono).tracking(1.4).foregroundStyle(Self.ink),
                 at: CGPoint(x: 58, y: 30.5), anchor: .leading)
        ctx.draw(Text("C90 · TYPE I").font(Self.mono).tracking(1.4).foregroundStyle(Self.ink),
                 at: CGPoint(x: 366, y: 30.5), anchor: .trailing)
        var rule = Path()
        rule.move(to: CGPoint(x: 36, y: 76))
        rule.addLine(to: CGPoint(x: 364, y: 76))
        ctx.stroke(rule, with: .color(.black.opacity(0.14)), lineWidth: 1)

        let pen = Color(hex: "26399A")
        let monthText = ctx.resolve(Text(month).font(.custom("Noteworthy-Bold", size: 30)).foregroundStyle(pen))
        ctx.draw(monthText, at: CGPoint(x: 40, y: 73), anchor: .bottomLeading)
        // Shrinks a long name rather than writing over the month.
        let room = 362 - 40 - monthText.measure(in: CGSize(width: 400, height: 60)).width - 16
        var nameSize: CGFloat = 21
        var nameText = ctx.resolve(Text("for \(name)").font(.custom("Noteworthy-Bold", size: nameSize)).foregroundStyle(pen))
        while nameSize > 11, nameText.measure(in: CGSize(width: 400, height: 60)).width > room {
            nameSize -= 1
            nameText = ctx.resolve(Text("for \(name)").font(.custom("Noteworthy-Bold", size: nameSize)).foregroundStyle(pen))
        }
        ctx.draw(nameText, at: CGPoint(x: 362, y: 73), anchor: .bottomTrailing)
        ctx.draw(Text("SIDE A · 45 MIN").font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(1.8).foregroundStyle(Color(hex: "8A8074")),
                 at: CGPoint(x: 200, y: 169))

        // Bottom ramp, holes, tape and screws.
        var ramp = Path()
        ramp.move(to: CGPoint(x: 80, y: 255))
        ramp.addLine(to: CGPoint(x: 97, y: 192))
        ramp.addQuadCurve(to: CGPoint(x: 105, y: 186), control: CGPoint(x: 99, y: 186))
        ramp.addLine(to: CGPoint(x: 295, y: 186))
        ramp.addQuadCurve(to: CGPoint(x: 303, y: 192), control: CGPoint(x: 301, y: 186))
        ramp.addLine(to: CGPoint(x: 320, y: 255))
        ramp.closeSubpath()
        ctx.fill(ramp, with: .color(Color(hex: "27272C")))
        ctx.stroke(ramp, with: .color(.white.opacity(0.08)), lineWidth: 1)

        let hole = Color(hex: "0B0B0D")
        for x in [116.0, 284] { ctx.fill(circle(x, 236, 7), with: .color(hole)) }
        for (x, y, w, h) in [(146.0, 226.0, 22.0, 22.0), (186, 222, 28, 26), (232, 226, 22, 22)] {
            ctx.fill(rr(x, y, w, h, 3), with: .color(hole))
            ctx.fill(Path(CGRect(x: x, y: 243, width: w, height: 3)), with: .color(Color(hex: "5A3320")))
        }
        let screwEdge = Color(hex: "5E5E66")
        for (x, y) in [(13.0, 13.0), (387, 13), (13, 243), (387, 243), (200, 204)] {
            let screw = circle(x, y, 5)
            ctx.fill(screw, with: .color(Color(hex: "111114")))
            ctx.stroke(screw, with: .color(screwEdge), lineWidth: 1.2)
            var slot = Path()
            slot.move(to: CGPoint(x: x - 3, y: y))
            slot.addLine(to: CGPoint(x: x + 3, y: y))
            ctx.stroke(slot, with: .color(screwEdge), lineWidth: 1.2)
        }
    }
}

// MARK: - Clock

/// Plays per hour as 24 spokes on a disc, drawn in one after another, with a dot
/// running round to the busiest hour.
struct RecapClock: View {
    let playsByHour: [Int]
    let hot: Set<Int>
    let size: CGFloat
    let theme: RecapTheme
    let b: RecapBeat

    private let centre = CGPoint(x: 190, y: 190)

    var body: some View {
        let peak = max(playsByHour.max() ?? 1, 1)
        let busiest = playsByHour.indices.max { playsByHour[$0] < playsByHour[$1] } ?? 0
        let lap = (1 + Double(busiest) / 24) * b.glide(0.5, 1.8)
        ZStack {
            Circle().fill(theme.shape)
                .frame(width: 300, height: 300)
                .popIn(b, 0.1, 0.8)
            ForEach(0..<24, id: \.self) { h in
                spoke(h, length: 10 + Double(playsByHour[h]) / Double(peak) * 76)
                    .trim(from: 0, to: b.ease(0.5 + Double(h) * 0.035, 0.7))
                    .stroke(hot.contains(h) ? theme.acc : theme.soft,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
            }
            ForEach([0, 6, 12, 18], id: \.self) { h in
                Text(Self.hourName(h))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.soft)
                    .position(point(Double(h), radius: 176))
            }
            Circle().fill(theme.acc)
                .frame(width: 12, height: 12)
                .position(point(lap * 24, radius: 158))
                .opacity(b.ease(0.5, 0.2))
            ForEach(0..<3, id: \.self) { i in
                RecapSparkle().fill(theme.alt)
                    .frame(width: 22, height: 22)
                    .scaleEffect(0.6 + 0.4 * abs(sin(b.drift * 2 + Double(i))))
                    .popIn(b, 1.2 + Double(i) * 0.2, 0.5)
                    .position([CGPoint(x: 42, y: 60), CGPoint(x: 340, y: 96), CGPoint(x: 318, y: 336)][i])
            }
            VStack(spacing: 2) {
                Text(Self.hourName(busiest))
                    .font(.system(size: 44, weight: .heavy).width(.condensed))
                    .foregroundStyle(theme.acc)
                Text("busiest")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.soft)
            }
            .popIn(b, 1.4, 0.6)
            .position(x: centre.x, y: centre.y + 6)
        }
        .frame(width: 380, height: 380)
        .scaleEffect(size / 380)
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Busiest hour \(Self.hourName(busiest))")
    }

    /// `hour` can be fractional, for the dot on its way round.
    private func point(_ hour: Double, radius: Double) -> CGPoint {
        let a = hour / 24 * 2 * .pi - .pi / 2
        return CGPoint(x: centre.x + cos(a) * radius, y: centre.y + sin(a) * radius)
    }

    private func spoke(_ hour: Int, length: Double) -> Path {
        var p = Path()
        p.move(to: point(Double(hour), radius: 62))
        p.addLine(to: point(Double(hour), radius: 62 + length))
        return p
    }

    /// "11pm", "12am".
    static func hourName(_ h: Int) -> String {
        "\(h % 12 == 0 ? 12 : h % 12)\(h < 12 ? "am" : "pm")"
    }
}
