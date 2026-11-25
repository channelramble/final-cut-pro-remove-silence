import SwiftUI
import SilenceCutCore

struct RemoverView: View {
    @ObservedObject var model: RemoverModel
    @ObservedObject var dropState: DropState
    @AppStorage("showAdjust") private var showSettings = false

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
                // The opened-up settings are taller than a small window, so they scroll; the
                // waveform above stays put so every change can be seen as it is made.
                ScrollView {
                    settings
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
            Text("Cuts every silence longer than \(seconds(model.settings.minimumSilence)) and joins the speech on either side tightly. Shorter pauses are left as they are, and leftover bits of sound shorter than \(seconds(model.settings.minimumSound)) are thrown away.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Change how it cuts", isExpanded: $showSettings) {
                controls
                    .padding(.top, 10)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            // How long a silence has to be.
            slider("Only cut silences longer than",
                   value: $model.settings.minimumSilence, range: SilenceSettings.minimumSilenceRange, step: 0.05,
                   label: seconds(model.settings.minimumSilence),
                   lower: "cuts short pauses too", upper: "keeps longer pauses",
                   explanation: "A pause shorter than this is never touched. A normal breath between sentences is about half a second; the dead air after losing your train of thought is longer.")

            // How tight each cut is.
            slider("Silence left on each side of a cut",
                   value: $model.settings.padding, range: SilenceSettings.paddingRange, step: 0.01,
                   label: seconds(model.settings.padding),
                   lower: "tighter", upper: "more breathing room",
                   explanation: "Where a silence is cut out, this much quiet stays after the last word and before the next one. Raise it if the ends of words sound clipped.")

            // Tiny clips.
            slider("Throw away leftover clips shorter than",
                   value: $model.settings.minimumSound, range: SilenceSettings.minimumSoundRange, step: 0.05,
                   label: seconds(model.settings.minimumSound),
                   lower: "keeps tiny clips", upper: "removes longer leftovers",
                   explanation: "A bit of sound this short with silence on both sides — a click, a cough, a false start — is deleted along with the silence instead of becoming a tiny clip. Set high, a lone short word like “Okay” goes too.")

            // What counts as silence.
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Work out what counts as silence for me", isOn: $model.settings.autoThreshold)
                caption(model.settings.autoThreshold
                        ? "Recommended. The app listens to each recording and treats everything clearly quieter than your voice as silence."
                        : "Off: you choose the loudness below which audio counts as silence, with the slider underneath.")
                slider("Anything quieter than this is silence",
                       value: model.settings.autoThreshold ? .constant(model.result?.displayThresholdDB ?? model.settings.thresholdDB)
                                                           : $model.settings.thresholdDB,
                       range: SilenceSettings.thresholdRange, step: 1,
                       label: String(format: "%.0f dB", model.settings.autoThreshold ? (model.result?.displayThresholdDB ?? model.settings.thresholdDB)
                                                                                   : model.settings.thresholdDB),
                       lower: "only near-total quiet", upper: "quiet talking too",
                       explanation: model.settings.autoThreshold
                           ? "Chosen for this project automatically — it is the dashed line on the waveform. Turn the switch off to set it yourself."
                           : "It is the dashed line on the waveform. dB is loudness: 0 is the loudest possible and bigger negative numbers are quieter. Further left is safer; further right removes more.")
                    .disabled(model.settings.autoThreshold)
            }

            // Which clips are listened to.
            VStack(alignment: .leading, spacing: 6) {
                Text("Which clips are listened to")
                Picker("Which clips are listened to", selection: $model.settings.scope) {
                    Text("Main storyline only").tag(DetectionScope.primaryStoryline)
                    Text("Attached clips too").tag(DetectionScope.allClips)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                caption(model.settings.scope == .primaryStoryline
                        ? "Only the clips in the main (primary) storyline decide what is silent. Music, B-roll and titles attached above or below it are ignored and never cut; they move along with the clip they are attached to."
                        : "A moment only counts as silent if nothing at all is playing, attached clips included, and attached audio gets cut as well. Use this when your voice is on a clip attached to B-roll. With background music attached, nothing will be cut.")
            }

            if model.settings != .default {
                Button("Put everything back to the recommended settings") { model.settings = .default }
                    .buttonStyle(.link)
            }
        }
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2f s", value)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A slider that says, in words, what it changes: a title phrased as the rule it sets, the
    /// current value, what each end does, and a sentence of explanation.
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        label: String, lower: String, upper: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(label)
                    .monospacedDigit()
                    .fontWeight(.semibold)
            }
            // Snap in the binding rather than with `step:`, which would draw a tick mark per step.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = ($0 / step).rounded() * step }), in: range)
                .accessibilityLabel(title)
                .accessibilityValue(label)
                .accessibilityHint(explanation)
            HStack {
                Text("← " + lower)
                Spacer()
                Text(upper + " →")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            caption(explanation)
                .padding(.top, 2)
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
