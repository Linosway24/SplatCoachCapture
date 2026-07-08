//
//  MissionManager.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Combine
import Foundation

@MainActor
final class MissionManager: ObservableObject {
    @Published private(set) var activeMission: Mission
    @Published private(set) var progress: MissionProgress = .inactive

    private let walkPerimeterEvaluator = WalkPerimeterMissionEvaluator()
    private var lastTelemetry: MissionTelemetry?

    init() {
        activeMission = walkPerimeterEvaluator.mission
    }

    func startScan() {
        lastTelemetry = nil
        progress = MissionProgress(
            status: .collecting,
            instruction: activeMission.instruction,
            evidence: [],
            debugText: nil
        )
    }

    func stopScan() {
        lastTelemetry = nil
        if progress.status != .complete {
            progress = MissionProgress(
                status: progress.status,
                instruction: "Scan stopped",
                evidence: progress.evidence,
                debugText: progress.debugText
            )
        }
    }

    func reset() {
        lastTelemetry = nil
        progress = .inactive
    }

    func update(with telemetry: MissionTelemetry) {
        guard telemetry != lastTelemetry else { return }
        lastTelemetry = telemetry
        let nextProgress = walkPerimeterEvaluator.evaluate(telemetry)
        if nextProgress != progress {
            progress = nextProgress
        }
    }
}
