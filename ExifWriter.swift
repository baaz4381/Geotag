import UIKit
import ImageIO
import CoreLocation
import UniformTypeIdentifiers

/// Encodes the stamped image as JPEG and, when a snapshot is given, writes GPS position, direction
/// and capture time into the EXIF/GPS metadata in the same step (so the photo is "geotagged" for
/// Photos, Maps, Google Photos, GIS tools, etc.).
enum ExifWriter {

    private static func formatter(_ pattern: String, utc: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if utc { f.timeZone = TimeZone(identifier: "UTC") }
        f.dateFormat = pattern
        return f
    }

    static func encode(_ image: UIImage, quality: CGFloat, snapshot s: CaptureSnapshot?, comment: String) -> Data? {
        guard let cg = image.cgImage else { return image.jpegData(compressionQuality: quality) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return image.jpegData(compressionQuality: quality)
        }

        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]

        if let s {
            let stamp = formatter("yyyy:MM:dd HH:mm:ss", utc: false).string(from: s.date)
            props[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: stamp,
                kCGImagePropertyExifDateTimeDigitized: stamp,
                kCGImagePropertyExifUserComment: comment
            ] as [CFString: Any]
            props[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFSoftware: "GeoStamp Cam",
                kCGImagePropertyTIFFDateTime: stamp
            ] as [CFString: Any]

            if let l = s.location {
                var gps: [CFString: Any] = [
                    kCGImagePropertyGPSLatitude: abs(l.coordinate.latitude),
                    kCGImagePropertyGPSLatitudeRef: l.coordinate.latitude >= 0 ? "N" : "S",
                    kCGImagePropertyGPSLongitude: abs(l.coordinate.longitude),
                    kCGImagePropertyGPSLongitudeRef: l.coordinate.longitude >= 0 ? "E" : "W",
                    kCGImagePropertyGPSTimeStamp: formatter("HH:mm:ss", utc: true).string(from: s.date),
                    kCGImagePropertyGPSDateStamp: formatter("yyyy:MM:dd", utc: true).string(from: s.date)
                ]
                if l.verticalAccuracy >= 0 {
                    gps[kCGImagePropertyGPSAltitude] = abs(l.altitude)
                    gps[kCGImagePropertyGPSAltitudeRef] = l.altitude >= 0 ? 0 : 1
                }
                if l.horizontalAccuracy >= 0 {
                    gps[kCGImagePropertyGPSHPositioningError] = l.horizontalAccuracy
                }
                if let h = s.headingDeg {
                    gps[kCGImagePropertyGPSImgDirection] = h
                    gps[kCGImagePropertyGPSImgDirectionRef] = "T"
                }
                props[kCGImagePropertyGPSDictionary] = gps
            }
        }

        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return image.jpegData(compressionQuality: quality) }
        return out as Data
    }
}
