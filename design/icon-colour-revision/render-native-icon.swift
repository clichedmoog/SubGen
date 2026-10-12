import AppKit
let appPath = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
    let appearance = NSAppearance(named: name)!
    appearance.performAsCurrentDrawingAppearance {
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        for size in [1024, 512, 256, 128, 64, 32, 16] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: size, height: size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            icon.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: "\(outDir)/\(mode)-\(size).png"))
        }
    }
}
print("Rendered actual app icons from bundle: \(appPath)")
