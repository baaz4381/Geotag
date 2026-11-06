import SwiftUI

/// The camera is the whole app. Settings opens over it from the gear button.
struct RootView: View {
    var body: some View {
        CameraScreen()
            .tint(.yellow)
    }
}
