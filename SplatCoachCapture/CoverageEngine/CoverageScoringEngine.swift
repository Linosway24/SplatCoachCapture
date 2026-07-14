//
//  CoverageScoringEngine.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/13/26.
//

import Foundation

struct CoverageScoringEngine {
    func level(
        savedFrames: Double,
        newAngleFrames: Double,
        stableFrames: Double,
        viewChangeTotal: Double
    ) -> CoverageEvidenceLevel {
        if savedFrames >= Double(CoverageTuning.strongSavedFrames),
           newAngleFrames >= Double(CoverageTuning.strongNewAngleFrames),
           stableFrames >= Double(CoverageTuning.strongStableFrames) {
            return .strong
        }

        if savedFrames >= Double(CoverageTuning.adequateSavedFrames),
           newAngleFrames >= Double(CoverageTuning.adequateNewAngleFrames),
           stableFrames >= Double(CoverageTuning.adequateStableFrames) {
            return .adequate
        }

        if savedFrames > 0 || viewChangeTotal >= CoverageTuning.sparseMinimumViewChange {
            return .sparse
        }

        return .none
    }

    func rationale(
        level: CoverageEvidenceLevel,
        savedFrames: Double,
        newAngleFrames: Double,
        stableFrames: Double,
        viewChangeTotal: Double
    ) -> String {
        let saved = display(savedFrames)
        let angles = display(newAngleFrames)
        let stable = display(stableFrames)

        switch level {
        case .none:
            return "No saved-frame evidence yet."
        case .sparse:
            return "Sparse: \(saved) weighted saved, \(angles) new-angle, \(stable) stable; add views while walking."
        case .adequate:
            return "Adequate: \(saved) weighted saved, \(angles) new-angle, \(stable) stable."
        case .strong:
            return "Strong: \(saved) weighted saved, \(angles) new-angle, \(stable) stable."
        }
    }

    private func display(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
