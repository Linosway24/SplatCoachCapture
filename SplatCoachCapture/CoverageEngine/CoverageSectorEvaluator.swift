//
//  CoverageSectorEvaluator.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct CoverageSectorEvaluator {
    let sectors: [CoverageSector] = [
        CoverageSector(id: .startWall, title: CoverageSectorID.startWall.title, startDegrees: 315, endDegrees: 45),
        CoverageSector(id: .rightSide, title: CoverageSectorID.rightSide.title, startDegrees: 45, endDegrees: 135),
        CoverageSector(id: .oppositeWall, title: CoverageSectorID.oppositeWall.title, startDegrees: 135, endDegrees: 225),
        CoverageSector(id: .leftSide, title: CoverageSectorID.leftSide.title, startDegrees: 225, endDegrees: 315)
    ]

    func sector(for relativeYawRadians: Double) -> CoverageSectorID {
        let degrees = normalizedDegrees(for: relativeYawRadians)

        if degrees >= 315 || degrees < 45 {
            return .startWall
        }

        if degrees >= 45, degrees < 135 {
            return .rightSide
        }

        if degrees >= 135, degrees < 225 {
            return .oppositeWall
        }

        return .leftSide
    }

    func normalizedDegrees(for relativeYawRadians: Double) -> Double {
        normalizedDegrees(relativeYawRadians * 180.0 / .pi)
    }

    func boundary(for sectorID: CoverageSectorID) -> CoverageSector? {
        sectors.first { $0.id == sectorID }
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value >= 0 ? value : value + 360
    }
}
