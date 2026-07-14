//
//  CoverageModels.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

enum CoverageSectorID: String, CaseIterable, Identifiable, Codable {
    case startWall
    case rightSide
    case oppositeWall
    case leftSide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startWall:
            return "Start wall"
        case .rightSide:
            return "Right side"
        case .oppositeWall:
            return "Opposite wall"
        case .leftSide:
            return "Left side"
        }
    }
}

enum CoverageEvidenceLevel: Int, Comparable, Equatable, Codable {
    case none
    case sparse
    case adequate
    case strong

    static func < (lhs: CoverageEvidenceLevel, rhs: CoverageEvidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var barFill: Double {
        switch self {
        case .none:
            return 0.08
        case .sparse:
            return 0.34
        case .adequate:
            return 0.68
        case .strong:
            return 1.0
        }
    }

    var title: String {
        switch self {
        case .none: "None"
        case .sparse: "Sparse"
        case .adequate: "Adequate"
        case .strong: "Strong"
        }
    }
}

enum CoverageRecommendationPriority: String, Equatable, Codable {
    case normal
    case important
    case complete
}

struct CoverageSector: Identifiable, Equatable, Codable {
    let id: CoverageSectorID
    let title: String
    let startDegrees: Double
    let endDegrees: Double
}

struct CoverageEvidence: Identifiable, Equatable, Codable {
    let sectorID: CoverageSectorID
    let title: String
    let savedFrames: Double
    let newAngleFrames: Double
    let stableFrames: Double
    let viewChangeTotal: Double
    let lastUpdatedAt: Date?
    let level: CoverageEvidenceLevel
    let rationale: String

    var id: CoverageSectorID { sectorID }
}

struct CoverageRecommendation: Equatable, Codable {
    let text: String
    let priority: CoverageRecommendationPriority
}

struct CoverageSummary: Equatable, Codable {
    static let empty = CoverageSummary(
        sectors: CoverageSectorID.allCases.map {
            CoverageEvidence(
                sectorID: $0,
                title: $0.title,
                savedFrames: 0,
                newAngleFrames: 0,
                stableFrames: 0,
                viewChangeTotal: 0,
                lastUpdatedAt: nil,
                level: .none,
                rationale: "No saved-frame evidence yet."
            )
        },
        recommendation: CoverageRecommendation(
            text: "Continue one steady perimeter pass.",
            priority: .normal
        )
    )

    let sectors: [CoverageEvidence]
    let recommendation: CoverageRecommendation
}

/// Coverage v1 deliberately maps relative device yaw into four equal 90-degree
/// sectors. It is an advisory heuristic, not a geometric room map: the user must
/// begin aimed at the intended start wall, yaw drift can accumulate, and turning
/// the phone does not prove that the user translated around the room.
enum CoverageTuning {
    static let sparseMinimumViewChange = CaptureTuning.minimumOverlapViewChangeScore
    static let adequateSavedFrames = 7
    static let adequateNewAngleFrames = 2
    static let adequateStableFrames = 4
    static let strongSavedFrames = 14
    static let strongNewAngleFrames = 5
    static let strongStableFrames = 8

    static let methodology = "relative-yaw-four-sector-v1"
    static let controlledTestProcedure = [
        "Face the intended start wall and hold for 10 seconds.",
        "Rotate 90 degrees right and hold for 10 seconds.",
        "Rotate another 90 degrees right and hold for 10 seconds.",
        "Rotate another 90 degrees right and hold for 10 seconds.",
        "Return to the start direction and hold long enough to confirm wraparound."
    ]
    static let assumptions = [
        "The phone is aimed at the intended start wall when the first usable yaw is recorded.",
        "Four equal 90-degree yaw sectors approximate room sides; they do not reconstruct room geometry.",
        "Core Motion yaw may drift during a long scan.",
        "Movement weighting reduces rotation-only evidence but cannot prove physical perimeter translation."
    ]
}

enum CoverageMotionState: Equatable {
    case walkingTranslation
    case rotatingInPlace
    case stationaryHold
    case uncertain
}

struct CoverageDiagnostics: Codable, Equatable {
    let methodology: String
    let assumptions: [String]
    let thresholds: CoverageThresholds
    let sectorBoundaries: [CoverageSector]
    let controlledTestProcedure: [String]
    let summary: CoverageSummary
    let perFrame: [CoverageFrameDiagnostic]
}

struct CoverageFrameDiagnostic: Codable, Equatable {
    let frameNumber: Int
    let timestamp: Date
    let absoluteYawRadians: Double?
    let absoluteYawDegrees: Double?
    let startYawRadians: Double?
    let startYawDegrees: Double?
    let startRelativeYawRadians: Double?
    let startRelativeYawDegrees: Double?
    let normalizedYawDegrees: Double?
    let assignedSector: CoverageSectorID?
    let assignedSectorStartDegrees: Double?
    let assignedSectorEndDegrees: Double?
    let saved: Bool
    let excluded: Bool
    let exclusionReason: String?
    let evidenceWeight: Double
    let viewChangeScore: Double?
    let newAngleDecision: Bool
    let overlapDecision: Bool
    let movementClassification: MovementClassification
    let scanHealth: String
}

struct CoverageThresholds: Codable, Equatable {
    let adequateSavedFrames: Int
    let adequateNewAngleFrames: Int
    let adequateStableFrames: Int
    let strongSavedFrames: Int
    let strongNewAngleFrames: Int
    let strongStableFrames: Int
    let sparseMinimumViewChange: Double

    static let current = CoverageThresholds(
        adequateSavedFrames: CoverageTuning.adequateSavedFrames,
        adequateNewAngleFrames: CoverageTuning.adequateNewAngleFrames,
        adequateStableFrames: CoverageTuning.adequateStableFrames,
        strongSavedFrames: CoverageTuning.strongSavedFrames,
        strongNewAngleFrames: CoverageTuning.strongNewAngleFrames,
        strongStableFrames: CoverageTuning.strongStableFrames,
        sparseMinimumViewChange: CoverageTuning.sparseMinimumViewChange
    )
}

struct CoverageTelemetry: Equatable {
    let timestamp: Date
    let isScanning: Bool
    let yawRadians: Double?
    let savedFrameCount: Int
    let savedNewAngleCount: Int
    let currentScanHealth: ScanHealthState
    let movementClassification: MovementClassification
    let recentLinearMotionImpulse: Double
    let recentRotationImpulse: Double
    let rotationDominance: Double
    let viewChangeScore: Double
}

struct CoverageSample: Equatable {
    let timestamp: Date
    let sectorID: CoverageSectorID
    let savedFrameDelta: Int
    let newAngleDelta: Int
    let isStable: Bool
    let movementClassification: MovementClassification
    let evidenceWeight: Double
    let viewChangeScore: Double
}
