import SwiftUI
import ExternalAccessory
import UIKit

struct ContentView: View {
    @EnvironmentObject var monitor: AccessoryMonitor
    @State private var hexInput = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Accessories visible to this app") {
                    if monitor.accessories.isEmpty {
                        Text("None. Make sure the camera shows “Connected” in Settings › Bluetooth, then tap Refresh.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(monitor.accessories, id: \.connectionID) { accessory in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(monitor.describe(accessory))
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                            ForEach(accessory.protocolStrings, id: \.self) { proto in
                                Button("Open session: \(proto)") {
                                    monitor.openSession(accessory: accessory, protocolString: proto)
                                }
                                .font(.footnote)
                            }
                        }
                    }
                }

                Section("Actions") {
                    Button("Refresh") { monitor.refresh() }
                    Button("Show Bluetooth accessory picker") { monitor.showPicker() }
                    Button("Copy log") { UIPasteboard.general.string = monitor.logText }
                    Button("Clear log", role: .destructive) { monitor.clearLog() }
                }

                if let proto = monitor.sessionProtocol {
                    Section("Session: \(proto)") {
                        TextField("Hex bytes, e.g. 01 02 ff", text: $hexInput)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Send") { monitor.sendHex(hexInput) }
                        Button("Close session", role: .destructive) { monitor.closeSession() }
                    }
                }

                Section("Log") {
                    ForEach(Array(monitor.log.enumerated().reversed()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Contour Test")
            .refreshable { monitor.refresh() }
        }
    }
}
