# GeoStamp Cam (iOS, SwiftUI)

A camera app that burns a location stamp into every photo: map, address, coordinates, date and time,
altitude, compass, weather, QR code, your note, project name, hashtags and your logo. It also writes GPS into the
photo's EXIF metadata and keeps a tamper-check fingerprint of every capture.

This is original code, inspired by the feature list of GPS Map Camera-style apps. It uses no branding, assets or
code from any existing app.

## Fastest way to test on an iPhone

No Mac? Read **SIDELOADLY_GUIDE.md**. It builds the .ipa on GitHub for free and installs it with Sideloadly,
with a 16-step test checklist.

## Build with Xcode (needs a Mac)

Xcode 15.2 or later, and an iPhone (the simulator has no real camera).

**Option A: XcodeGen (easiest)**
1. `brew install xcodegen`
2. In the folder containing `project.yml`, run `xcodegen`
3. Open `GeoStampCam.xcodeproj`

**Option B: Manual**
1. Xcode > New Project > iOS App, name `GeoStampCam`, SwiftUI, Swift.
2. Delete the generated `ContentView.swift` and `GeoStampCamApp.swift`.
3. Drag the inner `GeoStampCam/` folder into the project (tick "Copy items if needed").
4. Target > Info: add `Privacy - Camera Usage Description`,
   `Privacy - Location When In Use Usage Description`, `Privacy - Photo Library Additions Usage Description`
   (wording is in `project.yml`). Also add `Application supports iTunes file sharing` = YES.
5. Set the iOS Deployment Target to 16.0.

Then: choose your Team under Signing & Capabilities, change the bundle identifier, plug in the iPhone, Run.
On the phone, enable Developer Mode (Settings > Privacy & Security).

## Features

| Area | What you get |
|---|---|
| Camera | 0.5x ultra-wide, 1x/2x/3x/5x, pinch zoom, tap to focus, flash, timer 3s/10s, grid, front camera with mirror option, 4:3 / 1:1 / 16:9, volume-button shutter (iOS 17.2+), screen stays awake |
| Stamp templates | Classic, Advanced, Compact, Compass |
| Stamp fields | Map (standard, satellite, hybrid), address, country flag, lat/long (decimal or DMS), date formats with time zone, altitude, accuracy, compass, magnetic field, temperature, humidity, wind, pressure, project, note, hashtags, logo, QR code to the location, running photo number |
| Stamp look | Top or bottom, size, opacity, highlight colour, metric or imperial |
| Quick note | Pencil button on the camera: switch project, note and hashtags without opening Settings |
| Projects | Saved project list, tap to select |
| Before / After | "Tag" button adds a Before or After badge to the stamp |
| Trust | Burned-in stamp, GPS in EXIF, network-time check against a wrong phone clock, "Simulated location" warning |
| Saving | Photos app, with a copy in Files > On My iPhone > GeoStamp Cam if Photos access is off |
| Privacy | No account, no ads, no analytics. The microphone is never used, so photos never pause your music |

## Things to know

- **Not compiled in the build environment.** Expect a small number of compiler fixes on the first build. Send me the
  `error:` lines and I will fix them. The least certain spots are the volume-button code in
  `Components.swift` (if it errors, delete the `installHardwareButton` body) and the layout sizes in
  `CameraScreen.swift`.
- **Tamper-resistance is limited.** iOS reports when a location is software-simulated and the stamp warns about it,
  but a determined person with a jailbroken phone can still fake data. For legal or audit use, also keep your own server-side record.
- **Weather** comes from Open-Meteo (free, no key, non-commercial use). For a commercial app use their paid plan or
  Apple WeatherKit.
- **Address and map** use Apple's geocoder and Maps snapshots and need internet. Offline, the stamp shows
  coordinates only.
- **Altitude** is GPS altitude, not barometric.
- **Not included yet:** other languages, Google Drive sync (use the Files app), custom stamp
  dragging. Ask and I will add them.
- **App Store:** needs a paid Apple Developer account, an app icon, a privacy policy URL and the privacy label
  (location, photos).

## File map (all files sit in one folder)

- `StampSettings.swift`, `CaptureModels.swift` settings and capture data
- `LocationService`, `WeatherService`, `MapSnapshotService`, `TimeVerifier`, `CameraService` services
- `StampComposer`, `StampRenderer`, `Graphics`, `ExifWriter` stamp text, drawing, QR and compass, metadata
- `PhotosSaver.swift` save to Photos, Files backup, thumbnail
- `CameraViewModel.swift` ties it together
- `CameraScreen`, `Components`, `SettingsScreen`, `QuickNoteSheet`, `RootView` screens
