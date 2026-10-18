import Foundation

/// Camera settings block (CMD 0x58 from the camera, CMD 0x57 to the camera), big endian.
/// Layout from the Android app's CameraSettings.decodeByteArray / toByteArray:
///
///   per switch position (38 bytes, position 1 at offset 0, position 2 at offset 38):
///     +0  gps (UInt8, 0/1)      +1  beep (UInt8, 0/1)
///     +2  videoRes  +6 quality  +10 metering  +14 contrast  +18 exposure
///     +22 sharpness +26 mic     +30 photoInterval            +34 videoFormat   (all Int32)
///   76 gpsRate1  77 extMic1  78 whiteBalance1
///   79 gpsRate2  80 extMic2  81 whiteBalance2
///   82 model  83 major  84 minor  85 build
///
/// The camera sends 95 bytes; the Android app writes 105 bytes: the 82 setting bytes, then zeros.
struct ContourSettings: Equatable {
    struct Position: Equatable {
        var gps: Bool
        var beep: Bool
        var videoRes: Int32       // 0 1080p, 1 960p, 2 720p, 3 720p hi-fps, 4 photo, 5/6/7 480p
        var quality: Int32        // 0 low, 1 medium, 2 high
        var metering: Int32       // 0 center, 1 average, 2 spot
        var contrast: Int32       // 1...255 (default 62)
        var exposure: Int32       // 0...8 (Android: 4 = 0 EV; this camera reports 0)
        var sharpness: Int32      // 1...5 (default 3)
        var mic: Int32            // camera reports 45; Android slider 0...42
        var photoInterval: Int32  // seconds: 1,3,5,10,15,20,30,45,60
        var videoFormat: Int32    // 0 PAL (25/50/100), 1 NTSC (30/60/120)
        var gpsRate: UInt8        // Hz: 0,1,2,4,5
        var extMic: UInt8         // 0...42 on Android
        var whiteBalance: UInt8   // 0...7
    }

    var position1: Position
    var position2: Position
    let model: UInt8
    let version: String

    static let encodedLength = 105
    static let settingsBytes = 82

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 86 else { return nil }
        func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]))
        }
        func pos(_ base: Int, tail: Int) -> Position {
            Position(gps: b[base] > 0, beep: b[base + 1] > 0,
                     videoRes: i32(base + 2), quality: i32(base + 6), metering: i32(base + 10),
                     contrast: i32(base + 14), exposure: i32(base + 18), sharpness: i32(base + 22),
                     mic: i32(base + 26), photoInterval: i32(base + 30), videoFormat: i32(base + 34),
                     gpsRate: b[tail], extMic: b[tail + 1], whiteBalance: b[tail + 2])
        }
        position1 = pos(0, tail: 76)
        position2 = pos(38, tail: 79)
        model = b[82]
        version = "\(b[83]).\(b[84]).\(b[85])"
    }

    func encoded() -> Data {
        var d = Data()
        func put(_ v: Int32) {
            let u = UInt32(bitPattern: v)
            d.append(UInt8(u >> 24)); d.append(UInt8((u >> 16) & 0xFF))
            d.append(UInt8((u >> 8) & 0xFF)); d.append(UInt8(u & 0xFF))
        }
        for p in [position1, position2] {
            d.append(p.gps ? 1 : 0)
            d.append(p.beep ? 1 : 0)
            put(p.videoRes); put(p.quality); put(p.metering); put(p.contrast); put(p.exposure)
            put(p.sharpness); put(p.mic); put(p.photoInterval); put(p.videoFormat)
        }
        d.append(position1.gpsRate); d.append(position1.extMic); d.append(position1.whiteBalance)
        d.append(position2.gpsRate); d.append(position2.extMic); d.append(position2.whiteBalance)
        d.append(Data(count: Self.encodedLength - d.count))   // same zero padding as the Android app
        return d
    }

    subscript(position: Int) -> Position {
        get { position == 2 ? position2 : position1 }
        set { if position == 2 { position2 = newValue } else { position1 = newValue } }
    }

    // MARK: Option tables (labels from the Android app's resources)

    /// Order matches the Android menu for the Contour+2; values are the raw camera codes.
    static func videoModes(pal: Bool) -> [(Int32, String)] {
        let (a, b, c) = pal ? (25, 50, 100) : (30, 60, 120)
        return [(0, "1080p / \(a) fps"), (1, "960p / \(a) fps"), (2, "720p / \(a) fps"), (3, "720p / \(b) fps"),
                (5, "480p / \(a) fps"), (6, "480p / \(b) fps"), (7, "480p / \(c) fps"), (4, "Photo mode")]
    }
    static let qualities: [(Int32, String)] = [(0, "Low"), (1, "Medium"), (2, "High")]
    static let meterings: [(Int32, String)] = [(0, "Center"), (1, "Average"), (2, "Spot")]
    static let videoFormats: [(Int32, String)] = [(0, "PAL (25/50/100 fps)"), (1, "NTSC (30/60/120 fps)")]
    static let photoIntervals: [Int32] = [1, 3, 5, 10, 15, 20, 30, 45, 60]
    static let gpsRates: [UInt8] = [0, 1, 2, 4, 5]
    static let whiteBalances: [(UInt8, String)] = [(0, "Auto"), (1, "Incandescent"), (2, "Fluorescent"),
                                                   (3, "Daylight D50"), (4, "Daylight D65"), (5, "Cloudy"),
                                                   (6, "Shade"), (7, "Xenon")]
}
