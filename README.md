# Contour Connect (iOS)

A personal iOS app to control a Contour+2 action camera (model 1700) over Bluetooth.
The original Contour Connect app is no longer available.

**Status: working.** Live preview (432×240 JPEG, ~3 fps), camera status (battery, storage, state,
switch position) and record start/stop all work on a Contour+2 with firmware 2.1.29.

## Protocol notes

- MFi accessory "Connect View", protocol string `com.contour` (ExternalAccessory framework).
- Over iOS the camera frames messages as `FF AA <length UInt16 BE> <cmd> <data…>`
  (the Android app's 11-byte header is not used here).
- Command numbers match the Android app: `0x01` preview on, `0x03` preview off, `0x04` JPEG frame
  (3 bytes, then JPEG), `0x05`/`0x06` preview started/stopped, `0x55` get settings → `0x58`,
  `0x75` get status → `0x76`, `0x90`/`0x91` record start/stop → `0x92`/`0x93`.
- Status payload (19 B, big endian): HDOP, battery %, capacity MB (u32), free MB (u32),
  state (u32: 0 paused, 1 preview, 2 recording, 3 stopped), seconds (u32), switch position.
- Settings: `0x55` → `0x58` (95 B), written with `0x57` (105 B, Android layout, zero padded),
  then `0x5A` apply → `0x5B` (0 = applying, 1 = done). Layout documented in `ContourSettings.swift`.

## Build

No Mac needed. Every push to `main` builds an unsigned `.ipa` with GitHub Actions:

1. Open the repository's **Actions** tab and the latest **Build IPA** run.
2. Download the `ContourConnect-ipa` artifact (a zip containing `ContourConnect.ipa`).

## Install (Windows)

1. Install iTunes from apple.com (not the Microsoft Store version) and Sideloadly.
2. Connect the iPhone by USB, drag `ContourConnect.ipa` into Sideloadly, sign in with your Apple ID, start.
3. On the iPhone: Settings › General › VPN & Device Management › trust your Apple ID.
4. Enable Developer Mode if iOS asks (Settings › Privacy & Security › Developer Mode).

With a free Apple ID the app runs for 7 days and then needs reinstalling.

## Test

1. Hold the camera's Bluetooth button 5 s, pair it in Settings › Bluetooth until it shows “Connected”.
2. Open **Contour Test**, tap **Refresh**.
3. Tap **Copy log** and send the log.

## Project layout

- `project.yml` – XcodeGen spec; the Xcode project is generated in CI.
- `Sources/` – SwiftUI app and `AccessoryMonitor` (ExternalAccessory framework).
- `.github/workflows/build.yml` – cloud build.
