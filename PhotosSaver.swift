import Photos
import CoreLocation
import UIKit
import ImageIO

// MARK: - Save to the system Photos library

enum PhotosSaver {
    enum SaveError: Error { case denied, failed }

    /// Asks for "add photos" permission (shows the iOS prompt only the first time).
    static func authorize() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .authorized || current == .limited { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
    }

    /// Saves one or more JPEGs in a single Photos transaction (all or nothing).
    static func save(jpegs: [Data], location: CLLocation?, date: Date) async throws {
        try await authorize()
        try await PHPhotoLibrary.shared().performChanges {
            for jpeg in jpegs {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = "public.jpeg"
                request.addResource(with: .photo, data: jpeg, options: options)
                request.location = location
                request.creationDate = date
            }
        }
    }
}

// MARK: - Safety net

/// If the Photos library refuses (permission off, storage full), the file is kept here instead
/// so a capture is never lost. Visible in the Files app under On My iPhone > GeoStamp Cam.
enum BackupFolder {
    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeoStampCam", isDirectory: true)
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    @discardableResult
    static func write(jpeg: Data, date: Date) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "GSC_\(nameFormatter.string(from: date))_\(String(UUID().uuidString.prefix(4))).jpg"
        do {
            try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic)
            return true
        } catch { return false }
    }
}

// MARK: - Small thumbnail for the camera screen

enum Thumbnails {
    static func image(from data: Data, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
