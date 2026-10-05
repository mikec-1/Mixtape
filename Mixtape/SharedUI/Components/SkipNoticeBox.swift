// Strip over the bottom of a queue list naming songs the queue skipped.

import SwiftUI

struct SkipNoticeBox: View {

    @ObservedObject private var unavailable = UnavailableTracks.shared

    var body: some View {
        if !unavailable.recentSkips.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(unavailable.recentSkips) { skip in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                        Text("\(skip.title) couldn't be found — skipped")
                            .font(.mixCaption)
                            .foregroundStyle(Color.mixTextPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { unavailable.dismiss(skip) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.mixSurface2)
            .overlay(alignment: .top) { Divider().opacity(0.4) }
            .help("Tap a line to dismiss it")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
