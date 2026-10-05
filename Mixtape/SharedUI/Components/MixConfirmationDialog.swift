// Confirmations that sit in the middle of the screen on iOS. There a confirmation
// dialog is a popover anchored to the view it's attached to, which for a page is its top.
// Alerts add no Cancel of their own, so every caller brings one.

import SwiftUI

extension View {

    func mixConfirmationDialog<A: View, M: View>(_ title: String,
                                                 isPresented: Binding<Bool>,
                                                 titleVisibility: Visibility = .automatic,
                                                 @ViewBuilder actions: () -> A,
                                                 @ViewBuilder message: () -> M) -> some View {
        #if os(iOS)
        alert(title, isPresented: isPresented, actions: actions, message: message)
        #else
        confirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
                           actions: actions, message: message)
        #endif
    }

    func mixConfirmationDialog<A: View>(_ title: String,
                                        isPresented: Binding<Bool>,
                                        titleVisibility: Visibility = .automatic,
                                        @ViewBuilder actions: () -> A) -> some View {
        mixConfirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
                              actions: actions) { EmptyView() }
    }

    func mixConfirmationDialog<T, A: View, M: View>(_ title: String,
                                                    isPresented: Binding<Bool>,
                                                    titleVisibility: Visibility = .automatic,
                                                    presenting data: T?,
                                                    @ViewBuilder actions: (T) -> A,
                                                    @ViewBuilder message: (T) -> M) -> some View {
        #if os(iOS)
        alert(title, isPresented: isPresented, presenting: data, actions: actions, message: message)
        #else
        confirmationDialog(title, isPresented: isPresented, titleVisibility: titleVisibility,
                           presenting: data, actions: actions, message: message)
        #endif
    }
}
