//
//  StageDerivation.swift
//  Animo3D
//
//  Reading a stage out of its own sky.
//
//  The two stages that ship in the app were tuned by hand and measured on device: where the sun
//  stands, how warm the key light is, what colour the fog takes, how far the camera's white point
//  has to go to hold the highlights. That is a day's work per stage, and it does not scale to a
//  list of skies the server can add to at any time - nobody is going to hand-tune a scene that
//  arrives after the build shipped.
//
//  So a downloaded stage is one image, and everything else is measured off it. Two things make that
//  work rather than merely plausible:
//
//  - The sky becomes the lighting environment. Whatever colour that sky is, it is the colour
//    falling on the dancer, with no number in the middle for anyone to get wrong.
//  - The sun is found rather than assumed - but only when there is one. A noon sky has no disc in
//    it, and its brightest pixel is just the brightest part of a big bright area; pointing the
//    key light at that is how you get a scene lit from behind at five degrees for no reason.
//    `sunIsVisible` is what separates the two cases, and it was calibrated against the two stages
//    whose right answers are already known (see the constants below).
//
//  Checked against those two: the sunset's disc measures 7.9 degrees right of the camera at 5.6
//  degrees up, in the colour (1.00, 0.71, 0.17). Hand-tuned, from an afternoon of looking at it on
//  a phone: 8 degrees right, 6.5 up, (1.00, 0.72, 0.45). The daylight dome correctly reports no sun
//  at all.
//

import SceneKit
import UIKit

/// What a sky says about the light in it.
struct SkyMeasurement {
    let horizon: UIColor        // the colour at eye level, which the fog has to match
    let meanLuma: CGFloat       // average brightness above the horizon
    let peakLuma: CGFloat       // the brightest pixel
    let p99Luma: CGFloat        // and what almost all of it stays under
    let sunU: CGFloat           // where the brightest pixel is: 0...1 around the dome
    let sunElevation: CGFloat   // and how far above the horizon, in radians
    let sunColor: UIColor       // its colour, normalised so the brightest channel is 1

    /// Is there an actual sun in this sky, or just a bright sky?
    ///
    /// A disc is small and far brighter than everything around it, so it clears the 99th percentile
    /// by a wide margin; a bright overcast noon does not. Measured: 0.29 for the sunset dome and
    /// 0.09 for the daylight one, which is a wide enough gap that the threshold between them is not
    /// a delicate choice.
    var sunIsVisible: Bool { peakLuma - p99Luma > 0.15 }
}

enum SkyReader {
    /// Where the stage camera looks, as a fraction around an equirectangular background.
    ///
    /// SceneKit lays that background out against the world axes, so this is a property of the
    /// engine and the stage rig rather than of any one image. Measured with a four-quadrant test
    /// texture: the centre of the screen sits at 0.736, and the fraction grows to the right.
    static let cameraAzimuth: CGFloat = 0.736

    /// Measure a dome. Cheap: the image is drawn once into a 128x64 buffer, which is about eight
    /// thousand pixels, and every number below comes out of that one pass.
    static func measure(_ image: UIImage) -> SkyMeasurement? {
        let w = 128, h = 64
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let cg = image.cgImage,
              let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
            let i = (y * w + x) * 4
            return (CGFloat(px[i]) / 255, CGFloat(px[i + 1]) / 255, CGFloat(px[i + 2]) / 255)
        }
        func luma(_ c: (CGFloat, CGFloat, CGFloat)) -> CGFloat {
            0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
        }

        // The sun, and the brightness the sky holds around it. Only the half above the horizon:
        // below it is the ground's business, and on these domes it is a flat fill anyway.
        var peak: CGFloat = -1, peakX = 0, peakY = 0
        var sum: CGFloat = 0
        var all: [CGFloat] = []
        all.reserveCapacity(w * h / 2)
        for y in 0..<(h / 2) {
            for x in 0..<w {
                let l = luma(rgb(x, y))
                sum += l
                all.append(l)
                if l > peak { peak = l; peakX = x; peakY = y }
            }
        }
        all.sort()
        let p99 = all[min(all.count - 1, Int(Double(all.count) * 0.99))]

        // The horizon: the few rows just above eye level, which is what the ground has to fade into.
        var hr: CGFloat = 0, hg: CGFloat = 0, hb: CGFloat = 0
        var n: CGFloat = 0
        for y in Int(Double(h) * 0.46)..<(h / 2) {
            for x in 0..<w {
                let c = rgb(x, y)
                hr += c.0; hg += c.1; hb += c.2; n += 1
            }
        }
        n = max(n, 1)

        // The sun's own colour, off a small patch rather than one pixel, and normalised: what is
        // wanted from it is the hue of the light, not how bright that one pixel happened to be.
        var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sn: CGFloat = 0
        for y in max(0, peakY - 1)...min(h - 1, peakY + 1) {
            for x in max(0, peakX - 1)...min(w - 1, peakX + 1) {
                let c = rgb(x, y)
                sr += c.0; sg += c.1; sb += c.2; sn += 1
            }
        }
        sn = max(sn, 1)
        let scale = max(max(sr, sg), sb) / sn
        let sunColor = scale > 0.01
            ? UIColor(red: sr / sn / scale, green: sg / sn / scale, blue: sb / sn / scale, alpha: 1)
            : UIColor.white

        return SkyMeasurement(
            horizon: UIColor(red: hr / n, green: hg / n, blue: hb / n, alpha: 1),
            meanLuma: sum / CGFloat(w * h / 2),
            peakLuma: peak,
            p99Luma: p99,
            sunU: (CGFloat(peakX) + 0.5) / CGFloat(w),
            sunElevation: (0.5 - (CGFloat(peakY) + 0.5) / CGFloat(h)) * .pi,
            sunColor: sunColor)
    }
}

extension CharacterSceneController.StageSpec {

    /// A stage built from nothing but its sky.
    ///
    /// Used for every stage that did not ship in the app: the ones the catalogue serves, and the
    /// one a user makes out of their own photograph. The bundled two do not go through here - their
    /// numbers were measured on a phone and are better than anything this can infer - but they are
    /// what it was checked against.
    static func derived(id: String, name: String, icon: String = "photo.fill",
                        sky: @escaping () -> UIImage?,
                        backdrop: (() -> UIImage?)? = nil,
                        measured: SkyMeasurement) -> Self {
        let m = measured

        // Where the sun is, when there is one.
        //
        // The geometry: the camera looks along -Z at `cameraAzimuth`, and the fraction grows to the
        // right, which is +X. For a sun `a` radians to the right at elevation `e`, the light has to
        // travel the other way - so the node's pitch is -e and its yaw is pi - a. Worked through
        // once here rather than guessed per stage, and it lands within a few degrees of the sunset
        // angles that were arrived at by eye.
        //
        // With no disc to find, the fallback is a high sun over the viewer's shoulder: the same
        // shape of light the daylight stage uses, which is the safe answer for an even sky.
        let sunEuler: SIMD3<Float>
        if m.sunIsVisible {
            let a = (m.sunU - SkyReader.cameraAzimuth) * 2 * .pi
            sunEuler = SIMD3(Float(-m.sunElevation), Float(.pi - a), 0)
        } else {
            sunEuler = SIMD3(-Float.pi / 3, Float.pi / 10, 0)
        }

        // The light's colour is the sun's, and only when there is a sun: the brightest patch of an
        // even sky is a patch of sky, and keying a dancer in sky-blue makes them look dead.
        let key = m.sunIsVisible ? m.sunColor : UIColor(red: 1.0, green: 0.95, blue: 0.88, alpha: 1)

        // Image-based light scales with the sky, so a night scene is not lit like a noon one. The
        // four rig lights do not: they are what keeps the dancer readable, and a dark stage is
        // exactly where dimming them would lose the performer. 0.485 is the daylight dome's own
        // mean, so that stage would come out at its shipped value.
        let ibl = min(0.40, max(0.05, 0.25 * m.meanLuma / 0.485))

        // Tone mapping follows the highlights: a visible disc needs the white point pushed past 1
        // to keep the sky around it from clipping to a white hole. Both numbers reduce to the
        // hand-tuned ones on the two stages that have them (1.09 against 1.05, 0.09 against 0.09).
        let headroom = max(0, m.peakLuma - m.p99Luma)
        let grade = CharacterSceneController.CameraGrade(
            exposureOffset: 0, whitePoint: min(1.4, 1.0 + 0.3 * headroom),
            contrast: 0.08, vignetting: 0.22,
            bloom: m.sunIsVisible ? 0.09 : 0.05, bloomThreshold: 1.1)

        // The ground takes its colour from the horizon, pulled well back towards white. The paving
        // is the same stone on every stage; what changes is the light on it, and a tint mixed at
        // full strength reads as coloured stone rather than as stone at that hour.
        var hr: CGFloat = 0, hg: CGFloat = 0, hb: CGFloat = 0, ha: CGFloat = 0
        m.horizon.getRed(&hr, green: &hg, blue: &hb, alpha: &ha)
        return .init(
            id: id, name: name, icon: icon,
            sky: { sky() ?? CharacterSceneView.skyBackdrop() },
            environment: sky,
            horizon: m.horizon,
            fogNear: 3.0, fogFar: 20.0,
            backdrop: backdrop,
            // No ground. What was uploaded is what gets shown - a photograph of somewhere is
            // already a place, and paving it over with the app's own plaza puts the dancer in two
            // places at once.
            ground: nil,
            // No ring: it is drawn in the daylight dome's own haze colours, and against any other
            // sky it reads as a cut-out. A downloaded sky brings its own horizon.
            skyline: nil,
            sunEuler: sunEuler,
            light: CharacterSceneController.LightLevels(key: 420, fill: 130, rim: 340, sun: 170, ibl: ibl,
                               shadowAlpha: 0.38, rimShader: 0.06,
                               keyColor: key, rimColor: key),
            grade: grade)
    }
}
