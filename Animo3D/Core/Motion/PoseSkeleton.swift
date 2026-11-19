//
//  PoseSkeleton.swift
//  Animo3D
//
//  Connection definitions for the BlazePose 33-point skeleton (used for the overlay drawing).
//  Index reference: https://ai.google.dev/edge/mediapipe/solutions/vision/pose_landmarker
//

import Foundation

enum PoseSkeleton {
    /// Pairwise connections between the 33 landmarks.
    static let connections: [(Int, Int)] = [
        // Face
        (0, 1), (1, 2), (2, 3), (3, 7),
        (0, 4), (4, 5), (5, 6), (6, 8),
        (9, 10),
        // Torso
        (11, 12), (11, 23), (12, 24), (23, 24),
        // Left arm
        (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
        // Right arm
        (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
        // Left leg
        (23, 25), (25, 27), (27, 29), (27, 31), (29, 31),
        // Right leg
        (24, 26), (26, 28), (28, 30), (28, 32), (30, 32),
    ]
}
