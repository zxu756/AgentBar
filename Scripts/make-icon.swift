#!/usr/bin/env swift
import AppKit
import Foundation

let iconsetPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size)

    // Squircle obsidian-slate background
    let pad = s * 0.08
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    let colors = [
        CGColor(red: 0.09, green: 0.13, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0])!
    cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    // Segmented multi-agent telemetry arcs
    let center = CGPoint(x: s * 0.5, y: s * 0.46)
    let radius = s * 0.29
    let lineW = s * 0.075
    cg.setLineCap(.round)
    cg.setLineWidth(lineW)

    let segments: [(CGFloat, CGFloat, CGColor)] = [
        (205, 160, CGColor(red: 0.90, green: 0.50, blue: 0.36, alpha: 1.0)), // Claude
        (150, 108, CGColor(red: 0.20, green: 0.83, blue: 0.60, alpha: 1.0)), // Codex
        (98,  52,  CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1.0)), // OpenCode
        (42,  5,   CGColor(red: 0.98, green: 0.75, blue: 0.15, alpha: 1.0)), // Vibe
        (-5,  -25, CGColor(red: 0.66, green: 0.55, blue: 0.98, alpha: 1.0))  // AGY
    ]
    for (startDeg, endDeg, col) in segments {
        cg.setStrokeColor(col)
        cg.addArc(
            center: center,
            radius: radius,
            startAngle: startDeg * .pi / 180.0,
            endAngle: endDeg * .pi / 180.0,
            clockwise: true
        )
        cg.strokePath()
    }

    // Crisp instrument needle
    let needleAngle: CGFloat = 58.0 * .pi / 180.0
    let tip = CGPoint(x: center.x + cos(needleAngle) * (radius * 0.82), y: center.y + sin(needleAngle) * (radius * 0.82))
    cg.setStrokeColor(CGColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1.0))
    cg.setLineWidth(s * 0.036)
    cg.move(to: center)
    cg.addLine(to: tip)
    cg.strokePath()

    cg.setFillColor(CGColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1.0))
    let hub = s * 0.09
    cg.fillEllipse(in: CGRect(x: center.x - hub / 2, y: center.y - hub / 2, width: hub, height: hub))

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    try drawIcon(size: px).write(to: URL(fileURLWithPath: "\(iconsetPath)/\(name)"))
}
