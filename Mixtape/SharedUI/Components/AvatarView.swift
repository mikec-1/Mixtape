// AvatarView.swift
// Mixtape — SharedUI/Components
//
// Circular profile avatar. Renders the remote image when available, otherwise
// falls back to the brand-gradient monogram (first letter of the username).
// Used in Settings, the Find People list, and other-user profiles.

import SwiftUI

public struct AvatarView: View {

    private let url: URL?
    private let fallbackText: String
    private let size: CGFloat

    public init(url: URL?, fallbackText: String, size: CGFloat = 64) {
        self.url = url
        self.fallbackText = fallbackText
        self.size = size
    }

    public var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ZStack {
                            monogram
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                    case .failure:
                        monogram
                    @unknown default:
                        monogram
                    }
                }
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.mixSeparator, lineWidth: 0.5))
        .shadow(color: Color.mixPrimary.opacity(0.25), radius: size * 0.15, y: size * 0.06)
    }

    private var monogram: some View {
        LinearGradient(
            colors: [Color.mixPrimary, Color.mixPrimaryDark],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            Text(initial)
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        )
    }

    private var initial: String {
        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 16) {
        AvatarView(url: nil, fallbackText: "Rico", size: 64)
        AvatarView(url: nil, fallbackText: "mareep", size: 44)
    }
    .padding()
    .background(Color.mixBackground)
}
#endif
