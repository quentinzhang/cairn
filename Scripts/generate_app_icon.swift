#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let output = CommandLine.arguments.dropFirst().first
    ?? "Resources/AppIcon-1024.png"
private let side = 1024

// macOS icon grid: an 824×824 body centred on a 1024 canvas, corner radius
// 185.4. The margin is where the system's own shadow lands — the tile must
// not fill it.
private let tileSide: CGFloat = 824
private let tileCornerRadius: CGFloat = 185.4

private let markViewBox = CGSize(width: 108, height: 118)
private let markScale: CGFloat = 5.75
/// Bottom-left of the mark's viewBox, in the canvas's y-up coordinates.
private let markOrigin = CGPoint(x: 201.5, y: 170)

/// Keep these values identical to `Cairn.Mark` and the website's 108×118 SVG.
private struct MarkStone {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let rotation: CGFloat
    let seed: CGFloat
    var roundness: CGFloat = 2.7
    var jitter: CGFloat = 0.035

    /// The stone's centre on the icon canvas. The mark is authored y-down and
    /// the canvas is y-up, so the vertical axis flips here.
    var iconCenter: CGPoint {
        CGPoint(
            x: markOrigin.x + x * markScale,
            y: markOrigin.y + (markViewBox.height - y) * markScale
        )
    }
}

private let baseMarkStone = MarkStone(
    x: 54, y: 95, width: 82, height: 21, rotation: -2, seed: 0.6
)
private let middleMarkStone = MarkStone(
    x: 56, y: 67, width: 58, height: 19, rotation: 4, seed: 3.4
)
private let crownMarkStone = MarkStone(
    x: 52, y: 38, width: 24, height: 23.04, rotation: -8, seed: 5.2,
    roundness: 2.2, jitter: 0.06
)

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

private func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: colors.count == 2 ? [0, 1] : nil
    )!
}

/// The outline of a stone, centred on the origin and already scaled to the
/// canvas. Mirrors `Cairn.Mark.outline`; the two must stay in step.
private func stonePath(_ stone: MarkStone, steps: Int = 72) -> CGPath {
    let a = stone.width / 2 * markScale
    let b = stone.height / 2 * markScale
    let e = 2 / stone.roundness
    let path = CGMutablePath()
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let wobble = 1 + stone.jitter * (
            sin(stone.seed + t) * 0.62 + sin(stone.seed * 1.7 + t * 2) * 0.38
        )
        // The canvas is y-up; negate so the outline keeps the mark's handedness.
        let point = CGPoint(
            x: a * wobble * (ct < 0 ? -1 : 1) * pow(abs(ct), e),
            y: -b * wobble * (st < 0 ? -1 : 1) * pow(abs(st), e)
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

private func drawStone(
    in context: CGContext,
    stone: MarkStone,
    colors: [CGColor],
    shadow: Bool = true
) {
    let center = stone.iconCenter
    let width = stone.width * markScale
    let height = stone.height * markScale

    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    // Rotation is authored y-down, so it inverts on a y-up canvas.
    context.rotate(by: -stone.rotation * .pi / 180)
    let path = stonePath(stone)
    if shadow {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18),
            blur: 28,
            color: color(0x071315, alpha: 0.34)
        )
        context.addPath(path)
        context.setFillColor(color(0x2B474A))
        context.fillPath()
        context.restoreGState()
    }
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        gradient(colors),
        start: CGPoint(x: -width / 2, y: height / 2),
        end: CGPoint(x: width / 2, y: -height / 2),
        options: []
    )
    context.restoreGState()
}

guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: side,
    pixelsHigh: side,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon canvas")
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
let context = graphics.cgContext
context.clear(CGRect(x: 0, y: 0, width: side, height: side))

let inset = (CGFloat(side) - tileSide) / 2
let tile = CGRect(x: inset, y: inset, width: tileSide, height: tileSide)
let tilePath = CGPath(
    roundedRect: tile,
    cornerWidth: tileCornerRadius,
    cornerHeight: tileCornerRadius,
    transform: nil
)

// One soft drop shadow, wide enough that it never reads as a second edge
// against the tile's own near-black fill.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -22),
    blur: 44,
    color: color(0x071315, alpha: 0.30)
)
context.addPath(tilePath)
context.setFillColor(color(0x0D1F24))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(tilePath)
context.clip()
context.drawLinearGradient(
    gradient([color(0x1D373A), color(0x0D1F24)]),
    start: CGPoint(x: tile.minX, y: tile.maxY),
    end: CGPoint(x: tile.maxX, y: tile.minY),
    options: []
)

let ambient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x1A9E8A, alpha: 0.24), color(0x1A9E8A, alpha: 0)] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    ambient,
    startCenter: CGPoint(x: 355, y: 762),
    startRadius: 0,
    endCenter: CGPoint(x: 355, y: 762),
    endRadius: 580,
    options: []
)
context.restoreGState()

// Ground shadow: x 16…92, y 102.5…113.5 in mark space.
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -8),
    blur: 24,
    color: color(0x071315, alpha: 0.40)
)
context.setFillColor(color(0x071315, alpha: 0.42))
context.fillEllipse(
    in: CGRect(
        x: markOrigin.x + 16 * markScale,
        y: markOrigin.y + (markViewBox.height - 113.5) * markScale,
        width: 76 * markScale,
        height: 11 * markScale
    )
)
context.restoreGState()

drawStone(
    in: context,
    stone: baseMarkStone,
    colors: [color(0x758D8E), color(0x3C5659)]
)
drawStone(
    in: context,
    stone: middleMarkStone,
    colors: [color(0x2A9284), color(0x135B54)]
)

// The crown's halo sits under the stone, so the stone stays a hard silhouette.
let crownCenter = crownMarkStone.iconCenter
let crownGlow = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [color(0x8FDC8A, alpha: 0.42), color(0x8FDC8A, alpha: 0)] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    crownGlow,
    startCenter: crownCenter,
    startRadius: 0,
    endCenter: crownCenter,
    endRadius: 28.8 * markScale,
    options: []
)

drawStone(
    in: context,
    stone: crownMarkStone,
    colors: [color(0xDCEFBB), color(0x7FBF86)]
)

// The lit facet: drawn unrotated, on top of the crown.
context.setFillColor(color(0xF0FADD, alpha: 0.85))
context.fillEllipse(
    in: CGRect(
        x: markOrigin.x + 45.46 * markScale,
        y: markOrigin.y + (markViewBox.height - 39) * markScale,
        width: 10.08 * markScale,
        height: 7.2 * markScale
    )
)

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Generated \(output)")
