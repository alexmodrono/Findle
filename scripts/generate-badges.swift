// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.
//
// Draws the Finder badges in Resources/Badges.
// Usage: swift scripts/generate-badges.swift /tmp/badges
//        then: iconutil -c icns /tmp/badges/<Name>.iconset -o Resources/Badges/<Name>.icns

import AppKit
import CoreGraphics

enum Kind { case newDot, clock, updated }

func render(_ kind: Kind, size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.06
    let circle = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    // White ring keeps the badge legible on any icon.
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: circle)
    let ring = s * 0.09
    let inner = circle.insetBy(dx: ring, dy: ring)
    switch kind {
    case .newDot:
        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1)) // systemBlue
        ctx.fillEllipse(in: inner)
    case .clock:
        ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)) // systemOrange
        ctx.fillEllipse(in: inner)
        let c = CGPoint(x: s / 2, y: s / 2)
        let r = inner.width / 2
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1, r * 0.17))
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.58))
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + r * 0.42, y: c.y - r * 0.12))
        ctx.strokePath()
    case .updated:
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)) // systemGreen
        ctx.fillEllipse(in: inner)
        let c = CGPoint(x: s / 2, y: s / 2)
        let r = inner.width / 2
        // An upward arrow: a newer version replaced this one.
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(1, r * 0.2))
        ctx.move(to: CGPoint(x: c.x, y: c.y - r * 0.5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.5))
        ctx.move(to: CGPoint(x: c.x - r * 0.38, y: c.y + r * 0.12)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.5))
        ctx.addLine(to: CGPoint(x: c.x + r * 0.38, y: c.y + r * 0.12))
        ctx.strokePath()
    }
    let image = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
for (kind, name) in [(Kind.newDot, "NewBadge"), (Kind.clock, "DueSoonBadge"), (Kind.updated, "UpdatedBadge")] {
    let dir = "\(out)/\(name).iconset"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try! render(kind, size: base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
        try! render(kind, size: base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
    }
}
