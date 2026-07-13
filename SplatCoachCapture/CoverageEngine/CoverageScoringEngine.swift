//
//  CoverageScoringEngine.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/13/26.
//

import Foundation

struct CoverageScoringEngine {
    func level(
        savedFrames: Int,
        newAngleFrames: Int,
        stableFrames: Int,
        viewChangeTotal: Double
    ) -> CoverageEvidenceLevel {
        if savedFrames >= CoverageTuning.strongSavedFrames,
           newAngleFrames >= CoverageTuning.strongNewAngleFrames,
           stableFrames >= CoverageTuning.strongStableFrames {
            return .strong
        }

        if savedFrames >= CoverageTuning.adequateSavedFrames,
           newAngleFrames >= CoverageTuning.adequateNewAngleFrames,
           stableFrames >= CoverageTuning.adequateStableFrames {
            return .adequate
        }

        if savedFrames > 0 || viewChangeTotal >= CoverageTuning.sparseMinimumViewChange {
            return .sparse
        }

        return .none
    }

    func rationale(
        level: CoverageEvidenceLevel,
        savedFrames: Int,
        newAngleFrames: Int,
        stableFrames: Int,
        viewChangeTotal: Double
    ) -> String {
        switch level {
        case .none:
            return "No saved-frame evidence yet."
        case .sparse:
            return "Sparse: \(savedFrames) weighted saved, \(newAngleFrames) new-angle, \(stableFrames) stable; add views while walking."
        case .adequate:
            return "Adequate: \(savedFrames) weighted saved, \(newAngleFrames) new-angle, \(stableFrames) stable."
        case .strong:
            return "Strong: \(savedFrames) weighted saved, \(newAngleFrames) new-angle, \(stableFrames) stable."
        }
    }
}
