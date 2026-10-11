// Screenshot harness. make.sh appends this to a copy of main.swift (with `private` stripped and
// Usage.latest served from demoUsage), so it sees the app's types. Demo data only, never real accounts.
let demoNow = Date()
let demoUsage: [String: Usage] = [
    "Claude": Usage(fiveHour: 42, week: 18, sampledAt: demoNow.addingTimeInterval(-20)),
    "Claude-Desktop": Usage(fiveHour: 12, week: 9, sampledAt: demoNow.addingTimeInterval(-4 * 60)),
    "Claude-Desktop-2": Usage(fiveHour: 0, week: 61, sampledAt: demoNow.addingTimeInterval(-70 * 60)),
]

func ago(_ minutes: Double) -> Date { demoNow.addingTimeInterval(-minutes * 60) }

var trackingMenu: NSMenu?

struct Capture { var image: NSBitmapImageRep; var size: NSSize }

func capture(_ window: NSWindow) -> Capture? {
    guard let v = window.contentView,
          let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return Capture(image: rep, size: v.bounds.size)
}

func rows(in view: NSView) -> [NSTableRowView] {
    if let row = view as? NSTableRowView { return [row] }
    return view.subviews.flatMap { rows(in: $0) }
}

MainActor.assumeIsolated {
    let dark = CommandLine.arguments.contains("--dark")
    let outPath = CommandLine.arguments[1]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    app.appearance = appearance

    let d = AppDelegate()
    d.accounts = [
        Account(name: "work@example.com", folder: "Claude"),
        Account(name: "personal@example.com", folder: "Claude-Desktop"),
        Account(name: "Client project", folder: "Claude-Desktop-2"),
        Account(name: "Account 4", folder: "Claude-Demo-Never-Opened"),
    ]
    d.titles = d.accounts.map(\.name)
    var snap = ProcessSnapshot()
    snap.mainPid = ["Claude": 101, "Claude-Desktop": 102, "Claude-Desktop-2": 103]
    snap.codeSessions = [
        "Claude": [
            CodeSession(title: "Refactor billing webhooks", project: "api-server", state: .waiting("permission prompt"), since: ago(2)),
            CodeSession(title: "Add dark mode to settings", project: "web-app", state: .working, since: ago(6)),
            CodeSession(title: "Fix flaky login test", project: "web-app", state: .idle, since: ago(38)),
        ],
        "Claude-Desktop": [
            CodeSession(title: "Draft launch blog post", project: "blog", state: .working, since: ago(3)),
        ],
    ]
    d.snapshot = snap
    d.rebuildMenu()

    var firstRow = NSRect.zero
    var shots: [Capture] = []
    func show(_ menu: NSMenu, recordRow: Bool) {
        trackingMenu = menu
        let opened = Date()
        // Poll until the menu window has fully faded in; the previous menu's window can linger while it fades out.
        let grab = Timer(timeInterval: 0.2, repeats: true) { timer in
            MainActor.assumeIsolated {
                let window = NSApp.windows.last(where: {
                    $0.isVisible && $0.alphaValue >= 1 && "\(type(of: $0))".contains("Popup")
                })
                guard let w = window, Date().timeIntervalSince(opened) > 0.6 else {
                    if Date().timeIntervalSince(opened) > 5 { timer.invalidate(); trackingMenu?.cancelTracking() }
                    return
                }
                if recordRow, let content = w.contentView,
                   let row = rows(in: content).min(by: { $0.frame.minY < $1.frame.minY }) {
                    firstRow = row.convert(row.bounds, to: nil)
                }
                if let c = capture(w) { shots.append(c) }
                timer.invalidate()
                trackingMenu?.cancelTracking()
            }
        }
        RunLoop.main.add(grab, forMode: .common)
        menu.popUp(positioning: nil, at: NSPoint(x: 300, y: 900), in: nil)
        grab.invalidate()
    }
    // popUp occasionally returns without opening the menu, so retry until it captures one.
    func showRetrying(_ menu: NSMenu, recordRow: Bool) {
        for _ in 0..<4 {
            let before = shots.count
            show(menu, recordRow: recordRow)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            if shots.count > before { return }
        }
    }
    showRetrying(d.menu, recordRow: true)
    showRetrying(d.menu.items[0].submenu!, recordRow: false)
    guard shots.count == 2, shots[0].size != shots[1].size else { print("capture failed, run again:", shots.map(\.size)); exit(1) }
    let root = shots[0], sub = shots[1]

    // Layout in points: a menu bar strip, the menu under the status item, the submenu beside the hovered row.
    let margin: CGFloat = 36, barHeight: CGFloat = 26, gap: CGFloat = 6
    let rootOrigin = NSPoint(x: margin, y: margin)
    let subX = rootOrigin.x + root.size.width - 4
    let width = subX + sub.size.width + margin
    let height = margin + root.size.height + gap + barHeight
    let rootRect = NSRect(origin: rootOrigin, size: root.size)
    let rootTop = rootRect.maxY
    let rowTopInRoot = root.size.height - firstRow.maxY
    let subRect = NSRect(x: subX, y: rootTop - rowTopInRoot + 5 - sub.size.height, width: sub.size.width, height: sub.size.height)

    let scale: CGFloat = 2
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    appearance.performAsCurrentDrawingAppearance {
        // Desktop.
        let desk = dark
            ? NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.15, blue: 0.22, alpha: 1), ending: NSColor(srgbRed: 0.27, green: 0.18, blue: 0.30, alpha: 1))!
            : NSGradient(starting: NSColor(srgbRed: 0.72, green: 0.82, blue: 0.95, alpha: 1), ending: NSColor(srgbRed: 0.93, green: 0.84, blue: 0.90, alpha: 1))!
        desk.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -35)

        // Menu bar strip with the status item, shown pressed.
        let bar = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        (dark ? NSColor(white: 0.08, alpha: 0.55) : NSColor(white: 1, alpha: 0.55)).setFill()
        bar.fill()
        let ink = dark ? NSColor.white : NSColor.black
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [ink]))
        let icon = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil)!
            .withSymbolConfiguration(iconConfig)!
        let count = NSAttributedString(string: "3", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: ink])
        let itemWidth = icon.size.width + 4 + count.size().width + 16
        let pill = NSRect(x: rootOrigin.x, y: bar.minY + 3, width: itemWidth, height: barHeight - 6)
        (dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.1)).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5).fill()
        icon.draw(in: NSRect(x: pill.minX + 8, y: pill.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height))
        count.draw(at: NSPoint(x: pill.minX + 8 + icon.size.width + 4, y: pill.midY - count.size().height / 2))

        var x = width - 18
        let clock = NSAttributedString(string: "Sun 7:12 PM", attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: ink])
        x -= clock.size().width
        clock.draw(at: NSPoint(x: x, y: bar.midY - clock.size().height / 2))
        for name in ["wifi", "battery.75percent"] {
            let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(iconConfig)!
            x -= symbol.size.width + 14
            symbol.draw(in: NSRect(x: x, y: bar.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        }

        func panel(_ rect: NSRect, _ image: Capture, highlight: NSRect?) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: dark ? 0.55 : 0.28)
            shadow.shadowBlurRadius = 22
            shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            (dark ? NSColor(srgbRed: 0.16, green: 0.16, blue: 0.17, alpha: 0.97) : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.97, alpha: 0.97)).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            if let highlight {
                let row = NSRect(x: rect.minX + highlight.minX + 5, y: rect.minY + highlight.minY, width: highlight.width - 10, height: highlight.height)
                (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            NSImage(cgImage: image.image.cgImage!, size: image.size).draw(in: rect)
            (dark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.14)).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        panel(rootRect, root, highlight: firstRow)
        panel(subRect, sub, highlight: nil)
    }
    NSGraphicsContext.restoreGraphicsState()

    let url = URL(fileURLWithPath: outPath).appendingPathComponent(dark ? "menu-dark.png" : "menu-light.png")
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote", url.path, Int(width * scale), "x", Int(height * scale))
}
