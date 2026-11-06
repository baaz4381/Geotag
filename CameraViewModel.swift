import SwiftUI
import Combine
import CoreLocation
import UIKit

@MainActor
final class CameraViewModel: ObservableObject {
    let camera = CameraService()
    let weather = WeatherService()
    let mapService = MapSnapshotService()
    let timeVerifier = TimeVerifier()
    let settings: SettingsStore
    let location: LocationService

    @Published var countdown: Int?
    @Published var isSaving = false
    @Published var toast: String?
    @Published var lastThumb: UIImage?
    @Published var phase = ""               // "", "Before", "After"
    @Published var timerSeconds = 0         // 0, 3, 10
    @Published var focusPoint: CGPoint?

    private var cancellables = Set<AnyCancellable>()
    private var toastTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var cameraVisible = false
    private var captureToken = 0

    private static let serialKey = "geostamp.serial"

    init(settings: SettingsStore, location: LocationService) {
        self.settings = settings
        self.location = location

        // Re-render the camera screen when any child object changes.
        let forwards: [ObservableObjectPublisher] = [
            camera.objectWillChange, location.objectWillChange, weather.objectWillChange,
            mapService.objectWillChange, timeVerifier.objectWillChange,
            settings.objectWillChange
        ]
        // Throttled so fast sensors (compass, GPS, zoom) cannot flood SwiftUI,
        // and silent while Gallery or Settings is open.
        Publishers.MergeMany(forwards)
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.cameraVisible else { return }
                    self.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        // Refresh map and weather as the user moves.
        location.$location
            .compactMap { $0 }
            .throttle(for: .seconds(3), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] loc in
                guard let self else { return }
                Task { @MainActor in self.refreshContext(loc, cfg: self.settings.cfg) }
            }
            .store(in: &cancellables)

        // ...and when settings change (e.g. map type).
        settings.$cfg
            .removeDuplicates()
            .sink { [weak self] cfg in
                guard let self else { return }
                Task { @MainActor in
                    self.timeVerifier.useVerified = cfg.useVerifiedTime
                    self.refreshContext(self.location.location, cfg: cfg)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Lifecycle

    func start() {
        cameraVisible = true
        UIApplication.shared.isIdleTimerDisabled = true
        timeVerifier.useVerified = settings.cfg.useVerifiedTime
        location.start()
        camera.start()
        refreshContext(location.location, cfg: settings.cfg)

        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.timeVerifier.check()
                try? await Task.sleep(nanoseconds: 300_000_000_000)
            }
        }
    }

    /// Called when Settings opens or closes, so the camera screen does not redraw behind it.
    func setUIActive(_ active: Bool) {
        cameraVisible = active
        if active { objectWillChange.send() }
    }

    func stop() {
        cameraVisible = false
        UIApplication.shared.isIdleTimerDisabled = false
        camera.stop()
        clockTask?.cancel()
    }

    private func refreshContext(_ loc: CLLocation?, cfg: StampSettings) {
        guard let loc else { return }
        let needMap = cfg.template == .classic || (cfg.template == .advanced && cfg.showMap)
        let needWeather = cfg.template == .advanced &&
            (cfg.showWeather || cfg.showHumidity || cfg.showWind || cfg.showPressure)
        Task {
            if needMap { await mapService.refresh(coordinate: loc.coordinate, kind: cfg.mapKind) }
            if needWeather { await weather.refresh(for: loc) }
        }
    }

    // MARK: Numbering

    private var serialPeek: Int { UserDefaults.standard.integer(forKey: Self.serialKey) + 1 }
    private func commitSerial(_ n: Int) { UserDefaults.standard.set(n, forKey: Self.serialKey) }

    var nextSerial: Int { serialPeek }

    func resetSerial() {
        UserDefaults.standard.set(0, forKey: Self.serialKey)
        objectWillChange.send()
    }

    // MARK: Snapshot

    func makeSnapshot(serial: Int? = nil) -> CaptureSnapshot {
        var s = CaptureSnapshot(
            date: timeVerifier.now,
            location: location.location,
            address: location.address,
            headingDeg: location.heading?.bestHeading,
            magneticUT: location.heading?.totalField,
            weather: weather.weather,
            map: mapService.image,
            simulated: location.isSimulated,
            phase: phase
        )
        s.serial = serial
        return s
    }

    var previewContent: StampContent {
        let cfg = settings.cfg
        let serial = cfg.showSerial ? serialPeek : nil
        return StampComposer.build(makeSnapshot(serial: serial), cfg: cfg, logo: settings.logo)
    }

    // MARK: Controls

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
    }

    func cyclePhase() {
        switch phase {
        case "": phase = "Before"
        case "Before": phase = "After"
        default: phase = ""
        }
    }

    func tapFocus(device: CGPoint, layer: CGPoint) {
        camera.focus(at: device)
        focusPoint = layer
        focusTask?.cancel()
        focusTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if !Task.isCancelled { focusPoint = nil }
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    // MARK: Shutter

    func shutterTapped() {
        guard camera.isConfigured, countdown == nil else { return }

        guard !isSaving else { return }
        if timerSeconds > 0 {
            runCountdown { [weak self] in self?.capture() }
        } else {
            capture()
        }
    }

    private func runCountdown(then action: @escaping () -> Void) {
        let secs = timerSeconds
        Task {
            for i in stride(from: secs, to: 0, by: -1) {
                countdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            countdown = nil
            action()
        }
    }

    // MARK: Photo capture

    private func capture() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isSaving = true
        let cfg = settings.cfg
        let snapshot = makeSnapshot(serial: cfg.showSerial ? serialPeek : nil)   // frozen at the moment of the shutter
        let logo = settings.logo
        let mirror = camera.position == .front && cfg.mirrorFront

        // Take the number now so quick back-to-back shots never share one.
        if let n = snapshot.serial { commitSerial(n) }

        // Safety net: never leave the shutter stuck if the camera does not answer.
        captureToken += 1
        let token = captureToken
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.captureToken == token, self.isSaving else { return }
            self.isSaving = false
            self.showToast("The camera did not respond. Please try again.")
        }

        camera.capture(lockPortrait: cfg.lockPortrait) { [weak self] result in
            guard let self else { return }
            // The shutter is free again right away. Stamping and saving continue in the background.
            if self.captureToken == token { self.isSaving = false }
            switch result {
            case .failure:
                self.showToast("Capture failed. Please try again.")
            case .success(let data):
                Task { await self.process(data: data, snapshot: snapshot, cfg: cfg, logo: logo, mirror: mirror) }
            }
        }
    }

    private func process(data: Data, snapshot: CaptureSnapshot, cfg: StampSettings, logo: UIImage?, mirror: Bool) async {
        let result = await Task.detached(priority: .userInitiated) { () -> ProcessedPhoto? in
            PhotoPipeline.process(data: data, snapshot: snapshot, cfg: cfg, logo: logo, mirror: mirror)
        }.value

        guard let out = result else {
            showToast("Could not create the photo.")
            return
        }

        // One Photos transaction for the stamped photo (and the original, if asked), so a failure
        // can never leave a half-saved pair behind or write a second copy to Files.
        var savedToPhotos = false
        do {
            var files = [out.stamped]
            if let original = out.original { files.append(original) }
            try await PhotosSaver.save(jpegs: files, location: snapshot.location, date: snapshot.date)
            savedToPhotos = true
        } catch {
            savedToPhotos = false
        }
        // Safety net: never lose a capture.
        let savedToFiles = savedToPhotos ? false : BackupFolder.write(jpeg: out.stamped, date: snapshot.date)

        let stamped = out.stamped
        if let thumb = await Task.detached(priority: .utility, operation: { Thumbnails.image(from: stamped, maxPixel: 160) }).value {
            lastThumb = thumb
        }

        if savedToPhotos {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            showToast("Saved to Photos")
        } else if savedToFiles {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            showToast("Photos access is off. Saved in Files > GeoStamp Cam instead.")
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            showToast("Could not save the photo. Check storage and Photos access.")
        }
    }
}
