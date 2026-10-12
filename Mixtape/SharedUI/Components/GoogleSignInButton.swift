// Matches the web's Google button: pill, surface gradient, real four-colour G.

import SwiftUI

struct GoogleSignInButton: View {
    let action: () -> Void

    @State private var isHovering = false

    // The auth card's pills use these too so the two buttons line up.
    #if os(macOS)
    static let height: CGFloat = 42
    static var font: Font { .system(size: 14, weight: .semibold) }
    #else
    static let height: CGFloat = 50
    static var font: Font { .system(size: MixFontScale.size(16), weight: .semibold) }
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("GoogleLogo")
                    .resizable()
                    .frame(width: 18, height: 18)
                Text("Continue with Google")
                    .font(Self.font)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .foregroundStyle(Color.mixTextPrimary)
            .background(
                LinearGradient(colors: [Color.mixSurface, Color.mixSurface2], startPoint: .top, endPoint: .bottom),
                in: Capsule()
            )
            .brightness(isHovering ? 0.05 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .mixAnimation(.easeOut(duration: 0.15), value: isHovering)
    }
}
