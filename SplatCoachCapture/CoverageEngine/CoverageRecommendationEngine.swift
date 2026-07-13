//
//  CoverageRecommendationEngine.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct CoverageRecommendationEngine {
    func recommendation(
        for sectors: [CoverageEvidence],
        movementClassification: MovementClassification
    ) -> CoverageRecommendation {
        if movementClassification == .rotatingInPlace {
            return CoverageRecommendation(
                text: "Continue one steady perimeter pass.",
                priority: .important
            )
        }

        let sorted = sectors.sorted {
            if $0.level != $1.level {
                return $0.level < $1.level
            }

            if $0.newAngleFrames != $1.newAngleFrames {
                return $0.newAngleFrames < $1.newAngleFrames
            }

            return ($0.lastUpdatedAt ?? .distantPast) < ($1.lastUpdatedAt ?? .distantPast)
        }

        guard let weakest = sorted.first else {
            return CoverageRecommendation(text: "Continue one steady perimeter pass.", priority: .normal)
        }

        if sectors.allSatisfy({ $0.level >= .adequate }) {
            return CoverageRecommendation(text: "Coverage appears complete.", priority: .complete)
        }

        if weakest.level == .none || weakest.savedFrames == 0 {
            return CoverageRecommendation(
                text: "Return to the \(weakest.title.lowercased()).",
                priority: .important
            )
        }

        if weakest.level == .sparse {
            if weakest.newAngleFrames <= 1 {
                return CoverageRecommendation(
                    text: "Add more angled views along the \(weakest.title.lowercased()).",
                    priority: .important
                )
            }

            return CoverageRecommendation(
                text: "Return to the \(weakest.title.lowercased()).",
                priority: .important
            )
        }

        return CoverageRecommendation(text: "Continue one steady perimeter pass.", priority: .normal)
    }
}
