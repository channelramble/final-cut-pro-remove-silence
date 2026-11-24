import AppKit

/// Talking to Final Cut Pro: finding it, recognising its drags, and handing projects back.
enum FinalCutPro {
    static let bundleIdentifiers = ["com.apple.FinalCutApp", "com.apple.FinalCut", "com.apple.FinalCutAppTrial", "com.apple.FinalCutTrial"]

    /// Pasteboard types Final Cut Pro offers when a project is dragged out of its browser,
    /// newest FCPXML version first.
    static let dragTypes: [NSPasteboard.PasteboardType] = {
        var types = (8...24).reversed().map { NSPasteboard.PasteboardType("com.apple.finalcutpro.xml.v1-\($0)") }
        types.append(NSPasteboard.PasteboardType("com.apple.finalcutpro.xml"))
        return types
    }()

    static func applicationURL() -> URL? {
        for id in bundleIdentifiers {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first, let url = running.bundleURL {
                return url
            }
        }
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return nil
    }

    /// Opens an FCPXML file in Final Cut Pro, which imports it into the library named in the file.
    @MainActor
    static func importFile(_ url: URL) async throws {
        guard let app = applicationURL() else {
            throw NSError(domain: "SilenceRemover", code: 1, userInfo: [NSLocalizedDescriptionKey: "Final Cut Pro isn't installed on this Mac."])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
    }

    /// ~/Movies/Silence Remover — a place both this app (sandboxed or not) and Final Cut Pro can reach.
    static func outputDirectory() throws -> URL {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            // Inside the sandbox the "home" is the container; this is the real one.
            home = URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        let directory = home.appendingPathComponent("Movies/Silence Remover", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
