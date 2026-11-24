import Foundation
import SilenceCutCore

// silencecut — remove silence from a Final Cut Pro project exported as FCPXML.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let usage = """
usage: silencecut <project.fcpxml | project.fcpxmld> [options]

  -o, --output <file>     where to write the new FCPXML (default: "<input> - Silence Removed.fcpxml")
      --threshold <dB>    silence level in dBFS, e.g. -35, or "auto" (default: auto)
      --min-silence <s>   only cut silences at least this long (default: 0.5)
      --padding <s>       keep this much quiet on each side of a cut (default: 0.15)
      --scope <which>     "primary" (default) or "all" (also listen to connected clips, and cut them)
      --project <name>    which project to process when the file holds several
      --name <name>       name for the new project
      --dry-run           report what would be cut without writing anything
      --list              print every cut
"""

var args = Array(CommandLine.arguments.dropFirst())
var input: String?
var output: String?
var settings = SilenceSettings.default
var projectName: String?
var newName: String?
var dryRun = false
var dumpLevels: String?
var list = false

func value(_ flag: String) -> String {
    guard !args.isEmpty else { fail("\(flag) needs a value\n\n\(usage)") }
    return args.removeFirst()
}

while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "-h", "--help": print(usage); exit(0)
    case "-o", "--output": output = value(arg)
    case "--threshold":
        let v = value(arg)
        if v.lowercased() == "auto" { settings.autoThreshold = true }
        else if let d = Double(v) { settings.autoThreshold = false; settings.thresholdDB = d }
        else { fail("--threshold expects a number of dB or \"auto\"") }
    case "--min-silence":
        guard let d = Double(value(arg)), d > 0 else { fail("--min-silence expects seconds") }
        settings.minimumSilence = d
    case "--padding":
        guard let d = Double(value(arg)), d >= 0 else { fail("--padding expects seconds") }
        settings.padding = d
    case "--scope":
        switch value(arg) {
        case "primary": settings.scope = .primaryStoryline
        case "all": settings.scope = .allClips
        default: fail("--scope expects \"primary\" or \"all\"")
        }
    case "--project": projectName = value(arg)
    case "--name": newName = value(arg)
    case "--dry-run": dryRun = true
    case "--dump-levels": dumpLevels = value(arg)   // developer aid: one loudness value (dB) per 10 ms of timeline
    case "--list": list = true
    default:
        if arg.hasPrefix("-") { fail("unknown option \(arg)\n\n\(usage)") }
        input = arg
    }
}

guard let input else { fail(usage) }

func clock(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                         : String(format: "%d:%02d", total / 60, total % 60)
}

do {
    let inputURL = URL(fileURLWithPath: input)
    let file = try FCPXMLFile(contentsOf: inputURL)
    guard !file.projects.isEmpty else { throw SilenceCutError.noProject }
    let project: FCPXMLFile.Project
    if let projectName {
        guard let match = file.projects.first(where: { $0.name == projectName }) else {
            fail("No project named \"\(projectName)\". Found: \(file.projects.map(\.name).joined(separator: ", "))")
        }
        project = match
    } else {
        project = file.projects[0]
    }

    let showProgress = isatty(FileHandle.standardError.fileDescriptor) != 0
    let analysis = try await file.analyze(project: project, scope: settings.scope) { fraction in
        if showProgress {
            FileHandle.standardError.write(Data(String(format: "\rReading audio… %3.0f%%", fraction * 100).utf8))
        }
    }
    if showProgress { FileHandle.standardError.write(Data("\r                      \r".utf8)) }
    for name in analysis.unreadableMedia {
        FileHandle.standardError.write(Data("warning: couldn't read audio for \"\(name)\"; clips using it are left untouched\n".utf8))
    }
    guard analysis.hasAudio else { throw SilenceCutError.noAudio }

    if let dumpLevels {
        let levels = analysis.displayLevels(buckets: analysis.hopCount)
        try levels.map { String(format: "%.1f", $0) }.joined(separator: "\n").write(toFile: dumpLevels, atomically: true, encoding: .utf8)
    }
    let result = SilenceDetector.detect(analysis, settings: settings)
    print("Project:   \(project.name)")
    if settings.autoThreshold {
        for t in result.thresholds { print(String(format: "Threshold: %.1f dB (auto, %@)", t.thresholdDB, t.media)) }
    } else {
        print(String(format: "Threshold: %.1f dB", settings.thresholdDB))
    }
    let original = result.originalDuration.seconds, removed = result.removedDuration.seconds
    print("Cuts:      \(result.cutCount)")
    print(String(format: "Removed:   %@ of %@ (%.0f%%)", clock(removed), clock(original), original > 0 ? removed / original * 100 : 0))
    print("New length: \(clock(result.newDuration.seconds))")
    if list {
        for r in result.removals {
            print(String(format: "  cut %9.3f – %9.3f  (%.2f s)", r.start.seconds - analysis.timelineStart.seconds,
                         r.end.seconds - analysis.timelineStart.seconds, r.duration.seconds))
        }
    }
    if dryRun { exit(0) }
    guard result.cutCount > 0 else {
        print("Nothing to cut.")
        exit(0)
    }

    let name = newName ?? "\(project.name) - Silence Removed"
    let data = try file.documentRemoving(result.removals, from: analysis, newProjectName: name)
    let outputURL: URL
    if let output {
        outputURL = URL(fileURLWithPath: output)
    } else {
        let base = inputURL.deletingPathExtension().lastPathComponent
        outputURL = inputURL.deletingLastPathComponent().appendingPathComponent("\(base) - Silence Removed.fcpxml")
    }
    try data.write(to: outputURL)
    print("Wrote \(outputURL.path)")
} catch {
    fail("error: \(error.localizedDescription)")
}
