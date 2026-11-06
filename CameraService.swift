import AVFoundation
import UIKit

/// Photo camera. Only a photo output is attached to the session, so the preview stays light
/// and taking photos never touches the microphone or interrupts the user's music.
final class CameraService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()

    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var displayZoom: CGFloat = 1
    @Published private(set) var zoomPresets: [CGFloat] = CameraService.cachedZoomPresets()
    @Published private(set) var permissionDenied = false
    @Published private(set) var isConfigured = false
    @Published private(set) var hasFlash = false

    private static let presetsKey = "geostamp.zoomPresets"
    private static func cachedZoomPresets() -> [CGFloat] {
        let saved = (UserDefaults.standard.array(forKey: presetsKey) as? [Double]) ?? []
        return saved.isEmpty ? [1] : saved.map { CGFloat($0) }
    }

    private let queue = DispatchQueue(label: "geostamp.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var zoomBase: CGFloat = 1
    private var minDisplayZoom: CGFloat = 1
    private var maxDisplayZoom: CGFloat = 10
    private var completion: ((Result<Data, Error>) -> Void)?
    private var lastValidOrientation: UIDeviceOrientation = .portrait

    // MARK: Lifecycle

    func start() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.configureAndRun() } else { self?.permissionDenied = true }
                }
            }
        default:
            permissionDenied = true
        }
    }

    func stop() {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        queue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureAndRun() {
        permissionDenied = false
        let pos = position
        queue.async { [weak self] in
            guard let self else { return }
            if !self.configured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                self.session.automaticallyConfiguresApplicationAudioSession = false
                if let d = Self.bestDevice(pos),
                   let input = try? AVCaptureDeviceInput(device: d),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.input = input
                    self.device = d
                }
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    // Favour shutter speed over multi-frame processing so the app never feels stuck.
                    self.photoOutput.maxPhotoQualityPrioritization = .speed
                }
                self.session.commitConfiguration()
                self.configured = true
                if let d = self.device { self.applyZoomSetup(d) }
                DispatchQueue.main.async { self.isConfigured = self.device != nil }
            }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private static func bestDevice(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera
        ]
        for t in types {
            if let d = AVCaptureDevice.default(t, for: .video, position: .back) { return d }
        }
        return nil
    }

    // MARK: Zoom, focus, flash, flip

    /// Display zoom 1.0 = main camera. 0.5 = ultra-wide on phones that have one.
    private func applyZoomSetup(_ d: AVCaptureDevice) {
        var base: CGFloat = 1
        if d.position == .back,
           d.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }),
           let first = d.virtualDeviceSwitchOverVideoZoomFactors.first {
            base = CGFloat(truncating: first)
        }
        zoomBase = base
        do {
            try d.lockForConfiguration()
            d.videoZoomFactor = max(base, d.minAvailableVideoZoomFactor)
            d.unlockForConfiguration()
        } catch {}

        minDisplayZoom = d.minAvailableVideoZoomFactor / base
        maxDisplayZoom = min(d.maxAvailableVideoZoomFactor / base, 10)
        let lo = minDisplayZoom, hi = maxDisplayZoom
        let filtered = [CGFloat(0.5), 1, 2, 3, 5].filter { $0 >= lo - 0.01 && $0 <= hi + 0.01 }
        let presets = filtered.isEmpty ? [1] : filtered
        let flash = d.hasFlash || d.hasTorch
        DispatchQueue.main.async {
            self.zoomPresets = presets
            UserDefaults.standard.set(presets.map { Double($0) }, forKey: Self.presetsKey)
            self.displayZoom = 1
            self.hasFlash = flash
        }
    }

    func setZoom(_ requested: CGFloat) {
        queue.async { [weak self] in
            guard let self, let d = self.device else { return }
            let z = max(self.minDisplayZoom, min(requested, self.maxDisplayZoom))
            do {
                try d.lockForConfiguration()
                d.videoZoomFactor = z * self.zoomBase
                d.unlockForConfiguration()
            } catch { return }
            DispatchQueue.main.async { self.displayZoom = z }
        }
    }

    /// `point` is in capture-device coordinates (0...1), from the preview layer converter.
    func focus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let d = self?.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isFocusPointOfInterestSupported {
                    d.focusPointOfInterest = point
                    d.focusMode = .continuousAutoFocus
                }
                if d.isExposurePointOfInterestSupported {
                    d.exposurePointOfInterest = point
                    d.exposureMode = .continuousAutoExposure
                }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        default: flashMode = .off
        }
    }

    func flip() {
        let newPos: AVCaptureDevice.Position = position == .back ? .front : .back
        queue.async { [weak self] in
            guard let self,
                  let d = Self.bestDevice(newPos),
                  let newInput = try? AVCaptureDeviceInput(device: d) else { return }
            self.session.beginConfiguration()
            let old = self.input
            if let old { self.session.removeInput(old) }
            var switched = false
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.input = newInput
                self.device = d
                switched = true
            } else if let old {
                self.session.addInput(old)
            }
            self.session.commitConfiguration()
            if switched {
                self.applyZoomSetup(d)
                DispatchQueue.main.async { self.position = newPos }
            }
        }
    }

    // MARK: Photo capture

    func capture(lockPortrait: Bool, completion: @escaping (Result<Data, Error>) -> Void) {
        let orientation = currentVideoOrientation(lockPortrait: lockPortrait)
        let flash = flashMode
        queue.async { [weak self] in
            guard let self else { return }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .speed
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            if let c = self.photoOutput.connection(with: .video), c.isVideoOrientationSupported {
                c.videoOrientation = orientation
            }
            self.completion = completion
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func currentVideoOrientation(lockPortrait: Bool) -> AVCaptureVideoOrientation {
        if lockPortrait { return .portrait }
        let o = UIDevice.current.orientation
        if o.isValidInterfaceOrientation { lastValidOrientation = o }
        switch lastValidOrientation {
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default: return .portrait
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let done = completion
        completion = nil
        if let error {
            DispatchQueue.main.async { done?(.failure(error)) }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                done?(.failure(NSError(domain: "GeoStampCam", code: 1, userInfo: [NSLocalizedDescriptionKey: "No image data"])))
            }
            return
        }
        DispatchQueue.main.async { done?(.success(data)) }
    }
}
