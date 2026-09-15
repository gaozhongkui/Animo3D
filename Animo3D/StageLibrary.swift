//
//  StageLibrary.swift
//  Animo3D
//
//  Every stage the picker can offer, from three places, behind one id.
//
//  - The two that ship in the app. Hand-tuned, always available, pinned to the top of the list.
//  - The ones the catalogue serves. One image each; everything else is measured (StageDerivation).
//  - The ones the user makes out of their own photographs, which are measured the same way once
//    the photograph has been turned into something a dome can be.
//
//  That last step is the only part that is not shared. A photograph is not a panorama: it covers a
//  few tens of degrees, not a full turn, and it has no horizon line anyone told us about. Wrapping
//  one straight around the sky stretches it into a smear. So it is laid across one sector at its
//  own proportions and the rest of the turn is continued from the colours at its edges - the same
//  shape of answer as `tools/make_sky.py --span`, which is where this was worked out against real
//  photographs, minus the seam feathering that only matters when there is cloud structure to line
//  up.
//

import Combine
import ImageIO
import SwiftUI
import UIKit

/// A stage the user made from a picture of their own.
struct UserStage: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    /// File name inside the caches directory, not a path: the container moves between launches.
    let file: String
}

@MainActor
final class StageLibrary: ObservableObject {
    static let shared = StageLibrary()

    @Published private(set) var userStages: [UserStage] = []

    private var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stages", isDirectory: true)
    }
    private var indexURL: URL { cacheDir.appendingPathComponent("_user_stages.json") }

    /// Specs are kept once built: measuring is cheap but decoding a 2048x1024 JPEG is not, and the
    /// picker asks for the same handful of stages every time it opens.
    private var specs: [String: CharacterSceneController.StageSpec] = [:]

    private init() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let list = try? JSONDecoder().decode([UserStage].self, from: data) {
            // A file the user deleted from under us, or a cache the system reclaimed, is not a
            // stage any more. Dropping it here keeps a dead card out of the picker.
            userStages = list.filter { FileManager.default.fileExists(atPath: fileURL($0).path) }
            if userStages.count != list.count { save() }
        }
    }

    private func fileURL(_ stage: UserStage) -> URL { cacheDir.appendingPathComponent(stage.file) }

    // MARK: - Resolving

    /// The stage this id names, whatever kind it is.
    ///
    /// Built-ins win: the catalogue is a remote document, and a stage called "plaza" arriving in it
    /// should not be able to replace the one the app falls back to when there is no network.
    /// Nothing here happens on the main thread except the lookups.
    ///
    /// Building a stage means decoding a 2048x1024 JPEG, and for a photograph laying out a dome of
    /// the same size and measuring it. Done where this class lives - the main actor - that is a few
    /// hundred milliseconds of frozen interface, which is exactly what it looked like: the picker
    /// hung open for a beat after the tap before it would close. So the pieces are gathered here
    /// and the work is handed to a detached task.
    func spec(for id: String) async -> CharacterSceneController.StageSpec {
        if let built = CharacterSceneController.Stage.all.first(where: { $0.id == id }) { return built }
        if let cached = specs[id] { return cached }

        var source: (url: URL, name: String, icon: String, override: StageOverride?)?
        if let mine = userStages.first(where: { $0.id == id }) {
            source = (fileURL(mine), mine.name, "photo.fill", nil)
        } else if let item = RemoteAssets.shared.stage(id),
                  let url = try? await RemoteAssets.shared.ensureDownloaded(item.sky) {
            source = (url, item.name, "mountain.2.fill", item.override)
        }
        guard let source else { return CharacterSceneController.Stage.plaza }

        guard var spec = await Self.build(id: id, name: source.name, icon: source.icon,
                                          url: source.url)
        else { return CharacterSceneController.Stage.plaza }
        if let over = source.override { spec = spec.applying(over) }
        specs[id] = spec
        return spec
    }

    /// The expensive half: decode, lay out, measure. Off the main actor.
    private nonisolated static func build(id: String, name: String, icon: String,
                                          url: URL) async -> CharacterSceneController.StageSpec? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            let aspect = image.size.width / max(image.size.height, 1)
            let isPanorama = abs(aspect - 2) < 0.08
            let sky = isPanorama ? image : (StageImage.dome(from: image) ?? image)
            guard let measured = SkyReader.measure(sky) else { return nil }
            return CharacterSceneController.StageSpec.derived(
                id: id, name: name, icon: icon,
                sky: { sky },
                backdrop: isPanorama ? nil : { image },
                measured: measured)
        }.value
    }

    // MARK: - Cards

    /// Card art, once it is ready. Reading it never blocks and never decodes.
    @Published private(set) var thumbs: [String: UIImage] = [:]

    /// Produce the card art for a stage, off the main thread, once.
    ///
    /// This used to decode a full 2048x1024 JPEG per card, on the main actor, while the grid was
    /// laying itself out - which is tens of milliseconds each and which the catalogue is free to
    /// make worse by serving more stages. ImageIO decodes straight to the size a card needs instead,
    /// and it happens on a background task; the grid redraws as each one lands.
    func loadThumbnail(for id: String) async {
        guard thumbs[id] == nil else { return }

        // Where the picture is, resolved here because it needs this actor's state, and read there.
        let source: @Sendable () -> UIImage?
        if let built = CharacterSceneController.Stage.all.first(where: { $0.id == id }) {
            let sky = built.sky
            source = { Self.card(from: sky()) }
        } else if let mine = userStages.first(where: { $0.id == id }) {
            let url = fileURL(mine)
            source = { Self.card(fromFileAt: url) }
        } else if let item = RemoteAssets.shared.stage(id),
                  let url = RemoteAssets.shared.localURL(for: item.sky.assetName) {
            source = { Self.card(fromFileAt: url) }
        } else {
            return
        }

        if let art = await Task.detached(priority: .utility, operation: source).value {
            thumbs[id] = art
        }
    }

    /// Decode no larger than a card needs. 1400 across leaves the slice of a panorama about 280
    /// wide, which is what a card is on a phone, and it never decodes a user's 12-megapixel
    /// photograph in full to show it two centimetres across.
    private nonisolated static func card(fromFileAt url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour the camera's orientation
            kCGImageSourceThumbnailMaxPixelSize: 1400,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return card(from: UIImage(cgImage: cg))
    }

    /// What to show of a picture depends on what kind of picture it is.
    ///
    /// A panorama is 360 degrees of sky, and nearly all of it is somewhere the camera will never
    /// point; the card shows the slice it will, so what the user picked is what they get. A
    /// photograph is already framed - by the person who took it - and the whole of it is what will
    /// stand behind the dancer, so the card shows the whole of it.
    private nonisolated static func card(from image: UIImage?) -> UIImage? {
        guard let cg = image?.cgImage else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard abs(w / max(h, 1) - 2) < 0.08 else { return image }

        let width = w / 5
        let x = (SkyReader.cameraAzimuth * w - width / 2).truncatingRemainder(dividingBy: w)
        let rect = CGRect(x: max(0, min(w - width, x)), y: h * 0.22, width: width, height: h * 0.3)
        return cg.cropping(to: rect).map(UIImage.init(cgImage:))
    }

    // MARK: - Importing a photograph

    enum ImportError: LocalizedError {
        case unreadable, tooSmall, writeFailed

        var errorDescription: String? {
            switch self {
            case .unreadable:  return "This picture could not be opened."
            case .tooSmall:    return "This picture is too small to stand in for a sky."
            case .writeFailed: return "This picture could not be saved to the app."
            }
        }
    }

    /// What is kept is the picture itself, not the sky built from it.
    ///
    /// The sky is derived, and how it is derived has already changed twice; the photograph is the
    /// thing the user chose, and it is what the backdrop shows. Bounded at 2048 on the long edge,
    /// which is more than the screen can show and about as much as an older phone wants to hold in
    /// a texture.
    @discardableResult
    func importPhoto(_ photo: UIImage, name: String) throws -> UserStage {
        guard photo.cgImage != nil else { throw ImportError.unreadable }
        guard photo.size.width >= 480, photo.size.height >= 320 else { throw ImportError.tooSmall }
        guard let data = StageImage.bounded(photo, longEdge: 2048).jpegData(compressionQuality: 0.9)
        else { throw ImportError.writeFailed }

        let id = "user_\(Int(Date().timeIntervalSince1970))"
        let stage = UserStage(id: id, name: unique(name), file: "\(id).jpg")
        do { try data.write(to: fileURL(stage), options: .atomic) }
        catch { throw ImportError.writeFailed }

        userStages.insert(stage, at: 0)
        save()
        return stage
    }

    /// Give an imported scene a name of the user's own.
    ///
    /// The picture is not touched, only what it is called: the file name is the stage's id, which
    /// nothing outside this file ever sees, so a rename cannot break a reference.
    func rename(_ stage: UserStage, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = userStages.firstIndex(where: { $0.id == stage.id }) else { return }
        userStages[i] = UserStage(id: stage.id, name: trimmed, file: stage.file)
        specs[stage.id] = nil       // the spec carries the name it was built with
        save()
    }

    func delete(_ stage: UserStage) {
        try? FileManager.default.removeItem(at: fileURL(stage))
        userStages.removeAll { $0.id == stage.id }
        specs[stage.id] = nil
        thumbs[stage.id] = nil
        save()
    }

    /// "My Scene", then "My Scene 2". A list of cards all called the same thing is a list the
    /// user cannot choose from, and they should not have to rename one before it is usable.
    private func unique(_ name: String) -> String {
        guard userStages.contains(where: { $0.name == name }) else { return name }
        var n = 2
        while userStages.contains(where: { $0.name == "\(name) \(n)" }) { n += 1 }
        return "\(name) \(n)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(userStages) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}

// MARK: - Overrides

extension CharacterSceneController.StageSpec {
    /// The catalogue's corrections applied over what was measured. Absent fields stay measured.
    func applying(_ o: StageOverride) -> Self {
        var light = self.light
        var grade = self.grade
        if let ibl = o.ibl { light = light.with(ibl: CGFloat(ibl)) }
        if let key = o.key.flatMap(UIColor.init(hex:)) { light = light.with(keyColor: key) }
        if let wp = o.whitePoint { grade = grade.with(whitePoint: CGFloat(wp)) }
        if let bloom = o.bloom { grade = grade.with(bloom: CGFloat(bloom)) }

        var sun = self.sunEuler
        if let az = o.sunAzimuth {
            sun.y = Float(.pi - (Double(az) * .pi / 180))
        }
        if let el = o.sunElevation {
            sun.x = Float(-(Double(el) * .pi / 180))
        }

        return .init(id: id, name: name, icon: icon, sky: sky, environment: environment,
                     horizon: o.horizon.flatMap(UIColor.init(hex:)) ?? horizon,
                     fogNear: o.fogNear.map(Float.init) ?? fogNear,
                     fogFar: o.fogFar.map(Float.init) ?? fogFar,
                     backdrop: backdrop, ground: ground, skyline: skyline,
                     sunEuler: sun, light: light, grade: grade)
    }
}

extension CharacterSceneController.LightLevels {
    func with(ibl: CGFloat? = nil, keyColor: UIColor? = nil) -> Self {
        .init(key: key, fill: fill, rim: rim, sun: sun, ibl: ibl ?? self.ibl,
              shadowAlpha: shadowAlpha, rimShader: rimShader,
              keyColor: keyColor ?? self.keyColor, rimColor: keyColor ?? rimColor)
    }
}

extension CharacterSceneController.CameraGrade {
    func with(whitePoint: CGFloat? = nil, bloom: CGFloat? = nil) -> Self {
        .init(exposureOffset: exposureOffset, whitePoint: whitePoint ?? self.whitePoint,
              contrast: contrast, vignetting: vignetting, bloom: bloom ?? self.bloom,
              bloomThreshold: bloomThreshold)
    }
}

extension UIColor {
    /// "#RRGGBB" or "RRGGBB", which is how a colour is written in the catalogue.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - A photograph, made into a sky

enum StageImage {
    /// A picture, placed where the stage camera is looking.
    ///
    /// Two kinds of picture arrive here. One is already a sky: a 2:1 panorama, which is what
    /// `tools/make_sky.py` produces and what the catalogue serves, and the only right thing to do
    /// with it is nothing at all. The other is a photograph somebody took, which covers a few tens
    /// of degrees and has no horizon anyone declared. Wrapped around the sky it becomes a smear, so
    /// instead it is laid across the part of the dome the camera can see, at its own proportions,
    /// large enough to still cover the frame while the shot swings through its arc.
    ///
    /// The framing numbers are the stage camera's, measured: it sees about 42 degrees from top to
    /// bottom with the horizon a quarter of the way down, so the middle of the frame is some 11
    /// degrees below the horizon, and the slow orbit carries it 14 degrees either side.
    static func dome(from photo: UIImage, width: Int = 2048) -> UIImage? {
        guard let cg = photo.cgImage else { return nil }
        let aspect = CGFloat(cg.width) / CGFloat(cg.height)

        // Already a sky: hand it straight back. What was uploaded is what gets shown.
        if abs(aspect - 2) < 0.08 { return photo }

        let W = width, H = width / 2
        let degree = CGFloat(W) / 360                       // pixels per degree, both axes

        // Fill the frame, and keep filling it through the orbit: 52 degrees of height is the 42 the
        // camera sees plus a margin, and the width never goes under 56 so a tall photograph cannot
        // leave an edge in shot at the end of the swing.
        let spanPx = max(52 * aspect, 56) * degree
        let stripH = spanPx / aspect
        let centreY = CGFloat(H) / 2 + 11 * degree          // the middle of the frame, not of the sky
        let top = centreY - stripH / 2
        let x0 = SkyReader.cameraAzimuth * CGFloat(W) - spanPx / 2

        let edges = edgeColours(cg, rows: 64)
        let backdrop = edges.last ?? .gray

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: W, height: H), format: format).image { ctx in
            let c = ctx.cgContext
            c.setFillColor(backdrop.cgColor)
            c.fill(CGRect(x: 0, y: 0, width: W, height: H))

            // Behind and above: the picture's own edge colours, row by row, so whatever the camera
            // finds when it swings past the photograph is at least the right colour rather than a
            // hard edge. A sky changes far more from top to bottom than it does around.
            let space = CGColorSpaceCreateDeviceRGB()
            let rowH = stripH / CGFloat(max(edges.count, 1))
            for (i, colour) in edges.enumerated() {
                let y = top + CGFloat(i) * rowH
                guard y + rowH > 0, y < CGFloat(H) else { continue }
                c.setFillColor(colour.cgColor)
                c.fill(CGRect(x: 0, y: y, width: CGFloat(W), height: rowH + 1))
            }
            if let sky = edges.first, top > 0 {
                c.setFillColor(sky.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: CGFloat(W), height: top))
            }
            _ = space

            // And the picture, drawn three times so a sector that crosses the seam still wraps.
            //
            // Through UIImage rather than `CGContext.draw(cgImage:)`: this renderer's context is
            // flipped to UIKit's top-left origin, and a CGImage drawn straight into it comes out
            // upside down - which is exactly what the first version of this did, and it is not
            // obvious in a sky until you notice the trees are hanging from the top of the world.
            // UIImage also honours the orientation flag a phone camera writes.
            for dx in [CGFloat(0), CGFloat(-W), CGFloat(W)] {
                photo.draw(in: CGRect(x: x0 + dx, y: top, width: spanPx, height: stripH))
            }
        }
    }

    /// The picture at the shape of the screen, without cropping it.
    ///
    /// A landscape photograph on a phone held upright leaves most of the frame empty. Cropping to
    /// fill would keep a narrow vertical strip of it - not what the user chose - so instead the
    /// picture keeps its width and its topmost and bottommost rows are continued outwards to meet
    /// the edges. On a photograph of anywhere outdoors those rows are sky and ground, which is
    /// exactly what carries on past the frame of a picture in the real world.
    static func filling(_ picture: UIImage, aspect: CGFloat) -> UIImage {
        let w = picture.size.width
        let h = max(picture.size.height, 1)
        let target = max(h, w / max(aspect, 0.05))
        guard target > h + 1 else { return picture }

        let size = CGSize(width: w, height: target)
        let top = ((target - h) / 2).rounded()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            // The edge rows first, stretched to fill above and below, then the picture over them.
            if let cg = picture.cgImage {
                let edge = max(1, Int(CGFloat(cg.height) * 0.01))
                if let upper = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: edge)) {
                    UIImage(cgImage: upper).draw(in: CGRect(x: 0, y: 0, width: w, height: top + 1))
                }
                if let lower = cg.cropping(to: CGRect(x: 0, y: cg.height - edge,
                                                      width: cg.width, height: edge)) {
                    UIImage(cgImage: lower).draw(in: CGRect(x: 0, y: top + h - 1, width: w,
                                                            height: target - top - h + 1))
                }
            }
            picture.draw(in: CGRect(x: 0, y: top, width: w, height: h))
        }
    }

    /// The same picture, no larger than `longEdge` on its longer side.
    static func bounded(_ image: UIImage, longEdge: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > longEdge else { return image }
        let scale = longEdge / side
        let size = CGSize(width: (image.size.width * scale).rounded(),
                          height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// The colour down each side of the photograph, in bands from top to bottom.
    private static func edgeColours(_ cg: CGImage, rows: Int) -> [UIColor] {
        let w = 8, h = rows
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in
            // Both edges averaged: the two sides of the back arc meet, and a single side would put
            // a visible step at the seam directly behind the viewer.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
            for x in [0, w - 1] {
                let i = (y * w + x) * 4
                r += CGFloat(px[i]); g += CGFloat(px[i + 1]); b += CGFloat(px[i + 2])
            }
            return UIColor(red: r / 510, green: g / 510, blue: b / 510, alpha: 1)
        }
    }
}
