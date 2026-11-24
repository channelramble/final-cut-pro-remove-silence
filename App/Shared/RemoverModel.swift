import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SilenceCutCore

@MainActor
final class RemoverModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case analyzing(Double)
        case ready
    }

    struct Status: Equatable {
        var text: String
        var isError = false
    }

    @Published private(set) var phase: Phase = .empty
    @Published private(set) var projectNames: [String] = []
    @Published var selectedProject = 0 { didSet { if oldValue != selectedProject { analyze() } } }
    @Published var settings: SilenceSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var result: DetectionResult?
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var removedFractions: [ClosedRange<Double>] = []
    @Published private(set) var warnings: [String] = []
    @Published var status: Status?
    @Published private(set) var lastOutput: URL?
    @Published private(set) var isSending = false

    private var file: FCPXMLFile?
    private var analysis: TimelineAnalysis?
    private var task: Task<Void, Never>?
    /// Bumped whenever the presets change, so retuned defaults replace previously saved values.
    private static let settingsKey = "SilenceSettings.v3"

    static let waveformBuckets = 900

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(SilenceSettings.self, from: data) {
            settings = saved
        } else {
            settings = .default
        }
    }

    var projectName: String { projectNames.indices.contains(selectedProject) ? projectNames[selectedProject] : "" }
    var canCreate: Bool { phase == .ready && (result?.cutCount ?? 0) > 0 && !isSending }

    // MARK: Loading

    func load(data: Data, baseURL: URL? = nil) {
        do {
            let file = try FCPXMLFile(data: data, baseURL: baseURL)
            guard !file.projects.isEmpty else { throw SilenceCutError.noProject }
            adopt(file)
        } catch {
            fail(error)
        }
    }

    func load(url: URL) {
        do {
            let file = try FCPXMLFile(contentsOf: url)
            guard !file.projects.isEmpty else { throw SilenceCutError.noProject }
            adopt(file)
        } catch {
            fail(error)
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["fcpxml", "fcpxmld"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a project exported from Final Cut Pro with File > Export XML"
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func reset() {
        task?.cancel()
        file = nil
        analysis = nil
        result = nil
        waveform = []
        removedFractions = []
        warnings = []
        projectNames = []
        status = nil
        lastOutput = nil
        phase = .empty
    }

    private func adopt(_ file: FCPXMLFile) {
        task?.cancel()
        self.file = file
        status = nil
        lastOutput = nil
        projectNames = file.projects.map(\.name)
        if selectedProject != 0 { selectedProject = 0 } else { analyze() }
    }

    private func fail(_ error: Error) {
        status = Status(text: error.localizedDescription, isError: true)
    }

    // MARK: Analysis

    func analyze() {
        guard let file, file.projects.indices.contains(selectedProject) else { return }
        task?.cancel()
        analysis = nil
        result = nil
        waveform = []
        removedFractions = []
        warnings = []
        phase = .analyzing(0)
        let project = file.projects[selectedProject]
        let scope = settings.scope
        task = Task { [weak self] in
            do {
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try await file.analyze(project: project, scope: scope) { fraction in
                        Task { @MainActor in
                            guard let self, case .analyzing = self.phase else { return }
                            self.phase = .analyzing(fraction)
                        }
                    }
                }.value
                guard let self, !Task.isCancelled else { return }
                guard analysis.hasAudio else { throw SilenceCutError.noAudio }
                self.analysis = analysis
                self.waveform = analysis.displayLevels(buckets: Self.waveformBuckets)
                self.warnings = analysis.unreadableMedia.map { "Couldn't read the audio of “\($0)” — clips using it are left untouched." }
                self.phase = .ready
                self.detect()
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .empty
                self.file = nil
                self.projectNames = []
                self.fail(error)
            }
        }
    }

    private func settingsChanged(from old: SilenceSettings) {
        guard old != settings else { return }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
        if old.scope != settings.scope { analyze() } else { detect() }
    }

    private func detect() {
        guard let analysis else { return }
        let result = SilenceDetector.detect(analysis, settings: settings)
        self.result = result
        let start = analysis.timelineStart.seconds, length = max(analysis.duration.seconds, 0.001)
        removedFractions = result.removals.map { (($0.start.seconds - start) / length)...(($0.end.seconds - start) / length) }
        lastOutput = nil
        if status?.isError == false { status = nil }
    }

    // MARK: Output

    func createProject() {
        guard let file, let analysis, let result, result.cutCount > 0 else { return }
        isSending = true
        let name = "\(projectName) - Silence Removed"
        Task {
            defer { isSending = false }
            do {
                let data = try file.documentRemoving(result.removals, from: analysis, newProjectName: name)
                let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
                let url = try FinalCutPro.outputDirectory().appendingPathComponent("\(safe).fcpxml")
                try data.write(to: url, options: .atomic)
                lastOutput = url
                do {
                    try await FinalCutPro.importFile(url)
                    status = Status(text: "Sent “\(name)” to Final Cut Pro. Look for it next to the original project.")
                } catch {
                    status = Status(text: "Saved the project, but couldn't hand it to Final Cut Pro: \(error.localizedDescription) Use Show File and drag it into Final Cut Pro, or choose File > Import > XML.", isError: true)
                }
            } catch {
                fail(error)
            }
        }
    }

    func revealOutput() {
        if let lastOutput { NSWorkspace.shared.activateFileViewerSelecting([lastOutput]) }
    }
}
