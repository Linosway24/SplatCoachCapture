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
    let phase: CoverageCoachingPhase
    let targetSector: CoverageSectorID?
    let deficitSeverity: CoverageDeficitSeverity?
    let key: String
    let changeReason: String?
    let changedAt: Date?
}

enum CoverageCoachingPhase: String, Equatable, Codable {
    case startup
    case normal
    case correcting
    case completed
}

enum CoverageDeficitSeverity: String, Equatable, Codable {
    case small
    case moderate
    case large
}

struct CoverageCoachingChange: Equatable, Codable {
    let phase: CoverageCoachingPhase
    let targetSector: CoverageSectorID?
    let deficitSeverity: CoverageDeficitSeverity?
    let recommendationText: String
    let recommendationKey: String
    let reason: String
    let timestamp: Date
    let state: CoverageCoachingStateDiagnostic?
}

struct CoverageCoachingStateDiagnostic: Equatable, Codable {
    static let empty = CoverageCoachingStateDiagnostic(
        rawActiveSector: nil,
        targetSector: nil,
        debouncedInTarget: false,
        targetEntryStartedAt: nil,
        targetEntryElapsed: 0,
        targetExitStartedAt: nil,
        targetExitElapsed: 0,
        targetEvidenceDelta: 0,
        progressImproving: false,
        progressStalled: false,
        guidanceDecisionReason: "not-started"
    )

    let rawActiveSector: CoverageSectorID?
    let targetSector: CoverageSectorID?
    let debouncedInTarget: Bool
    let targetEntryStartedAt: Date?
    let targetEntryElapsed: TimeInterval
    let targetExitStartedAt: Date?
    let targetExitElapsed: TimeInterval
    let targetEvidenceDelta: Double
    let progressImproving: Bool
    let progressStalled: Bool
    let guidanceDecisionReason: String
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
            priority: .normal,
            phase: .startup,
            targetSector: nil,
            deficitSeverity: nil,
            key: "startup.perimeter-pass",
            changeReason: nil,
            changedAt: nil
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

    // Coaching does not leave startup until time, capture volume, and
    // directional diversity all support a meaningful weakest-sector choice.
    static let coachingStartupMinimumDuration: TimeInterval = 8
    static let coachingStartupMinimumSavedFrames = 12
    static let coachingStartupMinimumSectorsWithEvidence = 3
    static let coachingSmallDeficitMinimumProgress = 0.75
    static let coachingCompletionAcknowledgementDuration: TimeInterval = 2
    static let coachingTargetEntryDwellDuration: TimeInterval = 1
    static let coachingTargetExitDwellDuration: TimeInterval = 1.5
    static let coachingProgressWindowDuration: TimeInterval = 4
    static let coachingMeaningfulProgressDelta = 0.05
    static let coachingProgressAcknowledgementDuration: TimeInterval = 2
    static let coachingProgressStallDuration: TimeInterval = 4

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
    let coachingThresholds: CoverageCoachingThresholds
    let summary: CoverageSummary
    let coachingState: CoverageCoachingStateDiagnostic
    let coachingChanges: [CoverageCoachingChange]
    let perFrame: [CoverageFrameDiagnostic]
}

struct CoverageCoachingThresholds: Codable, Equatable {
    let startupMinimumDuration: TimeInterval
    let startupMinimumSavedFrames: Int
    let startupMinimumSectorsWithEvidence: Int
    let smallDeficitMinimumProgress: Double
    let completionAcknowledgementDuration: TimeInterval
    let targetEntryDwellDuration: TimeInterval
    let targetExitDwellDuration: TimeInterval
    let progressWindowDuration: TimeInterval
    let meaningfulProgressDelta: Double
    let progressAcknowledgementDuration: TimeInterval
    let progressStallDuration: TimeInterval

    static let current = CoverageCoachingThresholds(
        startupMinimumDuration: CoverageTuning.coachingStartupMinimumDuration,
        startupMinimumSavedFrames: CoverageTuning.coachingStartupMinimumSavedFrames,
        startupMinimumSectorsWithEvidence: CoverageTuning.coachingStartupMinimumSectorsWithEvidence,
        smallDeficitMinimumProgress: CoverageTuning.coachingSmallDeficitMinimumProgress,
        completionAcknowledgementDuration: CoverageTuning.coachingCompletionAcknowledgementDuration,
        targetEntryDwellDuration: CoverageTuning.coachingTargetEntryDwellDuration,
        targetExitDwellDuration: CoverageTuning.coachingTargetExitDwellDuration,
        progressWindowDuration: CoverageTuning.coachingProgressWindowDuration,
        meaningfulProgressDelta: CoverageTuning.coachingMeaningfulProgressDelta,
        progressAcknowledgementDuration: CoverageTuning.coachingProgressAcknowledgementDuration,
        progressStallDuration: CoverageTuning.coachingProgressStallDuration
    )
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
