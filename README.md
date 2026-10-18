# Contour Connect (iOS)

A personal iOS app to control a Contour+2 action camera (model 1700) over Bluetooth.
The original Contour Connect app is no longer available.

**Current stage: protocol discovery.** Confirmed: the camera appears as accessory "Connect View" (Contour+2, firmware 2.1.29) with protocol string `com.contour`, and an EASession opens. The app lists the Bluetooth accessories iOS
makes visible to it, shows what the camera reports (manufacturer, model, firmware,
protocol strings), and can open a raw data session to probe the camera's commands.

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
