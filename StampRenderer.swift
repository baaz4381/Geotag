import UIKit

/// Burns the stamp into the pixels of the photo, so it cannot be removed without editing the image.
enum StampRenderer {

    // MARK: Rendering

    /// Mirror (front camera), centre-crop to the chosen shape and draw the stamp in ONE pass.
    /// The old pipeline redrew the full-resolution photo three times (mirror, crop, stamp).
    static func render(photo: UIImage, content: StampContent, cfg: StampSettings, mirror: Bool) -> UIImage {
        let src = photo.size
        var out = src
        if let r = cfg.aspect.portraitRatio {
            let isPortrait = src.height >= src.width
            let target = isPortrait ? r : 1 / r             // desired width / height
            if abs(src.width / src.height - target) >= 0.002 {
                if src.width / src.height > target { out.width = (src.height * target).rounded() }
                else { out.height = (src.width / target).rounded() }
            }
        }
        let origin = CGPoint(x: (out.width - src.width) / 2, y: (out.height - src.height) / 2)

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        return UIGraphicsImageRenderer(size: out, format: fmt).image { ctx in
            let c = ctx.cgContext
            c.saveGState()
            if mirror {
                c.translateBy(x: out.width, y: 0)
                c.scaleBy(x: -1, y: 1)
            }
            photo.draw(in: CGRect(origin: origin, size: src))
            c.restoreGState()
            drawStamp(in: c, size: out, content: content, cfg: cfg)
        }
    }

    // MARK: Drawing

    private static func drawStamp(in ctx: CGContext, size: CGSize, content: StampContent, cfg: StampSettings) {
        let u = (min(size.width, size.height) / 390.0) * CGFloat(cfg.scale)
        let accent = cfg.accent.uiColor

        let margin = 10 * u
        let pad = 8 * u
        let gap = 8 * u
        let panelW = min(size.width - 2 * margin, 390 * u - 2 * margin)
        let mapSide: CGFloat = content.map == nil ? 0 : 88 * u
        let qrSide: CGFloat = content.qr == nil ? 0 : 64 * u
        let textX = pad + (mapSide > 0 ? mapSide + gap : 0)
        let textW = max(panelW - textX - pad - (qrSide > 0 ? qrSide + gap : 0), 10)

        let titleFont = UIFont.systemFont(ofSize: 13.5 * u, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: 11.5 * u, weight: .medium)
        let smallFont = UIFont.systemFont(ofSize: 10.5 * u, weight: .regular)
        let badgeFont = UIFont.systemFont(ofSize: 10.5 * u, weight: .heavy)

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 1 * u

        func attr(_ s: String, _ f: UIFont, _ color: UIColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: para])
        }

        var blocks: [NSAttributedString] = []
        if let b = content.badge { blocks.append(attr("● " + b, badgeFont, accent)) }
        if !content.title.isEmpty { blocks.append(attr(content.title, titleFont, .white)) }
        for l in content.lines { blocks.append(attr(l, bodyFont, UIColor.white.withAlphaComponent(0.95))) }
        if !content.metrics.isEmpty {
            blocks.append(attr(content.metrics.joined(separator: "  •  "), smallFont, UIColor.white.withAlphaComponent(0.85)))
        }
        for t in content.tags { blocks.append(attr(t, smallFont, accent)) }
        if let w = content.warning { blocks.append(attr(w, smallFont, .orange)) }

        if blocks.isEmpty && content.map == nil && content.qr == nil { return }

        let opts: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let spacing = 2 * u
        let heights: [CGFloat] = blocks.map {
            ceil($0.boundingRect(with: CGSize(width: textW, height: .greatestFiniteMagnitude), options: opts, context: nil).height)
        }
        let textH = heights.reduce(0, +) + spacing * CGFloat(max(0, blocks.count - 1))
        let panelH = max(textH, max(mapSide, qrSide)) + 2 * pad
        let panelX = (size.width - panelW) / 2
        let panelY = cfg.position == .bottom ? size.height - margin - panelH : margin
        let panel = CGRect(x: panelX, y: panelY, width: panelW, height: panelH)

        UIColor.black.withAlphaComponent(CGFloat(cfg.opacity)).setFill()
        UIBezierPath(roundedRect: panel, cornerRadius: 10 * u).fill()

        if let map = content.map {
            let r = CGRect(x: panel.minX + pad, y: panel.minY + pad, width: mapSide, height: mapSide)
            ctx.saveGState()
            UIBezierPath(roundedRect: r, cornerRadius: 6 * u).addClip()
            map.draw(in: r)
            ctx.restoreGState()
        }

        if let qr = content.qr {
            let r = CGRect(x: panel.maxX - pad - qrSide, y: panel.minY + pad, width: qrSide, height: qrSide)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: r.insetBy(dx: -3 * u, dy: -3 * u), cornerRadius: 4 * u).fill()
            qr.draw(in: r)
        }

        var y = panel.minY + pad
        for (i, b) in blocks.enumerated() {
            let rect = CGRect(x: panel.minX + textX, y: y, width: textW, height: heights[i])
            b.draw(with: rect, options: opts, context: nil)
            y += heights[i] + spacing
        }

        if let logo = content.logo, logo.size.height > 0 {
            let aspect = logo.size.width / logo.size.height
            var lh = 36 * u
            var lw = lh * aspect
            let maxW = 120 * u
            if lw > maxW { lw = maxW; lh = lw / aspect }
            let lx = panel.maxX - lw
            let ly = cfg.position == .bottom ? panel.minY - lh - 6 * u : panel.maxY + 6 * u
            logo.draw(in: CGRect(x: lx, y: ly, width: lw, height: lh))
        }
    }
}

// MARK: - Whole pipeline (runs off the main thread)

struct ProcessedPhoto {
    let stamped: Data
    let original: Data?
}

enum PhotoPipeline {
    static func process(data: Data,
                        snapshot: CaptureSnapshot,
                        cfg: StampSettings,
                        logo: UIImage?,
                        mirror: Bool) -> ProcessedPhoto? {
        guard let img = UIImage(data: data) else { return nil }

        let content = StampComposer.build(snapshot, cfg: cfg, logo: logo)
        let stamped = StampRenderer.render(photo: img, content: content, cfg: cfg, mirror: mirror)

        // Encode once, with the GPS / time metadata written in the same step (no second JPEG pass).
        let comment = "GeoStamp Cam | " + (snapshot.address.full.isEmpty ? "no address" : snapshot.address.full)
        guard let jpeg = ExifWriter.encode(stamped, quality: 0.92,
                                           snapshot: cfg.embedExif ? snapshot : nil,
                                           comment: comment) else { return nil }
        return ProcessedPhoto(stamped: jpeg, original: cfg.saveOriginal ? data : nil)
    }
}
