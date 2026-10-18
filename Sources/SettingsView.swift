import SwiftUI

/// Edits a local copy of the camera settings; "Save to camera" writes both switch positions at once.
struct SettingsView: View {
    @EnvironmentObject var monitor: AccessoryMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ContourSettings?
    @State private var position = 1

    var body: some View {
        NavigationStack {
            Group {
                if draft != nil {
                    form
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading settings from the camera …").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Camera settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save to camera") {
                        if let d = draft { monitor.saveSettings(d) }
                    }
                    .disabled(draft == nil || draft == monitor.settings || monitor.status?.isRecording == true)
                }
            }
        }
        .onAppear {
            position = Int(monitor.status?.switchPosition ?? 1) == 2 ? 2 : 1
            draft = monitor.settings
            if monitor.settings == nil { monitor.requestSettings() }
        }
        .onChange(of: monitor.settings) { newValue in
            // Take over fresh settings from the camera unless the user has unsaved edits.
            if draft == nil || draft == newValue || monitor.settingsMessage == "Saved to camera" {
                draft = newValue
            }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Switch position", selection: $position) {
                    Text("Position 1").tag(1)
                    Text("Position 2").tag(2)
                }
                .pickerStyle(.segmented)
            } footer: {
                let active = Int(monitor.status?.switchPosition ?? 0)
                Text(active == 0 ? "The camera has a two-position switch; each position has its own settings."
                                 : "The camera's switch is currently at position \(active).")
            }

            if let msg = monitor.settingsMessage {
                Section { Text(msg).foregroundStyle(.secondary) }
            }
            if monitor.status?.isRecording == true {
                Section { Text("Stop recording to change settings.").foregroundStyle(.orange) }
            }

            Section("Video") {
                Picker("Mode", selection: binding(\.videoRes)) {
                    ForEach(ContourSettings.videoModes(pal: current.videoFormat == 0), id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Quality", selection: binding(\.quality)) {
                    ForEach(ContourSettings.qualities, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Format", selection: binding(\.videoFormat)) {
                    ForEach(ContourSettings.videoFormats, id: \.0) { Text($0.1).tag($0.0) }
                }
                if current.videoRes == 4 {
                    Picker("Photo interval", selection: binding(\.photoInterval)) {
                        ForEach(ContourSettings.photoIntervals, id: \.self) { Text("every \($0) s").tag($0) }
                    }
                }
            }

            Section("Image") {
                Picker("Metering", selection: binding(\.metering)) {
                    ForEach(ContourSettings.meterings, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("White balance", selection: binding(\.whiteBalance)) {
                    ForEach(ContourSettings.whiteBalances, id: \.0) { Text($0.1).tag($0.0) }
                }
                Stepper(value: binding(\.exposure), in: 0...8) {
                    // Shown as the raw camera value: the Android app treated 4 as 0 EV, but this
                    // camera reports 0 with normal-looking images, so the scale is not certain.
                    LabeledContent("Exposure (0–8)", value: "\(current.exposure)")
                }
                Stepper(value: binding(\.sharpness), in: 1...5) {
                    LabeledContent("Sharpness", value: "\(current.sharpness)")
                }
                VStack(alignment: .leading) {
                    LabeledContent("Contrast", value: "\(current.contrast)")
                    Slider(value: doubleBinding(\.contrast), in: 1...255, step: 1)
                }
            }

            Section("Audio") {
                Stepper(value: binding(\.mic), in: 0...63) {
                    LabeledContent("Internal mic", value: "\(current.mic)")
                }
                Stepper(value: byteBinding(\.extMic), in: 0...63) {
                    LabeledContent("External mic", value: "\(current.extMic)")
                }
            }

            Section("Other") {
                Toggle("GPS", isOn: binding(\.gps))
                if current.gps {
                    Picker("GPS rate", selection: binding(\.gpsRate)) {
                        ForEach(ContourSettings.gpsRates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                }
                Toggle("Beeps", isOn: binding(\.beep))
            }

            if let s = draft {
                Section {
                    Button("Discard changes") { draft = monitor.settings }
                        .disabled(draft == monitor.settings)
                    Button("Re-read from camera") { monitor.requestSettings() }
                } footer: {
                    Text("Camera model \(s.model), settings version \(s.version). Changes take effect after “Save to camera”.")
                }
            }
        }
    }

    // MARK: - Bindings into the draft for the selected position

    private var current: ContourSettings.Position {
        draft?[position] ?? ContourSettings.Position(gps: false, beep: false, videoRes: 0, quality: 0, metering: 0,
                                                     contrast: 62, exposure: 4, sharpness: 3, mic: 0,
                                                     photoInterval: 3, videoFormat: 1, gpsRate: 0, extMic: 0,
                                                     whiteBalance: 0)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ContourSettings.Position, T>) -> Binding<T> {
        Binding(
            get: { current[keyPath: keyPath] },
            set: { newValue in
                guard var d = draft else { return }
                var p = d[position]
                p[keyPath: keyPath] = newValue
                d[position] = p
                draft = d
                monitor.settingsMessage = nil
            }
        )
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<ContourSettings.Position, Int32>) -> Binding<Double> {
        let b = binding(keyPath)
        return Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int32($0) })
    }

    private func byteBinding(_ keyPath: WritableKeyPath<ContourSettings.Position, UInt8>) -> Binding<Int> {
        let b = binding(keyPath)
        return Binding(get: { Int(b.wrappedValue) }, set: { b.wrappedValue = UInt8(clamping: $0) })
    }

}
