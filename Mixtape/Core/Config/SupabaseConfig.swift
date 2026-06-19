// SupabaseConfig.swift
// Mixtape — Core/Config
//
// The SupabaseClient is created once here and shared across all
// Supabase-backed services (auth, metadata sync, file storage).

import Foundation
import Supabase

public enum SupabaseConfig {

    // MARK: - Credentials

    static let projectURL = URL(string: "https://ldayhsncewjbstsmtzad.supabase.co")!

    /// Publishable anon key — safe to ship in the client; access is gated by RLS.
    static let anonKey = "sb_publishable_-ZKFsCnU1HKSxCBRt6hLOA_eWgjR6U6"

    // MARK: - Shared Client

    /// Single SupabaseClient shared by all services.
    /// Owns its own URLSession; do not create additional instances.
    public static let client = SupabaseClient(
        supabaseURL: projectURL,
        supabaseKey: anonKey,
        options: .init(
            auth: .init(
                // File-backed session storage instead of the Keychain — avoids
                // the recurring keychain-password prompt caused by ad-hoc
                // signing. See FileAuthLocalStorage for the full rationale.
                storage: FileAuthLocalStorage(),
                emitLocalSessionAsInitialSession: true
            )
        )
    )
}
