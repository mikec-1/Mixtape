// Profile avatar: remote image, else a blob character picked from the username.

import SwiftUI

public struct AvatarView: View {

    private let url: URL?
    private let seed: String
    private let size: CGFloat

    /// `seed` is the username where there is one, so a person gets the same blob everywhere.
    public init(url: URL?, seed: String, size: CGFloat = 64) {
        self.url = url
        self.seed = seed
        self.size = size
    }

    public var body: some View {
        Group {
            if let url {
                // Cached and shared: AsyncImage gave up for good when a lazy row cancelled its load.
                CachedRemoteImage(url: url, points: size) { $0.resizable().scaledToFill() } placeholder: { BlobAvatar(seed: seed) }
            } else {
                BlobAvatar(seed: seed)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.mixSeparator, lineWidth: 0.5))
        .mixShadow(color: Color.mixPrimary.opacity(0.25), radius: size * 0.15, y: size * 0.06)
    }
}

/// The default avatar: a little character on a 100pt grid. Same hash, tables and
/// geometry as mixtape-web's lib/avatar.ts so web and app agree; change both together.
struct BlobAvatar: View {

    let seed: String

    var body: some View {
        Canvas { ctx, size in
            var n = Self.hash(seed)
            func pick(_ k: UInt32) -> Int { defer { n /= k }; return Int(n % k) }
            let colors = Self.palettes[pick(10)]
            let shape = Self.shapes[pick(9)]
            let eyes = pick(4)
            let ex = shape.face.x + CGFloat(pick(5) - 2) * 3
            let ey = shape.face.y + (pick(2) == 0 ? -3 : 0)
            let smile = pick(4) == 0
            let blush = pick(3) == 0
            let tilt = Double(pick(5) - 2) * 6
            let body = GraphicsContext.Shading.color(Color(hex: colors.body))
            let ink = GraphicsContext.Shading.color(Color(hex: colors.ink))

            ctx.scaleBy(x: size.width / 100, y: size.height / 100)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 100, height: 100)), with: .color(Color(hex: colors.bg)))
            ctx.translateBy(x: 50, y: 54)
            ctx.rotate(by: .degrees(tilt))
            ctx.translateBy(x: -50, y: -54)

            ctx.fill(shape.path, with: body)
            if shape.rays {
                for i in 0..<8 {
                    let a = Double(i) * .pi / 4
                    ctx.fill(Path(ellipseIn: CGRect(x: 50 + 32 * cos(a) - 5.5, y: 54 + 32 * sin(a) - 5.5, width: 11, height: 11)),
                             with: body)
                }
            }
            for side: CGFloat in [-1, 1] {
                if blush {
                    ctx.fill(Path(ellipseIn: CGRect(x: ex + side * 10 - 3.5, y: ey + 3.5, width: 7, height: 7)),
                             with: .color(Color(hex: "FF7A9A").opacity(0.45)))
                }
                let x = ex + side * 5.5
                let eye = switch eyes {
                case 2: Path(ellipseIn: CGRect(x: x - 3.2, y: ey - 3.2, width: 6.4, height: 6.4))
                case 3: Path(roundedRect: CGRect(x: x - 3.5, y: ey - 1.3, width: 7, height: 2.6), cornerRadius: 1.3)
                default: Path(roundedRect: CGRect(x: x - 2.5, y: ey - 4.75, width: 5, height: 9.5), cornerRadius: 2.5)
                }
                ctx.fill(eye, with: ink)
            }
            if smile {
                var mouth = Path()
                mouth.move(to: CGPoint(x: ex - 3.5, y: ey + 9))
                mouth.addQuadCurve(to: CGPoint(x: ex + 3.5, y: ey + 9), control: CGPoint(x: ex, y: ey + 12.5))
                ctx.stroke(mouth, with: ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }

    /// FNV-1a over the trimmed, lower-cased name, then murmur's finaliser to spread the bits.
    nonisolated static func hash(_ seed: String) -> UInt32 {
        var key = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.hasPrefix("@") { key.removeFirst() }
        var h: UInt32 = 0x811c_9dc5
        for byte in (key.isEmpty ? "?" : key).utf8 { h = (h ^ UInt32(byte)) &* 0x0100_0193 }
        h ^= h >> 16; h = h &* 0x85eb_ca6b
        h ^= h >> 13; h = h &* 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    /// Background, body, eyes.
    nonisolated static let palettes: [(bg: String, body: String, ink: String)] = [
        ("E3E7FF", "5B6CF0", "1F1F24"), // indigo
        ("FFE6D9", "F2804B", "1F1F24"), // orange
        ("FFF4CF", "F7C948", "1F1F24"), // yellow
        ("D7F2EF", "3FB1A8", "1F1F24"), // teal
        ("FDE4F1", "F59AC7", "1F1F24"), // pink
        ("FDE0DF", "E35D5B", "1F1F24"), // red
        ("E1F4DF", "67C26B", "1F1F24"), // green
        ("ECE5FF", "9B7BEA", "1F1F24"), // purple
        ("ECEDF0", "A9ADB6", "1F1F24"), // grey
        ("E4E4E8", "222226", "FFFFFF"), // ink
    ]

    /// Body outline (SVG path syntax, the same strings as the web), where the eyes sit, and the sun's dots.
    nonisolated static let shapes: [(path: Path, face: CGPoint, rays: Bool)] = [
        (path(from: "M 50 24 C 66.57 24 80 37.43 80 54 C 80 70.57 66.57 84 50 84 C 33.43 84 20 70.57 20 54 C 20 37.43 33.43 24 50 24 Z"), CGPoint(x: 50, y: 48), false), // ball
        (path(from: "M 50 22 C 63.81 22 75 36.33 75 54 C 75 71.67 63.81 86 50 86 C 36.19 86 25 71.67 25 54 C 25 36.33 36.19 22 50 22 Z"), CGPoint(x: 50, y: 44), false), // egg
        (path(from: "M 50 18 C 58 26 76 38 76 60 C 76 74.36 64.36 86 50 86 C 35.64 86 24 74.36 24 60 C 24 38 42 26 50 18 Z"), CGPoint(x: 50, y: 54), false), // lemon
        (path(from: "M 27 50 C 15 45 18 25 36 27 C 42 20 58 20 64 27 C 82 25 85 45 73 50 L 73 80 Q 73 85 68 85 L 32 85 Q 27 85 27 80 Z"), CGPoint(x: 50, y: 56), false), // bread
        (path(from: "M 28 78 C 17 78 13 66 21 60 C 18 49 29 41 38 46 C 41 34 60 32 64 45 C 74 41 85 50 80 60 C 88 65 84 78 73 78 Z"), CGPoint(x: 52, y: 62), false), // cloud
        (path(from: "M 36 26 L 64 26 C 71.73 26 78 32.27 78 40 L 78 68 C 78 75.73 71.73 82 64 82 L 36 82 C 28.27 82 22 75.73 22 68 L 22 40 C 22 32.27 28.27 26 36 26 Z"), CGPoint(x: 50, y: 50), false), // cube
        (path(from: "M 50 31 C 62.7 31 73 41.3 73 54 C 73 66.7 62.7 77 50 77 C 37.3 77 27 66.7 27 54 C 27 41.3 37.3 31 50 31 Z"), CGPoint(x: 50, y: 51), true), // sun
        (path(from: "M 22 74 C 18 52 32 30 52 30 C 72 30 84 50 80 72 C 79 80 72 82 50 82 C 30 82 23 80 22 74 Z"), CGPoint(x: 54, y: 54), false), // mochi
        (path(from: "M 24 52 C 24 37.64 35.64 26 50 26 C 64.36 26 76 37.64 76 52 L 76 80 Q 67.33 89 58.67 80 Q 50 89 41.33 80 Q 32.67 89 24 80 Z"), CGPoint(x: 50, y: 50), false), // ghost
    ]

    /// Reads the M/L/Q/C/Z subset the shapes above use, space separated.
    nonisolated private static func path(from d: String) -> Path {
        let tokens = d.split(separator: " ")
        var i = 0
        func point() -> CGPoint {
            defer { i += 2 }
            return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
        }
        var path = Path()
        while i < tokens.count {
            let command = tokens[i]
            i += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "Q": let c = point(); path.addQuadCurve(to: point(), control: c)
            case "C": let c1 = point(), c2 = point(); path.addCurve(to: point(), control1: c1, control2: c2)
            default: path.closeSubpath()
            }
        }
        return path
    }
}

#if DEBUG
#Preview {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 6), spacing: 12) {
        ForEach(["rico", "mareep", "mike", "hannah", "franzi", "sam", "alex", "jo", "kai", "lu", "noor", "zed"], id: \.self) {
            AvatarView(url: nil, seed: $0, size: 56)
        }
    }
    .padding()
    .background(Color.mixBackground)
}
#endif
