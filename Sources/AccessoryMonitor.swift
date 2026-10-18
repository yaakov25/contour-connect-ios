import Foundation
import ExternalAccessory
import UIKit

/// Finds the Contour camera (MFi accessory, protocol "com.contour"), opens a session
/// and speaks the camera protocol: handshake, status polling, live preview, recording.
final class AccessoryMonitor: NSObject, ObservableObject, StreamDelegate {
    @Published var accessories: [EAAccessory] = []
    @Published var log: [String] = []
    @Published var sessionProtocol: String?

    // Camera state
    @Published var firmware: String?
    @Published var status: ContourProtocol.Status?
    @Published var previewRunning = false

    // Viewfinder
    @Published var latestFrame: UIImage?
    @Published var frameCount = 0
    @Published var fps: Double = 0
    @Published var rxTotalBytes = 0

    private var session: EASession?
    private var pendingOutput = Data()
    private var rxBuffer = Data()
    private var nextPacketID: UInt32 = 0
    private var statusTimer: Timer?
    private var fpsWindowStart = Date()
    private var fpsWindowFrames = 0

    /// Everything received in this app run, for export (capped).
    private(set) var rawCapture = Data()
    private let rawCaptureLimit = 20 * 1024 * 1024
    private var rxLogLines = 0

    /// Log every packet in detail (off by default once preview runs, it would flood the log).
    var verbosePackets = true

    let declaredProtocols: [String] =
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []

    override init() {
        super.init()
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidConnect(_:)),
                                               name: .EAAccessoryDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accessoryDidDisconnect(_:)),
                                               name: .EAAccessoryDidDisconnect, object: nil)
        append("App started. Declared protocols: \(declaredProtocols.joined(separator: ", "))")
        refresh()
    }

    // MARK: - Discovery

    func refresh() {
        accessories = EAAccessoryManager.shared().connectedAccessories
        append("Scan: \(accessories.count) accessory(ies) visible to this app")
        for accessory in accessories {
            append(describe(accessory))
        }
        if session == nil,
           let camera = accessories.first(where: { !$0.protocolStrings.isEmpty }),
           let proto = camera.protocolStrings.first {
            openSession(accessory: camera, protocolString: proto)
        }
    }

    func showPicker() {
        append("Opening Bluetooth accessory picker …")
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: nil) { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.append("Picker result: \(error.localizedDescription)")
                } else {
                    self?.append("Picker result: accessory selected")
                }
                self?.refresh()
            }
        }
    }

    @objc private func accessoryDidConnect(_ note: Notification) {
        let accessory = note.userInfo?[EAAccessoryKey] as? EAAccessory
        append("EVENT connected: \(accessory?.name ?? "?")")
        refresh()
    }

    @objc private func accessoryDidDisconnect(_ note: Notification) {
        let accessory = note.userInfo?[EAAccessoryKey] as? EAAccessory
        append("EVENT disconnected: \(accessory?.name ?? "?")")
        if let accessory = accessory, session?.accessory?.connectionID == accessory.connectionID {
            closeSession()
        }
        refresh()
    }

    func describe(_ a: EAAccessory) -> String {
        """
        • \(a.name)
          manufacturer: \(a.manufacturer)
          model: \(a.modelNumber)
          serial: \(a.serialNumber)
          firmware: \(a.firmwareRevision)
          hardware: \(a.hardwareRevision)
          connectionID: \(a.connectionID)  connected: \(a.isConnected)
          protocols: \(a.protocolStrings.isEmpty ? "(none reported)" : a.protocolStrings.joined(separator: ", "))
        """
    }

    // MARK: - Session

    func openSession(accessory: EAAccessory, protocolString: String) {
        closeSession()
        guard let newSession = EASession(accessory: accessory, forProtocol: protocolString) else {
            append("Session FAILED for \(protocolString)")
            return
        }
        session = newSession
        sessionProtocol = protocolString
        nextPacketID = 0
        rxBuffer.removeAll()
        status = nil
        firmware = nil
        verbosePackets = true
        for stream in [newSession.inputStream as Stream?, newSession.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        append("Session opened: \(protocolString)")
        // Handshake: the Android app sends an empty ACK first; the camera then identifies itself.
        sendRaw(ContourProtocol.ack(packetID: makePacketID()), label: "hello (ACK)")
    }

    func closeSession() {
        statusTimer?.invalidate()
        statusTimer = nil
        guard let current = session else { return }
        for stream in [current.inputStream as Stream?, current.outputStream as Stream?].compactMap({ $0 }) {
            stream.close()
            stream.remove(from: .main, forMode: .default)
            stream.delegate = nil
        }
        session = nil
        sessionProtocol = nil
        previewRunning = false
        pendingOutput.removeAll()
        append("Session closed")
    }

    // MARK: - Camera commands

    func startPreview() {
        sendCommand(.videoStreamOn)
        previewRunning = true
    }

    func stopPreview() {
        sendCommand(.videoStreamOff)
        previewRunning = false
    }

    func startRecording() { sendCommand(.recordStart) }
    func stopRecording() { sendCommand(.recordStop) }
    func requestStatus() { sendCommand(.getStatus, quiet: true) }
    func requestSettings() { sendCommand(.getSettings) }

    private func makePacketID() -> UInt32 {
        nextPacketID &+= 1
        return nextPacketID
    }

    private func sendCommand(_ cmd: ContourProtocol.Cmd, data: Data = Data(), quiet: Bool = false) {
        let packet = ContourProtocol.command(cmd.rawValue, data: data, packetID: makePacketID())
        sendRaw(packet, label: quiet ? nil : "CMD \(cmd)")
    }

    private func sendRaw(_ bytes: Data, label: String?) {
        guard session?.outputStream != nil else {
            append("No open session")
            return
        }
        pendingOutput.append(bytes)
        if let label = label {
            append("TX \(label): \(hex(bytes.prefix(32)))\(bytes.count > 32 ? " …" : "")")
        }
        flushOutput()
    }

    /// Sends bytes given as hex text, e.g. "01 02 ff" (debug).
    func sendHex(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else {
            append("Invalid hex input")
            return
        }
        var bytes = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            if let byte = UInt8(cleaned[index..<next], radix: 16) { bytes.append(byte) }
            index = next
        }
        sendRaw(bytes, label: "raw")
    }

    private func flushOutput() {
        guard let output = session?.outputStream, output.hasSpaceAvailable, !pendingOutput.isEmpty else { return }
        let written = pendingOutput.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.write(base, maxLength: pendingOutput.count)
        }
        if written > 0 { pendingOutput.removeFirst(written) }
    }

    // MARK: - Stream events

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            append("Stream open (\(aStream is InputStream ? "in" : "out"))")
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while input.hasBytesAvailable {
                let count = input.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                handleReceived(Data(buffer[0..<count]))
            }
        case .hasSpaceAvailable:
            flushOutput()
        case .errorOccurred:
            append("Stream error: \(aStream.streamError?.localizedDescription ?? "unknown")")
        case .endEncountered:
            append("Stream ended")
            closeSession()
        default:
            break
        }
    }

    // MARK: - Received data

    private func handleReceived(_ chunk: Data) {
        rxTotalBytes += chunk.count
        if rawCapture.count + chunk.count <= rawCaptureLimit {
            rawCapture.append(chunk)
        }
        rxBuffer.append(chunk)
        for packet in ContourProtocol.parse(&rxBuffer) {
            handlePacket(packet)
        }
    }

    private func handlePacket(_ packet: ContourProtocol.Packet) {
        guard packet.type == ContourProtocol.PacketType.cmd.rawValue, let cmdByte = packet.cmd else {
            return // ACKs from the camera need no action
        }
        // Every command from the camera is acknowledged with its packet ID + 1 (as the Android app does).
        sendRaw(ContourProtocol.ack(packetID: packet.packetID &+ 1), label: nil)

        let cmd = ContourProtocol.Cmd(rawValue: cmdByte)
        if verbosePackets && cmd != .jpeg {
            rxLogLines += 1
            if rxLogLines <= 300 {
                append("RX CMD 0x\(String(format: "%02X", cmdByte)) \(cmd.map { "\($0)" } ?? "?") id=\(packet.packetID) data=\(packet.data.count) B \(hex(packet.data.prefix(24)))")
            }
        }

        switch cmd {
        case .identify:
            let v = [UInt8](packet.data)
            firmware = v.map(String.init).joined(separator: ".")
            append("Camera identified, version bytes: \(firmware ?? "?")")
            // Same follow-up as the Android app: set clock, then ask for status.
            sendCommand(.startupUpdate, data: ContourProtocol.startupUpdatePayload())
            requestStatus()
            startStatusTimer()
        case .retStatus, .retStatusNew:
            let first = status == nil
            if let s = ContourProtocol.status(from: packet.data) {
                status = s
            }
            if first {
                // Android: after the first status, request settings and start the video stream.
                requestSettings()
                startPreview()
            }
        case .jpeg:
            if let jpeg = ContourProtocol.jpegData(from: packet), let image = UIImage(data: jpeg) {
                latestFrame = image
                frameCount += 1
                updateFPS()
                if frameCount == 1 {
                    append("First preview frame: \(Int(image.size.width))×\(Int(image.size.height)), \(jpeg.count) B")
                }
            }
        case .videoStreamStarted:
            previewRunning = true
            append("Preview started")
        case .videoStreamStopped:
            previewRunning = false
            append("Preview stopped")
        case .recordStarted:
            append("Recording started")
            requestStatus()
        case .recordStopped:
            append("Recording stopped")
            requestStatus()
        case .retSettings:
            append("Settings received (\(packet.data.count) B)")
        case .retConfigure:
            append("Configure state: \(packet.data.first.map(String.init) ?? "?")")
        case .debugText:
            append("Camera debug: \(String(decoding: packet.data, as: UTF8.self))")
        default:
            break
        }
    }

    private func startStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.requestStatus()
        }
    }

    private func updateFPS() {
        fpsWindowFrames += 1
        let elapsed = Date().timeIntervalSince(fpsWindowStart)
        if elapsed >= 2 {
            fps = Double(fpsWindowFrames) / elapsed
            fpsWindowFrames = 0
            fpsWindowStart = Date()
        }
    }

    /// Writes the raw capture to a temporary file for sharing.
    func exportRawCapture() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contour-rx.bin")
        do {
            try rawCapture.write(to: url)
            return url
        } catch {
            append("Export failed: \(error.localizedDescription)")
            return nil
        }
    }

    func resetCapture() {
        rawCapture.removeAll()
        rxTotalBytes = 0
        frameCount = 0
        rxLogLines = 0
        latestFrame = nil
        append("Capture reset")
    }

    // MARK: - Log

    var logText: String { log.joined(separator: "\n") }

    func clearLog() { log.removeAll() }

    private func append(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        let entry = "[\(stamp)] \(line)"
        if Thread.isMainThread {
            log.append(entry)
            if log.count > 2000 { log.removeFirst(log.count - 2000) }
        } else {
            DispatchQueue.main.async { self.log.append(entry) }
        }
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
