//
//  GlassBackground.swift
//  Lyrical
//
//  The one place Liquid Glass is configured. Used unconditionally — Lyrical is
//  macOS 26+ only, so there is no availability branch anywhere in the project.
//

import SwiftUI

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}
