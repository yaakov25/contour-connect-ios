import Foundation
import ExternalAccessory
import UIKit

/// Watches for MFi (iAP) accessories, shows what iOS reports about them,
/// and can open a raw data session so we can probe the camera's protocol.
final class AccessoryMonitor: NSObject, ObservableObject, StreamDelegate {
    @Published var accessories: [EAAccessory] = []
    @Published var log: [String] = []
    @Published var sessionProtocol: String?

    // Viewfinder: any JPEG found in the incoming byte stream is shown here.
    @Published var latestFrame: UIImage?
    @Published var frameCount = 0
    @Published var rxTotalBytes = 0

    private var session: EASession?
    private var pendingOutput = Data()
    private var frameBuffer = Data()
    /// Everything received in this app run, for export (capped).
    private(set) var rawCapture = Data()
    private let rawCaptureLimit = 20 * 1024 * 1024
    private var rxLogLines = 0

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
        // Open a session automatically so we never miss data the camera sends on its own.
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
        for stream in [newSession.inputStream as Stream?, newSession.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        append("Session opened: \(protocolString)")
    }

    func closeSession() {
        guard let current = session else { return }
        for stream in [current.inputStream as Stream?, current.outputStream as Stream?].compactMap({ $0 }) {
            stream.close()
            stream.remove(from: .main, forMode: .default)
            stream.delegate = nil
        }
        session = nil
        sessionProtocol = nil
        pendingOutput.removeAll()
        append("Session closed")
    }

    /// Sends bytes given as hex text, e.g. "01 02 ff".
    func sendHex(_ text: String) {
        let cleaned = text.replacingOccurrences(of: "0x", with: "")
            .filter { $0.isHexDigit }
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
        guard session?.outputStream != nil else {
            append("No open session")
            return
        }
        pendingOutput.append(bytes)
        append("TX \(bytes.count) B: \(hex(bytes))")
        flushOutput()
    }

    private func flushOutput() {
        guard let output = session?.outputStream, output.hasSpaceAvailable, !pendingOutput.isEmpty else { return }
        let written = pendingOutput.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.write(base, maxLength: pendingOutput.count)
        }
        if written > 0 { pendingOutput.removeFirst(written) }
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .openCompleted:
            append("Stream open (\(aStream is InputStream ? "in" : "out"))")
        case .hasBytesAvailable:
            guard let input = aStream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
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
        // Log the first 200 chunks in full detail (truncated to 64 bytes), then summarise,
        // so a video stream doesn't flood the log.
        rxLogLines += 1
        if rxLogLines <= 200 {
            let shown = chunk.prefix(64)
            let more = chunk.count > 64 ? " …" : ""
            append("RX \(chunk.count) B: \(hex(shown))\(more)")
        } else if rxLogLines % 100 == 0 {
            append("RX total so far: \(rxTotalBytes) B, frames: \(frameCount)")
        }
        extractJPEGFrames(from: chunk)
    }

    /// Looks for JPEG start (FF D8) and end (FF D9) markers and shows each complete image.
    private func extractJPEGFrames(from chunk: Data) {
        frameBuffer.append(chunk)
        let soi = Data([0xFF, 0xD8])
        let eoi = Data([0xFF, 0xD9])
        while true {
            guard let start = frameBuffer.range(of: soi) else {
                // Keep only a trailing 0xFF in case a marker is split across chunks.
                if let last = frameBuffer.last, last == 0xFF {
                    frameBuffer = Data([0xFF])
                } else {
                    frameBuffer.removeAll()
                }
                return
            }
            guard let end = frameBuffer.range(of: eoi, in: start.upperBound..<frameBuffer.endIndex) else {
                if start.lowerBound > frameBuffer.startIndex {
                    frameBuffer = Data(frameBuffer[start.lowerBound...])
                }
                if frameBuffer.count > 2 * 1024 * 1024 { frameBuffer.removeAll() } // runaway guard
                return
            }
            let jpeg = Data(frameBuffer[start.lowerBound..<end.upperBound])
            frameBuffer = Data(frameBuffer[end.upperBound...])
            if let image = UIImage(data: jpeg) {
                latestFrame = image
                frameCount += 1
                if frameCount == 1 {
                    append("First JPEG frame: \(Int(image.size.width))×\(Int(image.size.height)), \(jpeg.count) B")
                }
            }
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
        frameBuffer.removeAll()
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
