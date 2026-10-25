import AppKit
import Combine
import SwiftUI
import UserNotifications

// ---------------------------------------------------------------- 生成 App 图标（.icns）

// 开发工具：在 app/ 目录下跑 `./build/TokenBar.app/Contents/MacOS/TokenBar --icon`（需用 build.sh --devtools 编），
// Icon.iconset 和 AppIcon.icns 写到当前目录
@MainActor
enum IconMaker {
    static func run() {
        let base = FileManager.default.currentDirectoryPath
        let dir = base + "/Icon.iconset"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let level = sampleFuelLevel()
        let sizes: [(Int, String)] = [
            (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
            (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
            (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x"),
        ]
        for (px, name) in sizes {
            guard let data = plate(size: CGFloat(px), level: level) else { continue }
            try? data.write(to: URL(fileURLWithPath: dir + "/\(name).png"))
        }
        let out = base + "/AppIcon.icns"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", "-o", out, dir]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch {
            print("iconutil 启动失败: \(error.localizedDescription)")
            exit(1)
        }
        p.waitUntilExit()
        print("AppIcon.icns exit=\(p.terminationStatus) 油量=\(String(format: "%.3f", level))")
        exit(0)
    }

    /// 用离屏渲染的固定示例数据算油量读数（满盘按 ¥50，与 --render-check 一致），不再联网取数
    static func sampleFuelLevel() -> Double {
        guard let bal = RenderMode.sampleData().balance.cny else { return 0 }
        return max(0, min(1, bal / 50))
    }

    /// 圆角底板 + 仪表，1024 也能看清刻度
    static func plate(size: CGFloat, level: Double) -> Data? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let inset = size * 0.055
            let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
            let radius = size * 0.225
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
            if let g = NSGradient(colors: [NSColor(red: 0.10, green: 0.15, blue: 0.21, alpha: 1),
                                           NSColor(red: 0.04, green: 0.07, blue: 0.11, alpha: 1)]) {
                g.draw(in: rect, angle: -90)
            }
            NSGraphicsContext.restoreGraphicsState()
            let g2 = size * 0.432
            GaugeIcon.draw(in: NSRect(x: (size - g2) / 2, y: (size - g2) / 2, width: g2, height: g2),
                           value: level, tint: GaugeIcon.levelColor(level), showTicks: size >= 128)
            return true
        }
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
