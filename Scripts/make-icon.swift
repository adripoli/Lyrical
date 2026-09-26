#!/usr/bin/env swift

//
//  make-icon.swift
//  Lyrical
//
//  Draws the app icon and compiles it to Lyrical/Resources/Lyrical.icns.
//
//  The .icns is committed, so this only needs re-running when the artwork
//  changes:  ./Scripts/make-icon.swift
//
//  Everything is drawn with CoreGraphics into an offscreen bitmap — no Xcode
//  asset catalog, no design tool, and no window server, so it also runs fine
//  over SSH or in CI.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry helpers

/// Rounded rect as a path. macOS icons use Apple's continuous ("squircle")
/// corners; a circular corner at the same radius is within a pixel or two at
/// every size we emit and needs no private API.
func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - The icon

/// Draws the icon at `size` points into an ARGB bitmap.
///
/// Concept: a slab of blurred album colour (the wallpaper Lyrical paints),
/// with a sleeve punched out of it so the wall shows through the record hole,
/// and the scrubber that floats over the desktop underneath.
func drawIcon(size: CGFloat) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)

    // Apple's icon grid leaves the art at ~80% of the canvas so neighbouring
    // icons in the Dock and Finder line up optically.
    let inset = size * 0.098
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateRadius = plate.width * 0.2237
    let platePath = roundedRect(plate, radius: plateRadius)

    // Contact shadow. Skipped below 64pt, where it turns into mud.
    if size >= 64 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.012),
            blur: size * 0.03,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        )
        ctx.addPath(platePath)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Album-blur gradient: violet at the top falling through magenta into a
    // warm ember, i.e. what a cover looks like once it's been blown up to
    // wallpaper size.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    let stops: [CGFloat] = [0.0, 0.45, 1.0]
    let colors = [
        CGColor(red: 0.35, green: 0.20, blue: 0.75, alpha: 1.0),
        CGColor(red: 0.72, green: 0.21, blue: 0.62, alpha: 1.0),
        CGColor(red: 0.98, green: 0.45, blue: 0.28, alpha: 1.0),
    ] as CFArray

    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: stops) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.minX, y: plate.maxY),
            end: CGPoint(x: plate.maxX, y: plate.minY),
            options: []
        )
    }

    // Soft top-left sheen so the plate reads as glass rather than flat paint.
    if let sheen = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.28),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            sheen,
            startCenter: CGPoint(x: plate.minX + plate.width * 0.24, y: plate.maxY - plate.height * 0.16),
            startRadius: 0,
            endCenter: CGPoint(x: plate.minX + plate.width * 0.24, y: plate.maxY - plate.height * 0.16),
            endRadius: plate.width * 0.72,
            options: []
        )
    }
    ctx.restoreGState()

    // MARK: Sleeve

    let coverSide = plate.width * 0.46
    let coverRect = CGRect(
        x: plate.midX - coverSide / 2,
        y: plate.midY - coverSide / 2 + plate.height * 0.06,
        width: coverSide,
        height: coverSide
    )
    let coverPath = CGMutablePath()
    coverPath.addPath(roundedRect(coverRect, radius: coverSide * 0.12))
    // Spindle hole, punched even-odd so the wall shows through it.
    coverPath.addEllipse(in: CGRect(
        x: coverRect.midX - coverSide * 0.115,
        y: coverRect.midY - coverSide * 0.115,
        width: coverSide * 0.23,
        height: coverSide * 0.23
    ))

    ctx.saveGState()
    if size >= 64 {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -size * 0.006),
            blur: size * 0.022,
            color: CGColor(red: 0.10, green: 0.02, blue: 0.16, alpha: 0.45)
        )
    }
    ctx.addPath(coverPath)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // MARK: Scrubber
    //
    // The floating control bar, in miniature. Below 32pt it collapses into a
    // grey smear, so it only gets drawn where it can actually be seen.

    guard size >= 32 else { return ctx.makeImage() }

    let barWidth = plate.width * 0.54
    let barHeight = max(1, plate.height * 0.045)
    let barRect = CGRect(
        x: plate.midX - barWidth / 2,
        y: coverRect.minY - plate.height * 0.13,
        width: barWidth,
        height: barHeight
    )

    ctx.addPath(roundedRect(barRect, radius: barHeight / 2))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
    ctx.fillPath()

    var playedRect = barRect
    playedRect.size.width = barWidth * 0.62
    ctx.addPath(roundedRect(playedRect, radius: barHeight / 2))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillPath()

    return ctx.makeImage()
}

// MARK: - Emit the iconset

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not create \(url.lastPathComponent)"])
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "could not write \(url.lastPathComponent)"])
    }
}

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Scripts/
    .deletingLastPathComponent()   // repo root
let iconset = repoRoot.appendingPathComponent("build/Lyrical.iconset")
let output = repoRoot.appendingPathComponent("Lyrical/Resources/Lyrical.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (base point size, scale) — iconutil wants every slot filled, and each one is
// rendered natively rather than downsampled so the small sizes stay sharp.
let slots: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (points, scale) in slots {
    let pixels = points * scale
    guard let image = drawIcon(size: CGFloat(pixels)) else {
        FileHandle.standardError.write("failed to render \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try writePNG(image, to: iconset.appendingPathComponent(name))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", iconset.path, "--output", output.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(iconutil.terminationStatus)
}

try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
