import SwiftUI

@main
struct GeoStampCamApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var location: LocationService
    @StateObject private var camera: CameraViewModel

    init() {
        let s = SettingsStore()
        let l = LocationService()
        _settings = StateObject(wrappedValue: s)
        _location = StateObject(wrappedValue: l)
        _camera = StateObject(wrappedValue: CameraViewModel(settings: s, location: l))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(location)
                .environmentObject(camera)
                .preferredColorScheme(.dark)
        }
    }
}
