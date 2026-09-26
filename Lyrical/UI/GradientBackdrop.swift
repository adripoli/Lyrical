//
//  GradientBackdrop.swift
//  Lyrical
//
//  A static 3×3 mesh gradient from the album palette. The centre point, which
//  sits behind the lyrics column, is the darkest colour dimmed further. It
//  never animates on its own; the wallpaper view crossfades it between tracks.
//

import SwiftUI

struct GradientBackdrop: View {
    let palette: Palette?

    var body: some View {
        if let palette, palette.colors.count >= 4,
           let darkest = palette.colors.min(by: { $0.brightness < $1.brightness }) {
            let c = palette.colors.map(\.color)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    c[0], c[1], c[0],
                    c[2], darkest.dimmed(0.6).color, c[3],
                    c[3], c[2], c[1],
                ]
            )
        } else {
            Color(white: 0.07)
        }
    }
}
