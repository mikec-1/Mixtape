// ForgotPasswordSheet.swift
// Mixtape — Features/Auth
//
// One password-reset dialog for both platforms.
//
// There used to be two. The phone version was a 72pt glyph floating between a
// pair of Spacers, under an empty navigation title, with "Cancel" filed under
// `.confirmationAction`. The Mac version hand-built a 340pt panel with its own
// "Close" text button in the top-right corner — the one place the guidelines
// say a dismissing button never goes. Same field, same two states, two sets of
// spacing and two chances to drift.

import SwiftUI

struct ForgotPasswordSheet: View {

    @ObservedObject var vm: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MixSheet(title: vm.resetEmailSent ? "Check Your Inbox" : "Reset Password",
                 subtitle: vm.resetEmailSent
                     ? "We sent a link to \(vm.resetEmail). Open it to choose a new password."
                     : "Enter the email you signed up with and we'll send you a link.",
                 size: .compact,
                 primary: primaryAction,
                 // Nothing is left to cancel once the mail is gone.
                 showsCancel: !vm.resetEmailSent) {
            content
        }
        .tint(Color.mixPrimary)
    }

    @ViewBuilder
    private var content: some View {
        if vm.resetEmailSent {
            MixSheetStatus(kind: .success,
                           title: "Reset link sent",
                           detail: "It can take a minute to arrive. Check spam if it doesn't.")
        } else {
            TextField("you@example.com", text: $vm.resetEmail)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                #endif
                .autocorrectionDisabled()
                .onSubmit { if isValidEmail { Task { await vm.sendPasswordReset() } } }
                .mixSheetField()
        }
    }

    private var primaryAction: MixSheetAction {
        if vm.resetEmailSent {
            return MixSheetAction("Done") {
                vm.resetEmailSent = false
                dismiss()
            }
        }
        return MixSheetAction("Send Reset Link",
                              isEnabled: isValidEmail,
                              isBusy: vm.isResettingPassword) {
            Task { await vm.sendPasswordReset() }
        }
    }

    private var isValidEmail: Bool {
        vm.resetEmail.contains("@")
    }
}
