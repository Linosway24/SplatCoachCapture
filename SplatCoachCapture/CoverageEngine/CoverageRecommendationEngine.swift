//
//  CoverageRecommendationEngine.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct CoverageCoachingContext: Equatable {
    let timestamp: Date
    let scanStartedAt: Date
    let savedFrameCount: Int
    let currentSector: CoverageSectorID?
}

final class CoverageRecommendationEngine {
    private struct ProgressSample {
        let timestamp: Date
        let value: Double
    }

    private(set) var changeHistory: [CoverageCoachingChange] = []
    private(set) var diagnosticState: CoverageCoachingStateDiagnostic = .empty

    private var hasExitedStartup = false
    private var currentTarget: CoverageSectorID?
    private var completedTarget: CoverageSectorID?
    private var completionStartedAt: Date?
    private var currentRecommendation: CoverageRecommendation?

    private var rawActiveSector: CoverageSectorID?
    private var debouncedInTarget = false
    private var hasEnteredTarget = false
    private var targetEntryStartedAt: Date?
    private var targetExitStartedAt: Date?

    private var progressSamples: [ProgressSample] = []
    private var lastObservedEvidenceScore: Double?
    private var lastEvidenceIncreaseAt: Date?
    private var progressAcknowledgementStartedAt: Date?
    private var targetEvidenceDelta = 0.0
    private var progressImproving = false
    private var progressStalled = false

    func reset() {
        changeHistory = []
        diagnosticState = .empty
        hasExitedStartup = false
        currentTarget = nil
        completedTarget = nil
        completionStartedAt = nil
        currentRecommendation = nil
        rawActiveSector = nil
        resetTargetTracking()
    }

    func recommendation(
        for sectors: [CoverageEvidence],
        movementClassification: MovementClassification,
        context: CoverageCoachingContext
    ) -> CoverageRecommendation {
        rawActiveSector = context.currentSector

        if !hasExitedStartup {
            guard startupEvidenceIsReady(sectors: sectors, context: context) else {
                return publish(
                    text: "Continue one steady perimeter pass.",
                    priority: .normal,
                    phase: .startup,
                    target: nil,
                    severity: nil,
                    key: "startup.perimeter-pass",
                    defaultReason: "scan-started",
                    diagnosticReason: "startup-grace-period",
                    at: context.timestamp
                )
            }
            hasExitedStartup = true
        }

        if let completedTarget, let completionStartedAt {
            let elapsed = context.timestamp.timeIntervalSince(completionStartedAt)
            if elapsed < CoverageTuning.coachingCompletionAcknowledgementDuration {
                return completionRecommendation(for: completedTarget, at: context.timestamp)
            }
            self.completedTarget = nil
            self.completionStartedAt = nil
            resetTargetTracking()
        }

        if let target = currentTarget,
           let evidence = sectors.first(where: { $0.sectorID == target }) {
            updateTargetPresence(target: target, context: context)
            updateProgress(for: evidence, at: context.timestamp)

            if evidence.level >= .adequate {
                currentTarget = nil
                completedTarget = target
                completionStartedAt = context.timestamp
                return completionRecommendation(for: target, at: context.timestamp)
            }

            return correctionRecommendation(for: evidence, context: context)
        }

        if movementClassification == .rotatingInPlace {
            return publish(
                text: "Continue one steady perimeter pass.",
                priority: .important,
                phase: .normal,
                target: nil,
                severity: nil,
                key: "normal.perimeter-pass",
                defaultReason: "rotation-in-place",
                diagnosticReason: "rotation-in-place",
                at: context.timestamp
            )
        }

        if sectors.allSatisfy({ $0.level >= .adequate }) {
            return publish(
                text: "Coverage appears complete.",
                priority: .complete,
                phase: .completed,
                target: nil,
                severity: nil,
                key: "completed.all-sectors",
                defaultReason: "coverage-complete",
                diagnosticReason: "coverage-complete",
                at: context.timestamp
            )
        }

        guard let weakest = weakestSector(in: sectors) else {
            return publish(
                text: "Continue one steady perimeter pass.",
                priority: .normal,
                phase: .normal,
                target: nil,
                severity: nil,
                key: "normal.perimeter-pass",
                defaultReason: "no-actionable-deficit",
                diagnosticReason: "no-actionable-deficit",
                at: context.timestamp
            )
        }

        currentTarget = weakest.sectorID
        beginTracking(target: weakest.sectorID, evidence: weakest, context: context)
        return correctionRecommendation(for: weakest, context: context)
    }

    private func startupEvidenceIsReady(
        sectors: [CoverageEvidence],
        context: CoverageCoachingContext
    ) -> Bool {
        let elapsed = context.timestamp.timeIntervalSince(context.scanStartedAt)
        let sectorsWithEvidence = sectors.filter { $0.level != .none }.count
        return elapsed >= CoverageTuning.coachingStartupMinimumDuration &&
            context.savedFrameCount >= CoverageTuning.coachingStartupMinimumSavedFrames &&
            sectorsWithEvidence >= CoverageTuning.coachingStartupMinimumSectorsWithEvidence
    }

    private func weakestSector(in sectors: [CoverageEvidence]) -> CoverageEvidence? {
        sectors
            .filter { $0.level < .adequate }
            .sorted {
                if $0.level != $1.level { return $0.level < $1.level }
                let lhsProgress = adequacyProgress(for: $0)
                let rhsProgress = adequacyProgress(for: $1)
                if lhsProgress != rhsProgress { return lhsProgress < rhsProgress }
                if $0.newAngleFrames != $1.newAngleFrames {
                    return $0.newAngleFrames < $1.newAngleFrames
                }
                return ($0.lastUpdatedAt ?? .distantPast) < ($1.lastUpdatedAt ?? .distantPast)
            }
            .first
    }

    private func beginTracking(
        target: CoverageSectorID,
        evidence: CoverageEvidence,
        context: CoverageCoachingContext
    ) {
        resetTargetTracking()
        let score = evidenceProgressScore(for: evidence)
        progressSamples = [ProgressSample(timestamp: context.timestamp, value: score)]
        lastObservedEvidenceScore = score
        lastEvidenceIncreaseAt = context.timestamp
        updateTargetPresence(target: target, context: context)
        updateDiagnostic(reason: "target-selected", at: context.timestamp)
    }

    private func resetTargetTracking() {
        debouncedInTarget = false
        hasEnteredTarget = false
        targetEntryStartedAt = nil
        targetExitStartedAt = nil
        progressSamples = []
        lastObservedEvidenceScore = nil
        lastEvidenceIncreaseAt = nil
        progressAcknowledgementStartedAt = nil
        targetEvidenceDelta = 0
        progressImproving = false
        progressStalled = false
    }

    private func updateTargetPresence(
        target: CoverageSectorID,
        context: CoverageCoachingContext
    ) {
        if context.currentSector == target {
            targetExitStartedAt = nil
            guard !debouncedInTarget else {
                targetEntryStartedAt = nil
                return
            }

            if targetEntryStartedAt == nil {
                targetEntryStartedAt = context.timestamp
            }
            if let targetEntryStartedAt,
               context.timestamp.timeIntervalSince(targetEntryStartedAt) >= CoverageTuning.coachingTargetEntryDwellDuration {
                debouncedInTarget = true
                hasEnteredTarget = true
                self.targetEntryStartedAt = nil
            }
        } else {
            targetEntryStartedAt = nil
            guard debouncedInTarget else {
                targetExitStartedAt = nil
                return
            }

            if targetExitStartedAt == nil {
                targetExitStartedAt = context.timestamp
            }
            if let targetExitStartedAt,
               context.timestamp.timeIntervalSince(targetExitStartedAt) >= CoverageTuning.coachingTargetExitDwellDuration {
                debouncedInTarget = false
                self.targetExitStartedAt = nil
            }
        }
    }

    private func updateProgress(for evidence: CoverageEvidence, at timestamp: Date) {
        let score = evidenceProgressScore(for: evidence)
        if let lastObservedEvidenceScore, score > lastObservedEvidenceScore + 0.000_001 {
            lastEvidenceIncreaseAt = timestamp
        }
        lastObservedEvidenceScore = score
        progressSamples.append(ProgressSample(timestamp: timestamp, value: score))

        let cutoff = timestamp.addingTimeInterval(-CoverageTuning.coachingProgressWindowDuration)
        let baselineIndex = progressSamples.lastIndex(where: { $0.timestamp <= cutoff }) ?? 0
        if baselineIndex > 0 {
            progressSamples.removeFirst(baselineIndex)
        }

        targetEvidenceDelta = max(score - (progressSamples.first?.value ?? score), 0)
        progressImproving = targetEvidenceDelta >= CoverageTuning.coachingMeaningfulProgressDelta
        progressStalled = timestamp.timeIntervalSince(lastEvidenceIncreaseAt ?? timestamp) >=
            CoverageTuning.coachingProgressStallDuration

        if progressStalled {
            progressAcknowledgementStartedAt = nil
        } else if progressImproving, progressAcknowledgementStartedAt == nil {
            progressAcknowledgementStartedAt = timestamp
        }
    }

    private func correctionRecommendation(
        for evidence: CoverageEvidence,
        context: CoverageCoachingContext
    ) -> CoverageRecommendation {
        let severity = deficitSeverity(for: evidence)
        let location = evidence.sectorID.coachingLocation

        if debouncedInTarget {
            if progressStalled {
                return directionalRecommendation(
                    for: evidence,
                    severity: severity,
                    reason: "target-evidence-stalled",
                    at: context.timestamp
                )
            }

            if let progressAcknowledgementStartedAt {
                let acknowledgementElapsed = context.timestamp.timeIntervalSince(progressAcknowledgementStartedAt)
                if acknowledgementElapsed < CoverageTuning.coachingProgressAcknowledgementDuration {
                    return publish(
                        text: "Good—\(evidence.sectorID.coachingProgressSubject) coverage is improving.",
                        priority: .important,
                        phase: .correcting,
                        target: evidence.sectorID,
                        severity: severity,
                        key: "correcting.\(evidence.sectorID.rawValue).improving",
                        defaultReason: "target-evidence-improving",
                        diagnosticReason: "directional-guidance-suppressed-progress-improving",
                        at: context.timestamp
                    )
                }

                return publish(
                    text: "Keep moving to new viewpoints.",
                    priority: .normal,
                    phase: .correcting,
                    target: evidence.sectorID,
                    severity: severity,
                    key: "correcting.\(evidence.sectorID.rawValue).quiet",
                    defaultReason: "target-progress-acknowledged",
                    diagnosticReason: "directional-guidance-suppressed-recent-progress",
                    at: context.timestamp
                )
            }

            return publish(
                text: "Good—keep covering \(location).",
                priority: .important,
                phase: .correcting,
                target: evidence.sectorID,
                severity: severity,
                key: "correcting.\(evidence.sectorID.rawValue).active",
                defaultReason: "target-entry-debounced",
                diagnosticReason: "target-entry-debounced-awaiting-progress",
                at: context.timestamp
            )
        }

        let reason: String
        if hasEnteredTarget {
            reason = "target-exit-debounced"
        } else if targetEntryStartedAt != nil {
            reason = "target-entry-pending"
        } else {
            reason = "target-not-entered"
        }
        return directionalRecommendation(
            for: evidence,
            severity: severity,
            reason: reason,
            at: context.timestamp
        )
    }

    private func directionalRecommendation(
        for evidence: CoverageEvidence,
        severity: CoverageDeficitSeverity,
        reason: String,
        at timestamp: Date
    ) -> CoverageRecommendation {
        let text: String
        switch severity {
        case .small:
            text = "Capture a few more views on \(evidence.sectorID.coachingLocation)."
        case .moderate:
            text = "Continue along \(evidence.sectorID.coachingLocation)."
        case .large:
            text = "Make another pass along \(evidence.sectorID.coachingLocation)."
        }

        return publish(
            text: text,
            priority: .important,
            phase: .correcting,
            target: evidence.sectorID,
            severity: severity,
            key: "correcting.\(evidence.sectorID.rawValue).\(severity.rawValue)",
            defaultReason: reason,
            diagnosticReason: "directional-guidance-repeated-\(reason)",
            at: timestamp
        )
    }

    private func completionRecommendation(
        for sector: CoverageSectorID,
        at timestamp: Date
    ) -> CoverageRecommendation {
        publish(
            text: "\(sector.coachingCompletionSubject) coverage improved. Continue forward.",
            priority: .complete,
            phase: .completed,
            target: sector,
            severity: nil,
            key: "completed.\(sector.rawValue).improved",
            defaultReason: "target-satisfied",
            diagnosticReason: "target-satisfied",
            targetOverride: sector,
            at: timestamp
        )
    }

    private func deficitSeverity(for evidence: CoverageEvidence) -> CoverageDeficitSeverity {
        if evidence.level == .none || evidence.savedFrames == 0 {
            return .large
        }
        return adequacyProgress(for: evidence) >= CoverageTuning.coachingSmallDeficitMinimumProgress
            ? .small
            : .moderate
    }

    private func adequacyProgress(for evidence: CoverageEvidence) -> Double {
        min(
            evidence.savedFrames / Double(CoverageTuning.adequateSavedFrames),
            evidence.newAngleFrames / Double(CoverageTuning.adequateNewAngleFrames),
            evidence.stableFrames / Double(CoverageTuning.adequateStableFrames),
            1
        )
    }

    private func evidenceProgressScore(for evidence: CoverageEvidence) -> Double {
        let savedProgress = min(evidence.savedFrames / Double(CoverageTuning.adequateSavedFrames), 1)
        let angleProgress = min(evidence.newAngleFrames / Double(CoverageTuning.adequateNewAngleFrames), 1)
        let stableProgress = min(evidence.stableFrames / Double(CoverageTuning.adequateStableFrames), 1)
        return (savedProgress + angleProgress + stableProgress) / 3
    }

    private func publish(
        text: String,
        priority: CoverageRecommendationPriority,
        phase: CoverageCoachingPhase,
        target: CoverageSectorID?,
        severity: CoverageDeficitSeverity?,
        key: String,
        defaultReason: String,
        diagnosticReason: String,
        targetOverride: CoverageSectorID? = nil,
        at timestamp: Date
    ) -> CoverageRecommendation {
        updateDiagnostic(reason: diagnosticReason, targetOverride: targetOverride, at: timestamp)

        if let currentRecommendation,
           currentRecommendation.text == text,
           currentRecommendation.priority == priority,
           currentRecommendation.phase == phase,
           currentRecommendation.targetSector == target,
           currentRecommendation.deficitSeverity == severity,
           currentRecommendation.key == key {
            return currentRecommendation
        }

        let reason = changeReason(
            from: currentRecommendation,
            toPhase: phase,
            target: target,
            severity: severity,
            fallback: defaultReason
        )
        let recommendation = CoverageRecommendation(
            text: text,
            priority: priority,
            phase: phase,
            targetSector: target,
            deficitSeverity: severity,
            key: key,
            changeReason: reason,
            changedAt: timestamp
        )
        currentRecommendation = recommendation
        changeHistory.append(
            CoverageCoachingChange(
                phase: phase,
                targetSector: target,
                deficitSeverity: severity,
                recommendationText: text,
                recommendationKey: key,
                reason: reason,
                timestamp: timestamp,
                state: diagnosticState
            )
        )
        return recommendation
    }

    private func updateDiagnostic(
        reason: String,
        targetOverride: CoverageSectorID? = nil,
        at timestamp: Date
    ) {
        diagnosticState = CoverageCoachingStateDiagnostic(
            rawActiveSector: rawActiveSector,
            targetSector: targetOverride ?? currentTarget ?? completedTarget,
            debouncedInTarget: debouncedInTarget,
            targetEntryStartedAt: targetEntryStartedAt,
            targetEntryElapsed: targetEntryStartedAt.map { max(timestamp.timeIntervalSince($0), 0) } ?? 0,
            targetExitStartedAt: targetExitStartedAt,
            targetExitElapsed: targetExitStartedAt.map { max(timestamp.timeIntervalSince($0), 0) } ?? 0,
            targetEvidenceDelta: targetEvidenceDelta,
            progressImproving: progressImproving,
            progressStalled: progressStalled,
            guidanceDecisionReason: reason
        )
    }

    private func changeReason(
        from previous: CoverageRecommendation?,
        toPhase phase: CoverageCoachingPhase,
        target: CoverageSectorID?,
        severity: CoverageDeficitSeverity?,
        fallback: String
    ) -> String {
        guard let previous else { return fallback }
        if previous.phase == .startup, phase != .startup { return "startup-evidence-ready" }
        if phase == .completed, target == previous.targetSector { return "target-satisfied" }
        if previous.targetSector != target { return "target-changed" }
        if previous.deficitSeverity != severity { return "deficit-severity-changed" }
        return fallback
    }
}

private extension CoverageSectorID {
    var coachingLocation: String {
        switch self {
        case .startWall: "the start wall"
        case .rightSide: "the right side"
        case .oppositeWall: "the opposite wall"
        case .leftSide: "the left side"
        }
    }

    var coachingProgressSubject: String {
        switch self {
        case .startWall: "start-wall"
        case .rightSide: "right-side"
        case .oppositeWall: "opposite-wall"
        case .leftSide: "left-side"
        }
    }

    var coachingCompletionSubject: String {
        switch self {
        case .startWall: "Start-wall"
        case .rightSide: "Right-side"
        case .oppositeWall: "Opposite-wall"
        case .leftSide: "Left-side"
        }
    }
}
