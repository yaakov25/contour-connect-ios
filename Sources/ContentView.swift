import SwiftUI
import ExternalAccessory
import UIKit

struct ContentView: View {
    @EnvironmentObject var monitor: AccessoryMonitor
    @State private var hexInput = ""
    @State private var shareURL: URL?
    @State private var showDebug = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ZStack {
                        Rectangle().fill(Color.black)
                        if let frame = monitor.latestFrame {
                            Image(uiImage: frame)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Text(monitor.sessionProtocol == nil ? "Camera not connected" : "Waiting for preview …")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .listRowInsets(EdgeInsets())

                    HStack {
                        Text(monitor.previewRunning ? "Preview on" : "Preview off")
                        Spacer()
                        Text(String(format: "%.1f fps · %d frames", monitor.fps, monitor.frameCount))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    HStack {
                        Button(monitor.previewRunning ? "Stop preview" : "Start preview") {
                            monitor.previewRunning ? monitor.stopPreview() : monitor.startPreview()
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                        if monitor.status?.isRecording == true {
                            Button("■ Stop recording", role: .destructive) { monitor.stopRecording() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("● Record") { monitor.startRecording() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                    }
                    .disabled(monitor.sessionProtocol == nil)
                }

                Section("Camera") {
                    if let s = monitor.status {
                        LabeledContent("State", value: s.stateText)
                        if s.isRecording {
                            LabeledContent("Recording", value: formatDuration(s.elapsedRecordSeconds))
                        }
                        LabeledContent("Battery", value: "\(s.batteryPercent) %")
                        LabeledContent("Storage free", value: formatKB(s.storageRemainingKB) + " of " + formatKB(s.storageCapacityKB))
                        LabeledContent("Switch position", value: "\(s.switchPosition)")
                        LabeledContent("GPS HDOP", value: "\(s.gpsHdop)")
                    } else {
                        Text(monitor.sessionProtocol == nil
                             ? "Pair the camera in Settings › Bluetooth, then tap Refresh."
                             : "Waiting for camera status …")
                            .foregroundStyle(.secondary)
                    }
                    if let fw = monitor.firmware {
                        LabeledContent("Version bytes", value: fw)
                    }
                    Button("Refresh") { monitor.refresh() }
                }

                Section {
                    DisclosureGroup("Debug", isExpanded: $showDebug) {
                        ForEach(monitor.accessories, id: \.connectionID) { accessory in
                            Text(monitor.describe(accessory))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text("Received: \(monitor.rxTotalBytes) B")
                            .font(.system(.footnote, design: .monospaced))
                        TextField("Hex bytes, e.g. 01 02 ff", text: $hexInput)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Send raw bytes") { monitor.sendHex(hexInput) }
                        Button("Request status") { monitor.requestStatus() }
                        Button("Request settings") { monitor.requestSettings() }
                        Button("Copy log") { UIPasteboard.general.string = monitor.logText }
                        if monitor.rxTotalBytes > 0 {
                            Button("Prepare raw data for sharing") { shareURL = monitor.exportRawCapture() }
                        }
                        if let url = shareURL {
                            ShareLink("Share contour-rx.bin", item: url)
                        }
                        Button("Reset capture", role: .destructive) { monitor.resetCapture() }
                        Button("Clear log", role: .destructive) { monitor.clearLog() }
                        ForEach(Array(monitor.log.suffix(300).enumerated().reversed()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Contour")
            .refreshable { monitor.refresh() }
            // iOS closes the accessory session when the app goes to the background; reconnect on return.
            .onChange(of: scenePhase) { phase in
                if phase == .active { monitor.refresh() }
            }
        }
    }

    /// The camera reports storage in MB (a 32 GB card shows ~29838).
    private func formatKB(_ mb: UInt32) -> String {
        let gb = Double(mb) / 1024
        return gb >= 1 ? String(format: "%.1f GB", gb) : "\(mb) MB"
    }

    private func formatDuration(_ seconds: UInt32) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
