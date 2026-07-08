//
//  WalkPerimeterMissionEvaluator.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct WalkPerimeterMissionEvaluator {
    let mission = Mission(
        id: .walkRoomPerimeter,
        title: "Walk Room Perimeter",
        instruction: "Move steadily around the room edge"
    )

    func evaluate(_ telemetry: MissionTelemetry) -> MissionProgress {
        guard telemetry.isScanning else {
            return .inactive
        }

        let evidence = [
            frameEvidence(from: telemetry),
            viewpointEvidence(from: telemetry),
            movementEvidence(from: telemetry),
            motionEvidence(from: telemetry),
            confidenceEvidence(from: telemetry)
        ]

        if needsAttention(telemetry) {
            return MissionProgress(
                status: .needsAttention,
                instruction: attentionInstruction(for: telemetry),
                evidence: evidence,
                debugText: debugText(for: telemetry)
            )
        }

        if isComplete(evidence: evidence, telemetry: telemetry) {
            return MissionProgress(
                status: .complete,
                instruction: "Perimeter pass complete",
                evidence: evidence,
                debugText: debugText(for: telemetry)
            )
        }

        if isLikelyComplete(evidence: evidence, telemetry: telemetry) {
            return MissionProgress(
                status: .likelyComplete,
                instruction: "Close the loop and fill any obvious gaps",
                evidence: evidence,
                debugText: debugText(for: telemetry)
            )
        }

        return MissionProgress(
            status: .collecting,
            instruction: collectingInstruction(for: telemetry),
            evidence: evidence,
            debugText: debugText(for: telemetry)
        )
    }

    private func frameEvidence(from telemetry: MissionTelemetry) -> MissionEvidence {
        let level: MissionEvidenceLevel
        switch telemetry.savedFrameCount {
        case 0:
            level = .none
        case 1..<24:
            level = .building
        case 24..<70:
            level = .steady
        default:
            level = .strong
        }

        return MissionEvidence(
            id: "frame-evidence",
            title: "Good Frames",
            level: level,
            detail: "\(telemetry.savedFrameCount) saved"
        )
    }

    private func viewpointEvidence(from telemetry: MissionTelemetry) -> MissionEvidence {
        let saved = max(telemetry.savedFrameCount, 1)
        let newAngleRatio = Double(telemetry.savedNewAngleCount) / Double(saved)
        let level: MissionEvidenceLevel

        switch (telemetry.savedNewAngleCount, newAngleRatio) {
        case (0, _):
            level = .none
        case (1..<12, _):
            level = .building
        case (12..<35, 0.25...):
            level = .steady
        case (35..., 0.34...):
            level = .strong
        default:
            level = .building
        }

        return MissionEvidence(
            id: "viewpoint-diversity",
            title: "Unique Views",
            level: level,
            detail: "\(telemetry.savedNewAngleCount) new angles"
        )
    }

    private func movementEvidence(from telemetry: MissionTelemetry) -> MissionEvidence {
        MissionEvidence(
            id: "movement-evidence",
            title: "Movement",
            level: telemetry.translationEvidenceLevel,
            detail: telemetry.movementClassification.label
        )
    }

    private func motionEvidence(from telemetry: MissionTelemetry) -> MissionEvidence {
        let blockedFrames = telemetry.framesRejectedDueToPoorHealth + telemetry.rejectedMotionCount
        let totalJudgedFrames = max(telemetry.savedFrameCount + blockedFrames, 1)
        let blockedRatio = Double(blockedFrames) / Double(totalJudgedFrames)

        let level: MissionEvidenceLevel
        if telemetry.currentScanHealth == .lost || blockedRatio > 0.45 {
            level = .none
        } else if telemetry.currentScanHealth == .hold || blockedRatio > 0.25 {
            level = .building
        } else if telemetry.currentScanHealth == .coach || blockedRatio > 0.12 {
            level = .steady
        } else {
            level = .strong
        }

        return MissionEvidence(
            id: "motion-stability",
            title: "Motion",
            level: level,
            detail: telemetry.currentScanHealth.rawValue.capitalized
        )
    }

    private func confidenceEvidence(from telemetry: MissionTelemetry) -> MissionEvidence {
        let level: MissionEvidenceLevel
        switch telemetry.scanConfidenceScore {
        case 0:
            level = .none
        case 1..<45:
            level = .building
        case 45..<75:
            level = .steady
        default:
            level = .strong
        }

        return MissionEvidence(
            id: "scan-confidence",
            title: "Scan confidence",
            level: level,
            detail: confidenceLabel(for: telemetry.scanConfidenceScore)
        )
    }

    private func needsAttention(_ telemetry: MissionTelemetry) -> Bool {
        telemetry.movementClassification == .rotatingInPlace ||
            telemetry.currentScanHealth == .hold ||
            telemetry.currentScanHealth == .lost ||
            telemetry.lastMotionScore >= CaptureTuning.maxRotationRate
    }

    private func isLikelyComplete(evidence: [MissionEvidence], telemetry: MissionTelemetry) -> Bool {
        guard telemetry.movementClassification == .walking else { return false }

        return hasStrongEvidence(evidence, id: "frame-evidence") &&
            hasAtLeastSteadyEvidence(evidence, id: "viewpoint-diversity") &&
            hasAtLeastSteadyEvidence(evidence, id: "movement-evidence") &&
            hasAtLeastSteadyEvidence(evidence, id: "motion-stability") &&
            hasAtLeastSteadyEvidence(evidence, id: "scan-confidence") &&
            telemetry.timeInCapturing >= 18
    }

    private func isComplete(evidence: [MissionEvidence], telemetry: MissionTelemetry) -> Bool {
        guard telemetry.movementClassification == .walking else { return false }

        return hasStrongEvidence(evidence, id: "frame-evidence") &&
            hasStrongEvidence(evidence, id: "viewpoint-diversity") &&
            hasAtLeastSteadyEvidence(evidence, id: "movement-evidence") &&
            hasAtLeastSteadyEvidence(evidence, id: "motion-stability") &&
            hasAtLeastSteadyEvidence(evidence, id: "scan-confidence") &&
            telemetry.timeInCapturing >= 25
    }

    private func hasStrongEvidence(_ evidence: [MissionEvidence], id: String) -> Bool {
        evidence.first { $0.id == id }?.level == .strong
    }

    private func hasAtLeastSteadyEvidence(_ evidence: [MissionEvidence], id: String) -> Bool {
        guard let level = evidence.first(where: { $0.id == id })?.level else { return false }
        return level >= .steady
    }

    private func collectingInstruction(for telemetry: MissionTelemetry) -> String {
        if telemetry.savedFrameCount == 0 {
            return "Begin with a slow perimeter walk"
        }

        if telemetry.movementClassification == .smallAreaPacing {
            return "Keep moving along the room edge"
        }

        if telemetry.savedNewAngleCount < max(telemetry.savedFrameCount / 3, 8) {
            return "Keep moving to new viewpoints"
        }

        return mission.instruction
    }

    private func attentionInstruction(for telemetry: MissionTelemetry) -> String {
        if telemetry.movementClassification == .rotatingInPlace {
            return "Walk along the room edge. Do not just rotate in place."
        }

        switch telemetry.currentScanHealth {
        case .lost:
            return "Pause and let tracking recover"
        case .hold:
            return "Slow down and hold steady"
        case .coach:
            return "Move slower"
        case .capturing, .ready:
            return "Stabilize motion"
        }
    }

    private func confidenceLabel(for score: Int) -> String {
        switch score {
        case 75...100:
            return "Strong"
        case 45..<75:
            return "Steady"
        case 1..<45:
            return "Building"
        default:
            return "None"
        }
    }

    private func debugText(for telemetry: MissionTelemetry) -> String {
        "lin \(String(format: "%.2f", telemetry.recentLinearMotionImpulse)) " +
            "rot \(String(format: "%.2f", telemetry.recentRotationImpulse)) " +
            "dom \(String(format: "%.2f", telemetry.rotationDominance)) " +
            telemetry.movementClassification.rawValue
    }
}
