import Foundation

/// Contour+2 Bluetooth protocol, reconstructed from the Android "Contour Connect" app
/// (com.contour.api.CameraProtocol / CameraComms / CommThread).
///
/// Packet = 11-byte header (little endian) + body:
///   type      UInt8   1 = ACK, 2 = CMD
///   length    UInt32  body length (CMD: 1 + data.count, ACK: 0)
///   checksum  UInt16  CRC-16/ARC over cmd + data (camera sends 0)
///   packetID  UInt32
/// CMD body = cmd byte + data.
enum ContourProtocol {
    static let headerLength = 11

    enum PacketType: UInt8 {
        case ack = 1
        case cmd = 2
    }

    enum Cmd: UInt8 {
        case videoStreamOn = 0x01          // app -> camera
        case identify = 0x02               // camera -> app, data: firmware version bytes
        case videoStreamOff = 0x03         // app -> camera
        case jpeg = 0x04                   // camera -> app, 3 padding bytes then JPEG
        case videoStreamStarted = 0x05
        case videoStreamStopped = 0x06
        case getSettings = 0x55            // 85
        case setSettings = 0x57            // 87
        case retSettings = 0x58            // 88
        case setConfigure = 0x5A           // 90
        case retConfigure = 0x5B           // 91
        case retStatus = 0x74              // 116
        case getStatus = 0x75              // 117
        case retStatusNew = 0x76           // 118
        case recordStart = 0x90            // 144
        case recordStop = 0x91             // 145
        case recordStarted = 0x92          // 146
        case recordStopped = 0x93          // 147
        case startupUpdate = 0xAA          // 170: sets camera clock
        case debugText = 0xDD              // 221
    }

    struct Packet {
        let type: UInt8
        let packetID: UInt32
        let cmd: UInt8?
        let data: Data
    }

    // MARK: Encoding

    static func ack(packetID: UInt32) -> Data {
        var d = Data()
        d.append(PacketType.ack.rawValue)
        d.appendLE(UInt32(0))
        d.appendLE(UInt16(0))
        d.appendLE(packetID)
        return d
    }

    static func command(_ cmd: UInt8, data: Data = Data(), packetID: UInt32) -> Data {
        var body = Data([cmd])
        body.append(data)
        var d = Data()
        d.append(PacketType.cmd.rawValue)
        d.appendLE(UInt32(body.count))
        d.appendLE(crc16(body))
        d.appendLE(packetID)
        d.append(body)
        return d
    }

    /// Clock payload as the Android app sends it with CMD 0xAA.
    static func startupUpdatePayload(date: Date = Date(), timeZone: TimeZone = .current) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents(in: timeZone, from: date)
        let year = UInt32(c.year ?? 2026)
        // Android used the raw zone offset (without daylight saving), hours + 12 and |minutes| % 60.
        let rawOffset = timeZone.secondsFromGMT(for: date) - Int(timeZone.daylightSavingTimeOffset(for: date))
        let offsetHours = rawOffset / 3600 + 12
        let offsetMinutes = abs(rawOffset / 60) % 60
        var d = Data()
        d.append(UInt8((year >> 24) & 0xFF))
        d.append(UInt8((year >> 16) & 0xFF))
        d.append(UInt8((year >> 8) & 0xFF))
        d.append(UInt8(year & 0xFF))
        d.append(UInt8(c.month ?? 1))
        d.append(UInt8(c.day ?? 1))
        d.append(UInt8(c.hour ?? 0))
        d.append(UInt8(c.minute ?? 0))
        d.append(UInt8(c.second ?? 0))
        d.append(UInt8(truncatingIfNeeded: offsetHours))
        d.append(UInt8(offsetMinutes))
        return d
    }

    // MARK: Decoding

    /// Pulls complete packets off the front of `buffer`. Skips garbage bytes to resynchronise.
    static func parse(_ buffer: inout Data) -> [Packet] {
        var packets: [Packet] = []
        while buffer.count >= headerLength {
            let b = [UInt8](buffer.prefix(headerLength))
            let type = b[0]
            let length = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24
            guard type == PacketType.ack.rawValue || type == PacketType.cmd.rawValue, length < 1_000_000 else {
                buffer.removeFirst()   // not a header: drop one byte and try again
                continue
            }
            let total = headerLength + Int(length)
            guard buffer.count >= total else { break }
            let packetID = UInt32(b[7]) | UInt32(b[8]) << 8 | UInt32(b[9]) << 16 | UInt32(b[10]) << 24
            let start = buffer.startIndex
            var cmd: UInt8?
            var data = Data()
            if type == PacketType.cmd.rawValue, length >= 1 {
                cmd = buffer[start + headerLength]
                let dataStart = start + headerLength + 1
                let dataEnd = start + total
                if dataStart < dataEnd { data = Data(buffer[dataStart..<dataEnd]) }
            }
            packets.append(Packet(type: type, packetID: packetID, cmd: cmd, data: data))
            buffer = Data(buffer.dropFirst(total))
        }
        return packets
    }

    /// JPEG packets carry 3 bytes before the image.
    static func jpegData(from packet: Packet) -> Data? {
        guard packet.data.count > 3 else { return nil }
        return Data(packet.data.dropFirst(3))
    }

    struct Status {
        let gpsHdop: UInt8
        let batteryPercent: UInt8
        let storageCapacityKB: UInt32
        let storageRemainingKB: UInt32
        let cameraState: UInt32     // 0 preview paused, 1 preview, 2 recording, 3 recording stopped
        let elapsedRecordSeconds: UInt32
        let switchPosition: UInt8

        var stateText: String {
            switch cameraState {
            case 0: return "preview paused"
            case 1: return "preview"
            case 2: return "recording"
            case 3: return "recording stopped"
            default: return "state \(cameraState)"
            }
        }
        var isRecording: Bool { cameraState == 2 }
    }

    /// Status payload (CMD 0x74/0x76) is big endian.
    static func status(from data: Data) -> Status? {
        let b = [UInt8](data)
        guard b.count >= 19 else { return nil }
        func be32(_ i: Int) -> UInt32 { UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) }
        return Status(gpsHdop: b[0], batteryPercent: b[1],
                      storageCapacityKB: be32(2), storageRemainingKB: be32(6),
                      cameraState: be32(10), elapsedRecordSeconds: be32(14),
                      switchPosition: b[18])
    }

    // MARK: CRC-16/ARC (poly 0xA001 reflected, init 0) — matches the Android CRC16 table

    private static let crcTable: [UInt16] = (0..<256).map { i -> UInt16 in
        var crc = UInt16(i)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        return crc
    }

    static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt16(byte)) & 0xFF)] }
        return crc
    }
}

extension Data {
    mutating func appendLE(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}
