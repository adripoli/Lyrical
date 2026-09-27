//
//  ArtworkRenderer.swift
//  Lyrical
//
//  Pixel work for the wallpaper: the blurred/dimmed full-screen backdrop and the
//  deterministic gradient used when a track has no artwork (local files, some
//  podcasts, ads). Ported from CoverWall so the desktop and the lock screen
//  share its backdrop. "Deterministic" is the whole point of the gradient — the
//  same album must look the same on every launch, hence StableHash.
//

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum ArtworkRenderer {

    /// Two hues derived from `seed`, tuned dark enough to sit behind desktop icons.
    static func fallbackColors(seed: String) -> (NSColor, NSColor) {
        let hash = StableHash.fnv1a(seed)

        let hue = CGFloat(hash % 360) / 360
        // Offset the second hue by 25–70° so the gradient reads as a gradient,
        // never as a flat wash.
        let spread = CGFloat(25 + (hash >> 16) % 46) / 360
        let hue2 = (hue + spread).truncatingRemainder(dividingBy: 1)

        let top = NSColor(hue: hue, saturation: 0.52, brightness: 0.34, alpha: 1)
        let bottom = NSColor(hue: hue2, saturation: 0.60, brightness: 0.16, alpha: 1)
        return (top, bottom)
    }

    /// Full-bleed backdrop: `image` aspect-fill cropped to `targetSize`, heavily
    /// blurred and dimmed. Pure CoreImage — safe to call from a background context,
    /// never touches the main thread.
    static func blurred(_ image: NSImage, targetSize: CGSize,
                        blurRadius: CGFloat, dim: Double) -> NSImage {
        guard targetSize.width >= 1, targetSize.height >= 1 else {
            return solidDark(CGSize(width: 1, height: 1))
        }
        guard let source = cgImage(from: image) else { return solidDark(targetSize) }

        let full = CIImage(cgImage: source)
        let longEdge = max(full.extent.width, full.extent.height)
        guard longEdge >= 1 else { return solidDark(targetSize) }

        // 1. Downscale before blurring. A 40pt-radius blur of a 200px image, upscaled,
        //    is indistinguishable from the same blur at 640px or at screen resolution —
        //    and ~10-150x cheaper. Lanczos samples outside the extent too, so this gets
        //    the same clamp treatment as the blur or the outer ring comes back translucent.
        let small = scaled(full, by: min(1, workingLongEdge / longEdge))

        // 2. Aspect-fill the square cover into the screen ratio, overflow trimmed evenly.
        let cropped = aspectFillCropped(small, aspect: targetSize.width / targetSize.height)
        let bounds = cropped.extent
        guard bounds.width >= 1, bounds.height >= 1 else { return solidDark(targetSize) }

        // 3. CIAffineClamp (clampedToExtent) before the gaussian, then crop back.
        //    Without it the blur samples transparent pixels past the edges and
        //    feathers the whole frame dark — the classic CIGaussianBlur artifact.
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = cropped.clampedToExtent()
        blur.radius = Float(blurRadius * (bounds.width / targetSize.width))
        guard let blurOutput = blur.outputImage else { return solidDark(targetSize) }
        var output = blurOutput.cropped(to: bounds)

        // 4. Dim by compositing black over it; dim == 0 leaves the image untouched.
        if dim > 0 {
            let alpha = min(max(dim, 0), 1)
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: alpha))
            output = black.cropped(to: bounds).composited(over: output)
        }

        // 5. Render at the working size, once, through the shared context. The
        //    bitmap stays ~200px while NSImage.size is targetSize *points*, so
        //    SwiftUI lays it out full-screen and the GPU does the upscale with
        //    the same linear filtering this used to do into a screen-sized
        //    bitmap: ~100 KB per backdrop instead of ~5 MB, and no big render.
        //    Whole pixels only, so no half-covered edge row renders translucent.
        let renderRect = CGRect(x: 0, y: 0,
                                width: max(bounds.width.rounded(.down), 1),
                                height: max(bounds.height.rounded(.down), 1))
        let rendered = context.createCGImage(output, from: renderRect)
        // The context is shared and long-lived; its intermediate buffers aren't
        // needed until the next track.
        context.clearCaches()
        guard let rendered else { return solidDark(targetSize) }

        let rep = NSBitmapImageRep(cgImage: rendered)
        rep.size = targetSize
        let result = NSImage(size: targetSize)
        result.addRepresentation(rep)
        return result
    }

    // MARK: - Backdrop internals

    private static let workingLongEdge: CGFloat = 200

    /// One context for the whole process — building a CIContext per call dominates
    /// the cost of the blur itself.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale < 1 else { return image }

        let target = image.extent.applying(CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image.clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1

        guard let output = filter.outputImage else {
            return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return output.cropped(to: target)
    }

    /// Centre-crops to `aspect` and moves the result back to the origin, so every
    /// downstream extent calculation starts at (0, 0).
    private static func aspectFillCropped(_ image: CIImage, aspect: CGFloat) -> CIImage {
        let extent = image.extent
        guard aspect > 0, extent.width > 0, extent.height > 0 else { return image }

        var width = extent.width
        var height = extent.height
        if width / height > aspect {
            width = height * aspect
        } else {
            height = width / aspect
        }

        let rect = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2,
                          width: width, height: height)
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Failure path. Deliberately not the untouched original — a crisp, undimmed
    /// full-screen cover behind the crisp centred cover reads as a bug, whereas
    /// near-black reads as "no backdrop yet".
    private static func solidDark(_ size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(white: 0.07, alpha: 1).setFill()
            rect.fill()
            return true
        }
    }

    private static func cgImage(from image: NSImage) -> CGImage? {
        for rep in image.representations {
            if let bitmap = rep as? NSBitmapImageRep, let cgImage = bitmap.cgImage {
                return cgImage
            }
        }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
