//
//  SceneCameraController.swift
//  Animo3D
//
//  Camera positioning, orbit controls, drag gestures, and camera follow logic for 3D stage rendering.
//

import SceneKit
import simd
import UIKit

final class SceneCameraController {

    var isAutoOrbiting = true
    private var orbitClock: Float = 0
    private var orbitBaseAzimuth: Float?
    private var orbitBaseRadius: Float = 0
    private var orbitLook: simd_float3?
    private var orbitRadius: Float = 0
    var viewportAspect: Float = 0.46

    private let orbitSwing: Float = 0.25

    weak var hostView: SCNView?
    weak var cameraPan: UIPanGestureRecognizer?

    private var userAzimuth: Float = 0
    private var userPitch: Float = 0
    private static let azimuthLimit: Float = 0.70
    private static let pitchLimit: ClosedRange<Float> = -0.10 ... 0.30

    struct CameraFollow {
        let aspect: Float, margin: Float, fieldOfView: CGFloat
        var center: simd_float3
        var distance: Float
    }
    private var follow: CameraFollow?

    func dragCamera(byX dx: Float, y dy: Float) {
        let k: Float = 0.0045
        userAzimuth = min(max(userAzimuth - dx * k, -Self.azimuthLimit), Self.azimuthLimit)
        userPitch = min(max(userPitch + dy * k, Self.pitchLimit.lowerBound), Self.pitchLimit.upperBound)
    }

    func resetCameraDrag() { userAzimuth = 0; userPitch = 0 }

    func syncCameraControl(cameraNode: SCNNode?, stageBackdrop: Any?) {
        guard let view = hostView else { return }
        let flat = stageBackdrop != nil
        view.allowsCameraControl = !flat
        cameraPan?.isEnabled = flat
        guard flat, let cam = cameraNode else { return }
        if view.pointOfView !== cam {
            view.pointOfView = cam
            resetCameraDrag()
        }
    }

    func startAutoOrbit() { isAutoOrbiting = true }
    func stopAutoOrbit() { isAutoOrbiting = false }
    func resetCameraMove() { orbitBaseAzimuth = nil; orbitClock = 0 }

    func stepCameraMove(cameraNode: SCNNode?, modelHeight: Float, stageCenter: simd_float3, feetY: Float, posedBounds: () -> (min: simd_float3, max: simd_float3)?, distanceForHalfExtent: (simd_float3, Float, Float, CGFloat) -> Float) {
        guard isAutoOrbiting, let cam = cameraNode, modelHeight > 0 else { return }

        let dx = cam.simdPosition.x - stageCenter.x
        let dz = cam.simdPosition.z - stageCenter.z
        if orbitBaseAzimuth == nil {
            let r = sqrt(dx * dx + dz * dz)
            guard r > 1e-4 else { return }
            orbitBaseAzimuth = atan2(dx, dz)
            orbitBaseRadius = r
            orbitRadius = r
        }
        guard let base = orbitBaseAzimuth else { return }

        orbitClock += 1.0 / 30.0
        let azimuth = base + userAzimuth + sin(orbitClock * 0.20) * orbitSwing

        let standing = simd_float3(stageCenter.x, feetY + modelHeight * 0.48, stageCenter.z)
        var targetLook = standing
        var targetRadius = orbitBaseRadius
        if let b = posedBounds() {
            let c = (b.min + b.max) * 0.5
            targetLook = simd_float3(c.x, standing.y + (c.y - standing.y) * 0.45, c.z)
            targetRadius = max(orbitBaseRadius,
                               distanceForHalfExtent((b.max - b.min) * 0.5, viewportAspect, 1.25, 55))
        }

        var look = orbitLook ?? targetLook
        look += (targetLook - look) * 0.10
        orbitLook = look
        orbitRadius += (targetRadius - orbitRadius) * (targetRadius > orbitRadius ? 0.20 : 0.03)

        let radius = orbitRadius * (1 + sin(orbitClock * 0.13) * 0.05)

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        cam.simdPosition.x = look.x + sin(azimuth) * radius
        cam.simdPosition.z = look.z + cos(azimuth) * radius
        cam.simdPosition.y = look.y + modelHeight * (0.57 + userPitch)
        cam.look(at: SCNVector3(look))

        if DeviceTier.allowsCinematicEffects, let camera = cam.camera {
            let focusDist = simd_distance(cam.simdPosition, look)
            camera.focusDistance = CGFloat(focusDist)
        }
        SCNTransaction.commit()
    }

    func beginCameraFollow(aspect: Float, margin: Float = 1.12, fieldOfView: CGFloat = 42, posedBounds: () -> (min: simd_float3, max: simd_float3)?, distanceForHalfExtent: (simd_float3, Float, Float, CGFloat) -> Float, placeCamera: (simd_float3, Float, CGFloat) -> Void) {
        guard let b = posedBounds() else { return }
        let half = (b.max - b.min) * 0.5
        follow = CameraFollow(aspect: aspect, margin: margin, fieldOfView: fieldOfView,
                              center: (b.min + b.max) * 0.5,
                              distance: distanceForHalfExtent(half, aspect, margin, fieldOfView))
        stepCameraFollow(posedBounds: posedBounds, distanceForHalfExtent: distanceForHalfExtent, placeCamera: placeCamera)
    }

    func endCameraFollow() { follow = nil }

    func stepCameraFollow(posedBounds: () -> (min: simd_float3, max: simd_float3)?, distanceForHalfExtent: (simd_float3, Float, Float, CGFloat) -> Float, placeCamera: (simd_float3, Float, CGFloat) -> Void) {
        guard var f = follow, let b = posedBounds() else { return }
        let half = (b.max - b.min) * 0.5
        let targetCenter = (b.min + b.max) * 0.5
        let targetDistance = distanceForHalfExtent(half, f.aspect, f.margin, f.fieldOfView)

        f.center += (targetCenter - f.center) * 0.12
        f.distance += (targetDistance - f.distance) * (targetDistance > f.distance ? 0.25 : 0.04)
        follow = f
        placeCamera(f.center, f.distance, f.fieldOfView)
    }
}
