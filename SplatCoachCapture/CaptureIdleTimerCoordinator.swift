//
//  CaptureIdleTimerCoordinator.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/13/26.
//

import Combine
import UIKit

/// Keeps the screen awake only while the capture UI is visible, the app is
/// active, and a scan is running. The setter is injectable for focused tests.
@MainActor
final class CaptureIdleTimerCoordinator: ObservableObject {
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void
    private(set) var isCaptureViewVisible = false
    private(set) var isSceneActive = false
    private(set) var isScanning = false
    private(set) var isIdleTimerDisabled = false

    init(setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void = { disabled in
        UIApplication.shared.isIdleTimerDisabled = disabled
    }) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    func setCaptureViewVisible(_ isVisible: Bool) {
        isCaptureViewVisible = isVisible
        reconcile()
    }

    func setSceneActive(_ isActive: Bool) {
        isSceneActive = isActive
        reconcile()
    }

    func setScanning(_ isScanning: Bool) {
        self.isScanning = isScanning
        reconcile()
    }

    private func reconcile() {
        let shouldDisable = isCaptureViewVisible && isSceneActive && isScanning
        guard shouldDisable != isIdleTimerDisabled else { return }
        isIdleTimerDisabled = shouldDisable
        setIdleTimerDisabled(shouldDisable)
    }

}
