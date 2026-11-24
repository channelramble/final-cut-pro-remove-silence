import AppKit

// Silence Remover — standalone companion to the Final Cut Pro workflow extension.
// The same interface runs inside Final Cut Pro (Window > Extensions > Remove Silence).

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let controller = RemoverViewController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentViewController: controller)
        window.title = "Silence Remover"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(RemoverViewController.preferredSize)
        window.contentMinSize = NSSize(width: 380, height: 540)
        window.setFrameAutosaveName("SilenceRemoverMainWindow")
        if window.frame.origin == .zero { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runSnapshotIfRequested()
    }

    /// Developer aid: `Silence Remover --snapshot <out.png> [project.fcpxml]` renders the window
    /// to an image once the project has been analyzed, then quits.
    private func runSnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), arguments.count > flag + 1 else { return }
        let output = URL(fileURLWithPath: arguments[flag + 1])
        if arguments.count > flag + 2 { controller.model.load(url: URL(fileURLWithPath: arguments[flag + 2])) }
        if arguments.contains("--manual") { controller.model.settings.autoThreshold = false }
        Task { @MainActor in
            for _ in 0..<600 {
                if case .analyzing = controller.model.phase { try? await Task.sleep(nanoseconds: 50_000_000) } else { break }
            }
            if arguments.contains("--create") {
                controller.model.createProject()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let view = window.contentView else { exit(2) }
            view.wantsLayer = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let scale: CGFloat = 2
            let size = view.bounds.size
            guard let layer = view.layer,
                  let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(2) }
            context.scaleBy(x: scale, y: scale)
            // Views don't draw the window background themselves; put it underneath.
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                context.setFillColor(NSColor.windowBackgroundColor.cgColor)
            }
            context.fill(CGRect(origin: .zero, size: size))
            if layer.isGeometryFlipped || view.isFlipped {
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
            }
            layer.render(in: context)
            if let image = context.makeImage() {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output)
            }
            exit(0)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if let url = urls.first { controller.model.load(url: url) }
    }

    @objc func openDocument(_ sender: Any?) { controller.model.openPanel() }

    @objc func showOutputFolder(_ sender: Any?) {
        if let url = try? FinalCutPro.outputDirectory() { NSWorkspace.shared.open(url) }
    }
}

@MainActor
func buildMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About Silence Remover", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Silence Remover", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit Silence Remover", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    main.addItem(appItem)

    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "File")
    let open = fileMenu.addItem(withTitle: "Open XML…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
    open.target = target
    let folder = fileMenu.addItem(withTitle: "Show Saved Projects in Finder", action: #selector(AppDelegate.showOutputFolder(_:)), keyEquivalent: "")
    folder.target = target
    fileMenu.addItem(.separator())
    fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    main.addItem(fileItem)

    let windowItem = NSMenuItem()
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    return main
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.mainMenu = buildMenu(target: delegate)
    // `run()` never returns, so `delegate` stays alive for the life of the app.
    app.run()
}
