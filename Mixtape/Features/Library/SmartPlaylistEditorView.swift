// SmartPlaylistEditorView.swift
// Mixtape — Features/Library
//
// Create a new smart playlist: pick a rule type + parameters, name and icon.

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
        case mostPlayed          = "Most Played"
        case neverPlayed         = "Never Played"
        case forgottenFavourites = "Forgotten Favourites"
        case fieldFilter         = "Field Filter"
        var id: String { rawValue }
    }

    private var builtRule: SmartPlaylistRule {
        switch ruleKind {
        case .recentlyAdded:       return .recentlyAdded(days: days)
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
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Smart Playlist Name", text: $name)
                }

                Section("Rule") {
                    Picker("Type", selection: $ruleKind) {
                        ForEach(RuleKind.allCases) { Text($0.rawValue).tag($0) }
                    }

                    switch ruleKind {
                    case .recentlyAdded, .forgottenFavourites:
                        Stepper("Within \(days) day\(days == 1 ? "" : "s")", value: $days, in: 1...365)
                    case .mostPlayed:
                        Stepper("Top \(limit) tracks", value: $limit, in: 1...200)
                    case .neverPlayed:
                        Text("Tracks you've never played.")
                            .font(.mixLabel)
                            .foregroundStyle(Color.mixTextSecondary)
                    case .fieldFilter:
                        Picker("Field", selection: $field) {
                            ForEach(SmartPlaylistRule.Field.allCases, id: \.self) {
                                Text($0.displayName).tag($0)
                            }
                        }
                        TextField("Contains…", text: $fieldValue)
                    }
                }
                .listRowBackground(Color.mixSurface)
            }
            .scrollContentBackground(.hidden)
            .background(Color.mixBackground.ignoresSafeArea())
            .navigationTitle("New Smart Playlist")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let rule = builtRule
                        service.create(
                            name: name.trimmingCharacters(in: .whitespaces),
                            iconName: rule.defaultIcon,
                            rule: rule
                        )
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}
