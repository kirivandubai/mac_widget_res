#!/usr/bin/env swift
// Рисует иконку приложения и собирает её в .icns.
// Запуск: swift Tools/MakeIcon.swift <путь к AppIcon.icns>

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.icns"

/// Одна отрисовка иконки заданного размера в пикселях.
func drawIcon(size: CGFloat) -> Data? {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(size), pixelsHigh: Int(size),
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .calibratedRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Подложка: скруглённый квадрат с полями, как у системных иконок.
    let inset = size * 0.09
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let plateShape = NSBezierPath(roundedRect: plate,
                                  xRadius: plate.width * 0.235, yRadius: plate.width * 0.235)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.26, green: 0.56, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.11, green: 0.30, blue: 0.82, alpha: 1),
    ])?.draw(in: plateShape, angle: -90)

    // Столбики-индикаторы разной высоты.
    let heights: [CGFloat] = [0.34, 0.68, 0.46, 0.86]
    let barWidth = plate.width * 0.13
    let spacing = plate.width * 0.075
    let totalWidth = barWidth * CGFloat(heights.count) + spacing * CGFloat(heights.count - 1)
    let baseline = plate.minY + plate.height * 0.20
    var x = plate.midX - totalWidth / 2

    for (index, height) in heights.enumerated() {
        let bar = NSRect(x: x, y: baseline,
                         width: barWidth, height: plate.height * 0.62 * height)
        let shape = NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor(calibratedWhite: 1, alpha: index == heights.count - 1 ? 1.0 : 0.82).setFill()
        shape.fill()
        x += barWidth + spacing
    }

    return bitmap.representation(using: .png, properties: [:])
}

// Полный набор размеров, который ожидает iconutil.
let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    guard let data = drawIcon(size: variant.pixels) else {
        print("не удалось нарисовать \(variant.name)")
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent(variant.name + ".png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputPath]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

exit(iconutil.terminationStatus)
