#!/usr/bin/env swift
// Generates the Bealach app icon as a 1024x1024 PNG.
// Draws the same gauge-arc + navigation-needle as BealachMark.swift on the dark tile background.

import AppKit
import CoreGraphics

let size = 1024
let s = CGFloat(size)

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("No graphics context")
}

// Background: dark gradient matching BealachMark.tile
let bgColors: [CGFloat] = [
    0.18, 0.18, 0.10, 1.0,
    0.035, 0.04, 0.016, 1.0,
]
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorSpace: colorSpace, colorComponents: bgColors, locations: [0, 1], count: 2)!
let center = CGPoint(x: s / 2, y: s / 2)
ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.7, options: [.drawsAfterEndLocation])

// Coordinate helper (origin at top-left to match SwiftUI Canvas)
func point(_ x: Double, _ y: Double) -> CGPoint {
    CGPoint(x: x * s, y: s - y * s) // flip Y for CG
}

// Gauge arc
let arcCenter = point(0.5, 0.527)
let arcRadius = 0.332 * s
let startAngle = -CGFloat.pi * 140 / 180  // CG uses reversed angles
let endAngle = -CGFloat.pi * 400 / 180

ctx.setLineCap(.round)
ctx.setLineWidth(0.102 * s)

// Gradient stroke on arc - draw segments with color interpolation
let steps = 100
for i in 0..<steps {
    let t0 = CGFloat(i) / CGFloat(steps)
    let t1 = CGFloat(i + 1) / CGFloat(steps)
    let a0 = startAngle + (endAngle - startAngle) * t0
    let a1 = startAngle + (endAngle - startAngle) * t1

    let r = 1.0 * (1 - t0) + 0.0 * t0
    let g = 0.765 * (1 - t0) + 0.678 * t0
    let b = 1.0 * (1 - t0) + 1.0 * t0
    ctx.setStrokeColor(red: r, green: g, blue: b, alpha: 1)

    let path = CGMutablePath()
    path.addArc(center: arcCenter, radius: arcRadius, startAngle: a0, endAngle: a1, clockwise: true)
    ctx.addPath(path)
    ctx.strokePath()
}

// Needle
let tilt = 38.0 * .pi / 180
func arrow(_ x: Double, _ y: Double) -> CGPoint {
    let k = 0.21
    let xr = x * cos(tilt) - y * sin(tilt)
    let yr = x * sin(tilt) + y * cos(tilt)
    return point(0.5 + xr * k, 0.508 + yr * k)
}

let tip = arrow(0, -1)
let right = arrow(0.72, 0.92)
let notch = arrow(0, 0.46)
let left = arrow(-0.72, 0.92)

// Left facet (warm white)
let leftPath = CGMutablePath()
leftPath.move(to: tip)
leftPath.addLine(to: left)
leftPath.addLine(to: notch)
leftPath.closeSubpath()
ctx.setFillColor(red: 0.98, green: 0.98, blue: 0.88, alpha: 1)
ctx.addPath(leftPath)
ctx.fillPath()

// Right facet (white)
let rightPath = CGMutablePath()
rightPath.move(to: tip)
rightPath.addLine(to: right)
rightPath.addLine(to: notch)
rightPath.closeSubpath()
ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
ctx.addPath(rightPath)
ctx.fillPath()

image.unlockFocus()

// Save as PNG
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Failed to create PNG")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] :
    "Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
try! (png as NSData).write(toFile: outputPath, atomically: true)
print("Wrote \(outputPath) (\(png.count) bytes)")
