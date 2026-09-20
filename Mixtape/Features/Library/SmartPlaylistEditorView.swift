// SmartPlaylistEditorView.swift
// Mixtape — Features/Library
//
// Create a new smart playlist: pick a rule type + parameters, and name it.
//
// This was a `Form` of `Section`s inside a `NavigationStack`, with Cancel and
// Save up in a navigation bar — an iOS Settings screen wearing a Mac modal.
// The rule is the decision this sheet exists to make, so it's now five rows you
// can see and compare at once, with the chosen rule's parameters directly
// underneath, instead of a `Picker` that hides four of the five options.

import SwiftUI

public struct SmartPlaylistEditorView: View {

    @ObservedObject var service: SmartPlaylistService
    @Environment(\.dismiss) private var dismiss

    // MARK: - Editable state

    @State private var name: String = ""
    @State private var ruleKind: RuleKind = .recentlyAdded
    @State private var days: Int = 30
    @State private var limit: Int = 25
    @State private var field: SmartPlaylistRule.Field = .genre
    @State private var fieldValue: String = ""

    public init(service: SmartPlaylistService) {
        self.service = service
    }

    private enum RuleKind: String, CaseIterable, Identifiable {
        case recentlyAdded       = "Recently Added"
        case onRepeat            = "On Repeat"
        case mostPlayed          = "Most Played"
        case neverPlayed         = "Never Played"
        case forgottenFavourites = "Forgotten Favourites"
        case fieldFilter         = "Field Filter"
        var id: String { rawValue }

        /// Borrowed from the rule itself so the row, the sidebar and the saved
        /// playlist can't drift apart. The parameters don't affect the icon.
        var icon: String {
            switch self {
            case .recentlyAdded:       return SmartPlaylistRule.recentlyAdded(limit: 50).defaultIcon
            case .onRepeat:            return SmartPlaylistRule.onRepeat(limit: 30).defaultIcon
            case .mostPlayed:          return SmartPlaylistRule.mostPlayed(limit: 25).defaultIcon
            case .neverPlayed:         return SmartPlaylistRule.neverPlayed.defaultIcon
            case .forgottenFavourites: return SmartPlaylistRule.forgottenFavourites(days: 30).defaultIcon
            case .fieldFilter:         return SmartPlaylistRule.fieldContains(field: .genre, value: "").defaultIcon
            }
        }

        var blurb: String {
            switch self {
            case .recentlyAdded:       return "The newest songs in your library."
            case .onRepeat:            return "What you've been playing lately."
            case .mostPlayed:          return "Your top songs by play count."
            case .neverPlayed:         return "Songs sitting in your library unplayed."
            case .forgottenFavourites: return "Old favourites you haven't played in a while."
            case .fieldFilter:         return "Match on a tag — genre, album, year."
            }
        }
    }

    private var builtRule: SmartPlaylistRule {
        switch ruleKind {
        case .recentlyAdded:       return .recentlyAdded(limit: limit)
        case .onRepeat:            return .onRepeat(limit: limit)
        case .mostPlayed:          return .mostPlayed(limit: limit)
        case .neverPlayed:         return .neverPlayed
        case .forgottenFavourites: return .forgottenFavourites(days: days)
        case .fieldFilter:         return .fieldContains(field: field, value: fieldValue)
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if ruleKind == .fieldFilter {
            return !fieldValue.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    public var body: some View {
        MixSheet(title: "New Smart Playlist",
                 subtitle: "Set a rule and the playlist keeps itself up to date.",
                 size: .large,
                 primary: MixSheetAction("Create", isEnabled: canSave, action: save)) {
            VStack(alignment: .leading, spacing: 22) {
                nameField
                ruleChooser
                parameters
            }
        }
        .tint(Color.mixPrimary)
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("NAME")
            TextField("Smart Playlist Name", text: $name)
                .textFieldStyle(.plain)
                .mixSheetField()
        }
    }

    // MARK: - Rule

    private var ruleChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("RULE")
            VStack(spacing: 0) {
                ForEach(RuleKind.allCases) { kind in
                    ruleRow(kind)
                }
            }
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func ruleRow(_ kind: RuleKind) -> some View {
        let isSelected = kind == ruleKind
        return Button {
            Haptics.play(.selection)
            ruleKind = kind
        } label: {
            HStack(spacing: 12) {
                Image(systemName: kind.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.mixPrimary : Color.mixTextSecondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.mixTextPrimary)
                    Text(kind.blurb)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mixTextSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // The only mark of selection that survives at a glance — the
                // tint alone reads as decoration on a five-row stack.
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mixPrimary)
                    .opacity(isSelected ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.mixPrimary.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).mixHandCursor()
        .mixHoverCursor { _ in }
    }

    // MARK: - Parameters

    /// The chosen rule's knobs, directly under the rule that owns them.
    @ViewBuilder
    private var parameters: some View {
        switch ruleKind {
        case .forgottenFavourites:
            parameterCard {
                Stepper(value: $days, in: 1...365) {
                    parameterLabel("Not played for", value: "\(days) day\(days == 1 ? "" : "s")")
                }
            }
        case .recentlyAdded, .onRepeat, .mostPlayed:
            parameterCard {
                Stepper(value: $limit, in: 1...200) {
                    parameterLabel("Include",
                                   value: ruleKind == .recentlyAdded ? "\(limit) songs" : "Top \(limit)")
                }
            }
        case .neverPlayed:
            // Nothing to configure — say so rather than leaving a gap that
            // looks like something failed to load.
            Text("No settings for this one — it's every song you've never played.")
                .font(.system(size: 12))
                .foregroundStyle(Color.mixTextTertiary)
        case .fieldFilter:
            parameterCard {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Field", selection: $field) {
                        ForEach(SmartPlaylistRule.Field.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    TextField("Contains\u{2026}", text: $fieldValue)
                        .textFieldStyle(.plain)
                        .mixSheetField()
                }
            }
        }
    }

    private func parameterCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.mixSurface,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func parameterLabel(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Color.mixTextSecondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mixTextPrimary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.mixTextTertiary)
            .tracking(0.8)
    }

    // MARK: - Save

    private func save() {
        let rule = builtRule
        service.create(
            name: name.trimmingCharacters(in: .whitespaces),
            iconName: rule.defaultIcon,
            rule: rule
        )
        dismiss()
    }
}
