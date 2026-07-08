//
//  MissionModels.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

enum MissionID: String, CaseIterable, Identifiable {
    case walkRoomPerimeter
    case reversePerimeter
    case ceilingPass
    case heroObjectPass
    case finalConnectionPass

    var id: String { rawValue }
}

struct Mission: Identifiable, Equatable {
    let id: MissionID
    let title: String
    let instruction: String
}

enum MissionStatus: String, Equatable {
    case collecting = "Collecting"
    case likelyComplete = "Likely Complete"
    case complete = "Complete"
    case needsAttention = "Needs Attention"
}

enum MovementClassification: String, Equatable {
    case unknown
    case walking
    case rotatingInPlace
    case stopped
    case smallAreaPacing

    var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .walking:
            return "Walking"
        case .rotatingInPlace:
            return "Rotating"
        case .stopped:
            return "Stopped"
        case .smallAreaPacing:
            return "Small area"
        }
    }
}

enum MissionEvidenceLevel: Int, Comparable {
    case none
    case building
    case steady
    case strong

    static func < (lhs: MissionEvidenceLevel, rhs: MissionEvidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .none:
            return "None"
        case .building:
            return "Building"
        case .steady:
            return "Steady"
        case .strong:
            return "Strong"
        }
    }

    var barFill: Double {
        switch self {
        case .none:
            return 0.08
        case .building:
            return 0.36
        case .steady:
            return 0.68
        case .strong:
            return 1.0
        }
    }
}

struct MissionEvidence: Identifiable, Equatable {
    let id: String
    let title: String
    let level: MissionEvidenceLevel
    let detail: String
}

struct MissionTelemetry: Equatable {
    let isScanning: Bool
    let framesSeen: Int
    let savedFrameCount: Int
    let savedNewAngleCount: Int
    let savedOverlapCount: Int
    let rejectedMotionCount: Int
    let rejectedBlurryCount: Int
    let framesRejectedDueToPoorHealth: Int
    let scanConfidenceScore: Int
    let currentScanHealth: ScanHealthState
    let linearAccelerationMagnitude: Double
    let rotationRateMagnitude: Double
    let recentLinearMotionImpulse: Double
    let recentRotationImpulse: Double
    let rotationDominance: Double
    let movementClassification: MovementClassification
    let translationEvidenceLevel: MissionEvidenceLevel
    let lastMotionScore: Double
    let lastViewChangeScore: Double
    let lastRotationChangeRadians: Double
    let captureFPS: Double
    let timeInCapturing: TimeInterval
    let timeInCoach: TimeInterval
    let timeInHold: TimeInterval
    let timeInLost: TimeInterval
}

struct MissionProgress: Equatable {
    static let inactive = MissionProgress(
        status: .collecting,
        instruction: "Start scanning",
        evidence: [],
        debugText: nil
    )

    let status: MissionStatus
    let instruction: String
    let evidence: [MissionEvidence]
    var debugText: String?
}
