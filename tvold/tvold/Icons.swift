import UIKit

// Player chrome icons, drawn as paths rather than bundled as artwork.
//
// The shapes are Phosphor's (phosphoricons.com, MIT), transcribed from their
// SVGs' native 256x256 grid — the coordinates below are lifted straight from
// them, which is why they are round numbers in 256 space and not in points.
// Nothing of Phosphor's is copied into the build: no repository is cloned, no
// asset ships, and there is no third-party code in the app.
//
// Drawing beats bundling here for three reasons specific to this app: the iOS 6
// runtime does not read the Assets.car that Xcode 13 writes (hence the loose
// Icon-*.png dance in build.sh), loose PNGs would need an @1x and an @2x each
// and would still be wrong on a future screen, and a path is sharp at any size
// while an image is not.
// Every icon here is *stroked*. A filled path (added for a favourite star, and
// reverted) crashes on device at first use — see the note on `draw` below.
enum Icon {
    case skipBack
    case skipForward
    case close
    case retry
    case airplay
}

enum Icons {

    private static var cache: [String: UIImage] = [:]

    // White is baked in rather than tinted at draw time: `withRenderingMode`
    // and template images are iOS 7, so a UIImageView here cannot recolour
    // anything it is given. Everything these icons sit on is dark, so one
    // colour is all that is needed — and a colour parameter was tried and
    // removed along with the filled star that motivated it.
    static func image(_ icon: Icon, size: CGFloat) -> UIImage? {
        let key = "\(icon)-\(size)"
        if let cached = cache[key] { return cached }
        guard let img = draw(icon, size: size) else { return nil }
        cache[key] = img
        return img
    }

    // Strokes only. `UIBezierPath.fill()` was used once, for a filled star, and
    // killed the process the first time it ran on device — the four stroked
    // icons below had already drawn in the same context moments earlier, so the
    // context, the path building and the cache are all fine and filling is the
    // one thing that is not. Cause never pinned down further; it was a
    // cosmetic detail and not worth more device cycles. If a filled shape is
    // ever wanted here, treat it as unproven and bisect it on device first.
    private static func draw(_ icon: Icon, size: CGFloat) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 0)
        defer { UIGraphicsEndImageContext() }

        // Phosphor draws on a 256-unit grid. Working in those units and scaling
        // at the end keeps the transcription checkable against the original.
        let s = size / 256
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            return CGPoint(x: x * s, y: y * s)
        }

        let path = UIBezierPath()
        // Between Phosphor's Regular (16) and Bold (24): these sit over moving
        // video, where a hairline disappears.
        path.lineWidth = 20 * s
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch icon {
        case .skipBack:
            path.move(to: p(56, 40))
            path.addLine(to: p(56, 216))
            path.move(to: p(96, 128))
            path.addLine(to: p(208, 48))
            path.addLine(to: p(208, 208))
            path.close()

        case .skipForward:
            // The same shape mirrored about x = 128.
            path.move(to: p(200, 40))
            path.addLine(to: p(200, 216))
            path.move(to: p(160, 128))
            path.addLine(to: p(48, 48))
            path.addLine(to: p(48, 208))
            path.close()

        case .close:
            path.move(to: p(200, 56))
            path.addLine(to: p(56, 200))
            path.move(to: p(200, 200))
            path.addLine(to: p(56, 56))

        case .retry:
            // Three quarters of a circle starting at 4 o'clock and running
            // clockwise, then a tail out to the arrowhead's corner at 1
            // o'clock. M_PI rather than CGFloat.pi: a C constant cannot be a
            // late-binding surprise against the 5.1.5 runtime.
            let quarter = CGFloat(M_PI) / 4
            path.addArc(withCenter: p(128, 128), radius: 88 * s,
                        startAngle: quarter, endAngle: 7 * quarter, clockwise: true)
            path.addLine(to: p(224.2, 99.7))
            path.move(to: p(176.2, 99.7))
            path.addLine(to: p(224.2, 99.7))
            path.addLine(to: p(224.2, 51.7))

        case .airplay:
            // Screen outline left open along the bottom, with the triangle
            // sitting in the gap. Stroked like everything else here, so the
            // triangle reads as an outline rather than Apple's solid one.
            path.move(to: p(96, 168))
            path.addLine(to: p(48, 168))
            path.addLine(to: p(48, 56))
            path.addLine(to: p(208, 56))
            path.addLine(to: p(208, 168))
            path.addLine(to: p(160, 168))
            path.move(to: p(128, 152))
            path.addLine(to: p(80, 216))
            path.addLine(to: p(176, 216))
            path.close()
        }

        UIColor.white.setStroke()
        path.stroke()
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
