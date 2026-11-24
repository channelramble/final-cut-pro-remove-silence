import SwiftUI
import SilenceCutCore

struct RemoverView: View {
    @ObservedObject var model: RemoverModel
    @ObservedObject var dropState: DropState
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .empty:
                emptyState
            case .analyzing(let progress):
                header
                analyzing(progress)
                Spacer(minLength: 0)
            case .ready:
                header
                preview
                settings
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(16)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity, alignment: .top)
        .overlay {
            if dropState.isTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.badge.minus")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Remove Silence")
                .font(.title2.weight(.semibold))
            Text("Drag a project here from the Final Cut Pro browser.")
                .multilineTextAlignment(.center)
            Text("Every silent stretch is cut out and the gaps are closed. You get a new project next to the original — the original isn't changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose an XML File…") { model.openPanel() }
                .padding(.top, 4)
            if let status = model.status {
                statusLabel(status)
                    .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            if model.projectNames.count > 1 {
                Picker("Project", selection: $model.selectedProject) {
                    ForEach(Array(model.projectNames.enumerated()), id: \.offset) { index, name in
                        Text(name).tag(index)
                    }
                }
                .labelsHidden()
            } else {
                Text(model.projectName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Close") { model.reset() }
                .buttonStyle(.link)
        }
    }

    private func analyzing(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progress)
            Text("Listening to the project's audio…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            WaveformView(levels: model.waveform, removed: model.removedFractions,
                         thresholdDB: model.result?.displayThresholdDB)
                .frame(height: 84)
            if let result = model.result {
                if result.cutCount == 0 {
                    Text("No silence found with these settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    let original = result.originalDuration.seconds, removed = result.removedDuration.seconds
                    HStack(spacing: 0) {
                        Text("\(result.cutCount) \(result.cutCount == 1 ? "silence" : "silences")")
                            .fontWeight(.semibold)
                        Text(" · removes \(clock(removed)) (\(Int((removed / max(original, 0.001) * 100).rounded()))%)")
                        Spacer()
                        Text("\(clock(original)) → \(clock(result.newDuration.seconds))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // The presets are meant to be left alone; the controls stay out of the way.
            Text("Cuts every silence longer than \(String(format: "%.2f", model.settings.minimumSilence)) s and joins the speech on either side tightly. Shorter pauses — the natural ones mid-thought — are left as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Adjust", isExpanded: $showSettings) {
                controls
                    .padding(.top, 8)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Detect the silence level automatically", isOn: $model.settings.autoThreshold)
                Text(model.settings.autoThreshold
                     ? "Measures each recording's background noise and voice level, and draws the line between them."
                     : "Anything quieter than the level below counts as silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            slider("Silence level",
                   value: model.settings.autoThreshold ? .constant(model.result?.displayThresholdDB ?? model.settings.thresholdDB)
                                                       : $model.settings.thresholdDB,
                   range: SilenceSettings.thresholdRange, step: 1,
                   label: String(format: "%.0f dB", model.settings.autoThreshold ? (model.result?.displayThresholdDB ?? model.settings.thresholdDB)
                                                                               : model.settings.thresholdDB),
                   help: "Lower (further left) is more cautious: only quieter audio is treated as silence.")
                .disabled(model.settings.autoThreshold)

            slider("Shortest silence to cut", value: $model.settings.minimumSilence,
                   range: SilenceSettings.minimumSilenceRange, step: 0.05,
                   label: String(format: "%.2f s", model.settings.minimumSilence),
                   help: "Pauses shorter than this are never cut, so speech keeps its natural rhythm.")

            slider("Gap left at each cut", value: $model.settings.padding,
                   range: SilenceSettings.paddingRange, step: 0.01,
                   label: String(format: "%.2f s", model.settings.padding),
                   help: "Quiet kept before and after each cut. Smaller is tighter clip-to-clip pacing; words are protected either way.")

            slider("Drop stray noises shorter than", value: $model.settings.minimumSound,
                   range: SilenceSettings.minimumSoundRange, step: 0.05,
                   label: String(format: "%.2f s", model.settings.minimumSound),
                   help: "A tap, click or sigh with silence on both sides is removed with the silence instead of being left as a tiny clip.")

            VStack(alignment: .leading, spacing: 4) {
                Picker("Listen to", selection: $model.settings.scope) {
                    Text("Primary storyline").tag(DetectionScope.primaryStoryline)
                    Text("All clips").tag(DetectionScope.allClips)
                }
                .pickerStyle(.segmented)
                Text(model.settings.scope == .primaryStoryline
                     ? "Connected clips (music, B-roll, titles) don't count and stay whole, moving with the clip they're attached to."
                     : "A moment is silent only if nothing is playing, connected clips included. Connected audio is cut too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.settings != .default {
                Button("Reset to Defaults") { model.settings = .default }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        label: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Snap in the binding rather than with `step:`, which would draw a tick mark per step.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = ($0 / step).rounded() * step }), in: range)
                .help(help)
                .accessibilityLabel(title)
                .accessibilityValue(label)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status { statusLabel(status) }
            HStack {
                if model.lastOutput != nil {
                    Button("Show File") { model.revealOutput() }
                }
                Spacer()
                Button {
                    model.createProject()
                } label: {
                    Text(model.isSending ? "Sending…" : "Create Silence-Free Project")
                        .frame(minWidth: 190)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!model.canCreate)
            }
        }
    }

    private func statusLabel(_ status: RemoverModel.Status) -> some View {
        Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(status.isError ? Color.red : Color.green)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }
}
