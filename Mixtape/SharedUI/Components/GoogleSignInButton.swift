// GoogleSignInButton.swift
// Mixtape — SharedUI/Components
//
// The web's `.btn.btn-ghost.auth-google`: a pill on the surface colour, a
// hairline border that brightens under the pointer, and Google's own
// four-colour G rather than an SF Symbol stand-in.

import SwiftUI

struct GoogleSignInButton: View {
    let action: () -> Void

    @State private var isHovering = false

    #if os(macOS)
    private let height: CGFloat = 42
    private let font = Font.system(size: 14, weight: .semibold)
    #else
    private let height: CGFloat = 50
    private let font = Font.system(size: 16, weight: .semibold)
    #endif

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image("GoogleLogo")
                    .resizable()
                    .frame(width: 18, height: 18)
                Text("Continue with Google")
                    .font(font)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .foregroundStyle(Color.mixTextPrimary)
            .background(Color.mixSurface, in: Capsule())
            .overlay(
                Capsule().strokeBorder(isHovering ? Color.mixTextTertiary : Color.mixSeparator, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).mixHandCursor()
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .mixAnimation(.easeOut(duration: 0.15), value: isHovering)
    }
}
