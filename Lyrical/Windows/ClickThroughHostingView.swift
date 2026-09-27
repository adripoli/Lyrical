//
//  ClickThroughHostingView.swift
//  Lyrical
//
//  Lets a click land on a transport button of a non-key, non-activating panel
//  without the user's focus ever leaving the app they were working in. Without
//  acceptsFirstMouse, the first click on the bar would only be spent bringing
//  the panel forward.
//

import SwiftUI

final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — Lyrical builds every view in code")
    }
}
