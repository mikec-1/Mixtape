// MergeDuplicatesSheet.swift
// Mixtape — SharedUI/Components
//
// The preview half of `DuplicateMerger`: what the cleanup would do, before it
// does it.
//
// Merging is a delete under a friendlier name, so nothing here happens on the
// way in. The sheet opens, scans, and shows the list — every doubled song, the
// copy that survives, and the playlists that get repointed — and the button
// stays the only thing that acts.

import SwiftUI

extension Notification.Name {
    /// Posted by the macOS Library menu. `MacRootView` listens and presents the
    /// sheet — the menu bar lives outside every view that could show it itself.
    static let mixMergeDuplicates = Notification.Name("mix.mergeDuplicates")
}

struct MergeDuplicatesSheet: View {

    @EnvironmentObject private var deps: AppDependencies

    @State private var plan: DuplicateMergePlan?
    @State private var mergedCount: Int?

    var body: some View {
        MixSheet(title: "Merge Duplicate Songs",
                 subtitle: subtitle,
                 size: size,
                 primary: primaryAction,
                 cancelTitle: primaryAction == nil ? "Done" : "Cancel") {
            content
        }
        .task { if plan == nil { plan = DuplicateMerger.plan(library: deps.libraryService) } }
    }

    /// Only the list of duplicates needs a window you can scroll. Every other
    /// state of this sheet is one sentence, and asking for `.large` there is
    /// what left an eighth of the screen empty under a single line of text.
    private var size: MixSheetSize {
        guard mergedCount == nil, let plan, !plan.isEmpty else { return .compact }
        return .large
    }

    // MARK: Header text

    /// Nil in every state whose message is a status row below — the sentence
    /// belongs in one place, and up here it would be printed twice.
    private var subtitle: String? {
        guard mergedCount == nil, let plan, !plan.isEmpty else { return nil }
        return "\(plan.groups.count) song\(plan.groups.count == 1 ? "" : "s") are in your library more than once. One copy of each is kept — the rest are removed, and every playlist and like is moved onto the copy that stays."
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let mergedCount {
            MixSheetStatus(
                kind: mergedCount == 0 ? .noop : .success,
                title: mergedCount == 0
                    ? "Nothing was changed"
                    : "\(mergedCount) duplicate\(mergedCount == 1 ? "" : "s") removed",
                detail: mergedCount == 0
                    ? nil
                    : "Your playlists and liked songs now point at the copy that was kept."
            )
        } else if let plan {
            if plan.isEmpty {
                MixSheetStatus(kind: .noop,
                               title: "No duplicates found",
                               detail: "Every song in your library is in there once.")
            } else {
                VStack(spacing: 8) {
                    ForEach(plan.groups) { group in
                        row(group)
                    }
                }
            }
        } else {
            MixSheetStatus(kind: .busy, title: "Scanning your library…")
        }
    }

    private func row(_ group: DuplicateMergePlan.Group) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(group.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.mixTextPrimary)
                .lineLimit(1)

            Text(group.artistName)
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextSecondary)
                .lineLimit(1)

            Text(detail(for: group))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.mixTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mixSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// "2 copies removed · Keeping the downloaded copy · In Road Trip, Liked Songs"
    private func detail(for group: DuplicateMergePlan.Group) -> String {
        var parts = ["\(group.loserIDs.count) cop\(group.loserIDs.count == 1 ? "y" : "ies") removed",
                     group.keeperReason]
        if !group.playlistNames.isEmpty {
            parts.append("In \(group.playlistNames.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Action

    private var primaryAction: MixSheetAction? {
        guard mergedCount == nil, let plan, !plan.isEmpty else { return nil }
        let count = plan.duplicateCount
        return MixSheetAction("Merge \(count) Duplicate\(count == 1 ? "" : "s")",
                              isDestructive: true) {
            mergedCount = DuplicateMerger.apply(plan, library: deps.libraryService)
        }
    }
}
