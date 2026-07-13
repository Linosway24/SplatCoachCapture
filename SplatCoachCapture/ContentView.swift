//
//  ContentView.swift
//  SplatCoachCapture
//
//  Created by Michael Carlino on 7/3/26.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraCaptureController()
    @State private var exportArchiveURL: URL?
    @State private var isShowingShareSheet = false
    @State private var isDebugVisible = false
    @State private var isShowingResetConfirmation = false
    @State private var isShowingPreviousScanPrompt = false
    @State private var pendingStartAfterReset = false
    @State private var feedbackText = "READY"
    @State private var feedbackOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(
                    session: camera.session,
                    orientation: camera.captureOrientation,
                    onTapToFocus: camera.focus
                )
                    .ignoresSafeArea()

                scanHealthBorder

                overlayGradient

                VStack(spacing: 0) {
                    topOverlay
                        .padding(.horizontal, 16)
                        .padding(.top, proxy.safeAreaInsets.top + 10)

                    Spacer(minLength: 0)

                    centerFeedback

                    Spacer(minLength: 0)

                    bottomOverlay(isLandscape: proxy.size.width > proxy.size.height)
                        .padding(.horizontal, 16)
                        .padding(.bottom, proxy.safeAreaInsets.bottom + 14)
                }
                .ignoresSafeArea()

                if camera.isScanning {
                    VStack(alignment: .leading, spacing: 10) {
                        MissionView(manager: camera.missionManager)
                        CoverageView(manager: camera.coverageManager)
                    }
                        .padding(.horizontal, 14)
                        .padding(.top, proxy.safeAreaInsets.top + 74)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isDebugVisible {
                    debugOverlay
                        .padding(.horizontal, 14)
                        .padding(.top, proxy.safeAreaInsets.top + 74)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let exportProgressText = camera.exportProgressText {
                    exportProgressOverlay(exportProgressText)
                        .padding(.top, proxy.safeAreaInsets.top + 76)
                        .transition(.opacity)
                }
            }
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .task {
            await camera.prepareCamera()
            if camera.previousScanFound {
                isShowingPreviousScanPrompt = true
            }
        }
        .onDisappear {
            camera.captureViewDidDisappear()
        }
        .onChange(of: camera.statusText) { _, newStatus in
            showFeedback(for: newStatus)
        }
        .onChange(of: camera.liveCoachingText) { _, newCoaching in
            showFeedback(for: newCoaching)
        }
        .sheet(isPresented: $isShowingShareSheet, onDismiss: {
            camera.clearExportProgress()
        }) {
            if let exportArchiveURL {
                ShareSheet(activityItems: [exportArchiveURL])
            }
        }
        .alert(
            "Export Failed",
            isPresented: isExportErrorPresented
        ) {
            Button("OK", role: .cancel) {
                camera.clearExportError()
            }
        } message: {
            Text(camera.exportErrorMessage ?? "The export could not be completed.")
        }
        .alert("Reset this scan?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingStartAfterReset = false
            }
            Button("Reset Scan", role: .destructive) {
                camera.resetScan()
                if pendingStartAfterReset, camera.storageErrorMessage == nil {
                    camera.startScan()
                }
                pendingStartAfterReset = false
            }
        } message: {
            Text("Captured frames will be removed unless exported first.")
        }
        .alert("Previous scan found.", isPresented: $isShowingPreviousScanPrompt) {
            Button("Export") {
                Task {
                    exportArchiveURL = await camera.makeExportArchive()
                    isShowingShareSheet = exportArchiveURL != nil
                }
            }
            Button("Discard", role: .destructive) {
                camera.discardRecoveredScan()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Storage Error",
            isPresented: isStorageErrorPresented
        ) {
            Button("OK", role: .cancel) {
                camera.clearStorageError()
            }
        } message: {
            Text(camera.storageErrorMessage ?? "The scan storage action could not be completed.")
        }
    }

    private var isExportErrorPresented: Binding<Bool> {
        Binding(
            get: { camera.exportErrorMessage != nil },
            set: { if !$0 { camera.clearExportError() } }
        )
    }

    private var isStorageErrorPresented: Binding<Bool> {
        Binding(
            get: { camera.storageErrorMessage != nil },
            set: { if !$0 { camera.clearStorageError() } }
        )
    }

    private var overlayGradient: some View {
        VStack {
            LinearGradient(
                colors: [.black.opacity(0.72), .black.opacity(0.12), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 180)

            Spacer()

            LinearGradient(
                colors: [.clear, .black.opacity(0.22), .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 210)
        }
        .ignoresSafeArea()
    }

    private var scanHealthBorder: some View {
        Rectangle()
            .strokeBorder(scanHealthColor, lineWidth: 10)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.22), value: camera.currentScanHealth)
    }

    private var topOverlay: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Splat Coach Capture")
                    .font(.headline.weight(.bold))
                    .lineLimit(1)

                Text("\(camera.savedFrameCount) saved")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }

            Spacer()

            confidencePill

            statusPill

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isDebugVisible.toggle()
                }
            } label: {
                Image(systemName: "ladybug")
                    .font(.body.weight(.bold))
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.48), in: Circle())
            }
            .accessibilityLabel("Toggle debug overlay")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(camera.isScanning ? Color.green : Color.gray)
                .frame(width: 9, height: 9)

            Text(camera.isScanning ? "Scanning" : "Ready")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.48), in: Capsule())
    }

    private var confidencePill: some View {
        HStack(spacing: 7) {
            Image(systemName: "gauge")
                .font(.caption.weight(.bold))

            Text("\(camera.scanConfidenceScore)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(confidenceColor.opacity(0.72), in: Capsule())
    }

    private var confidenceColor: Color {
        switch camera.scanConfidenceScore {
        case 80...100:
            return .green
        case 55..<80:
            return .orange
        default:
            return .black
        }
    }

    private var scanHealthColor: Color {
        switch camera.currentScanHealth {
        case .ready:
            return .gray
        case .capturing:
            return .green
        case .coach:
            return .yellow
        case .hold:
            return .orange
        case .lost:
            return .red
        }
    }

    @ViewBuilder
    private var centerFeedback: some View {
        if shouldShowLargeFeedback {
            Text(feedbackText)
                .font(.system(size: camera.currentScanHealth == .lost ? 42 : 32, weight: .black, design: .rounded))
                .minimumScaleFactor(0.48)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.black.opacity(0.52), in: RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.82), radius: 16, y: 6)
                .padding(.horizontal, 22)
                .opacity(feedbackOpacity)
                .scaleEffect(feedbackOpacity > 0.8 ? 1.0 : 0.96)
                .animation(.easeOut(duration: 0.18), value: feedbackOpacity)
        } else if camera.currentScanHealth == .capturing, camera.isScanning {
            Text("Capturing")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.34), in: Capsule())
                .foregroundStyle(.white.opacity(0.78))
        }
    }

    private var shouldShowLargeFeedback: Bool {
        if camera.currentScanHealth == .coach || camera.currentScanHealth == .hold || camera.currentScanHealth == .lost {
            return true
        }

        return !camera.isScanning && camera.postScanReport == nil
    }

    private func bottomOverlay(isLandscape: Bool) -> some View {
        VStack(spacing: 12) {
            postScanReportPanel

            Group {
                if isLandscape {
                    HStack(spacing: 12) {
                        controlButtons
                        exportButton
                            .frame(maxWidth: 220)
                    }
                } else {
                    controlButtons
                    exportButton
                }
            }
        }
        .controlSize(.large)
        .tint(.orange)
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Button {
                startButtonTapped()
            } label: {
                Label("Start", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OverlayButtonStyle(isProminent: true))
            .disabled(camera.isScanning || !camera.isReady)

            Button {
                camera.stopScan()
            } label: {
                Label("Stop", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OverlayButtonStyle(isProminent: false))
            .disabled(!camera.isScanning)

            Button {
                pendingStartAfterReset = false
                isShowingResetConfirmation = true
            } label: {
                Label("Reset", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OverlayButtonStyle(isProminent: false))
            .disabled(!camera.isScanning && !hasWorkingScan)
        }
    }

    private var exportButton: some View {
        Button {
            Task {
                exportArchiveURL = await camera.makeExportArchive()
                isShowingShareSheet = exportArchiveURL != nil
            }
        } label: {
            Label(camera.isExporting ? "Exporting" : "Export / Save", systemImage: "archivebox")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OverlayButtonStyle(isProminent: false))
        .disabled(!hasWorkingScan || camera.isExporting)
    }

    private var hasWorkingScan: Bool {
        !camera.savedImageURLs.isEmpty || camera.workingScanImageCount > 0
    }

    private func startButtonTapped() {
        if hasWorkingScan {
            pendingStartAfterReset = true
            isShowingResetConfirmation = true
        } else {
            camera.startScan()
        }
    }

    @ViewBuilder
    private var postScanReportPanel: some View {
        if let report = camera.postScanReport, !camera.isScanning {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(report.estimatedCaptureQuality)
                        .font(.headline.weight(.bold))

                    Spacer()

                    Text("\(report.confidenceScore)")
                        .font(.title3.weight(.black))
                        .monospacedDigit()
                }

                Text(report.recommendation)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))

                Text(camera.coverageManager.summary.recommendation.text)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange.opacity(0.92))

                VStack(spacing: 5) {
                    reportRow("Duration", formattedDuration(report.captureDuration))
                    reportRow("Frames", "\(report.framesSaved) saved / \(report.framesSeen) seen")
                    reportRow("Blur avg", report.blur.average.map { String(format: "%.1f", $0) } ?? "Unavailable")
                    reportRow("Motion avg", report.motion.average.map { String(format: "%.3f", $0) } ?? "Unavailable")
                    reportRow("Dominant health", "\(report.dominantScanHealth.capitalized) \(String(format: "%.0f%%", report.dominantScanHealthPercent))")
                    reportRow("Final active", report.finalActiveScanHealth.capitalized)
                    reportRow("COLMAP", report.estimatedCOLMAPReadiness)
                    ForEach(camera.coverageManager.summary.sectors) { sector in
                        reportRow(
                            sector.title,
                            "\(sector.level.title) · S\(sector.savedFrames) A\(sector.newAngleFrames)"
                        )
                    }
                }
                .font(.caption.monospacedDigit())
            }
            .padding(12)
            .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.14), lineWidth: 1)
            }
        }
    }

    private func exportProgressOverlay(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)

            Text(text)
                .font(.headline.weight(.bold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.black.opacity(0.72), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Debug", systemImage: "ladybug")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isDebugVisible = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                }
            }

            debugRow("Frames Seen", "\(camera.framesSeen)")
            debugRow("Frames Saved", "\(camera.savedFrameCount)")
            debugRow("Overlap Frames", "\(camera.savedForOverlapCount)")
            debugRow("New Angle Frames", "\(camera.savedNewAngleCount)")
            debugRow("Rejected Blurry", "\(camera.rejectedBlurryCount)")
            debugRow("Rejected Motion", "\(camera.rejectedMotionCount)")
            debugRow("Confidence", "\(camera.scanConfidenceScore)")
            debugRow("Coaching", camera.liveCoachingText)
            debugRow("Current UI State", camera.currentUIState)
            debugRow("Final Active Scan Health", camera.finalActiveScanHealth)
            debugRow("Dominant Scan Health", "\(camera.dominantScanHealth) \(String(format: "%.1f%%", camera.dominantScanHealthPercent))")
            debugRow("Health Reason", camera.scanHealthReason)
            debugRow("Health Inputs", camera.healthDecisionInputs)
            debugRow("Time Capturing", String(format: "%.1fs", camera.timeInCapturing))
            debugRow("Time Coach", String(format: "%.1fs", camera.timeInCoach))
            debugRow("Time Hold", String(format: "%.1fs", camera.timeInHold))
            debugRow("Time Lost", String(format: "%.1fs", camera.timeInLost))
            debugRow("Saved Capturing", "\(camera.savedFramesWhileCapturing)")
            debugRow("Saved Coach", "\(camera.savedFramesWhileCoach)")
            debugRow("Blocked Hold", "\(camera.framesBlockedWhileHold)")
            debugRow("Blocked Lost", "\(camera.framesBlockedWhileLost)")
            debugRow("Blocked Total", "\(camera.framesRejectedDueToPoorHealth)")
            debugRow("Working Scan", camera.workingScanExists ? "Yes" : "No")
            debugRow("Working Images", "\(camera.workingScanImageCount)")
            debugRow("Last Frame Path", camera.lastSavedFramePath)
            debugRow("Exported At", camera.exportedAt.map { Self.debugDateFormatter.string(from: $0) } ?? "Never")
            debugRow("Blur Score", camera.lastBlurScore.map { String(format: "%.1f", $0) } ?? "Unavailable")
            debugRow("Motion Score", String(format: "%.3f", camera.lastMotionScore))
            debugRow("Motion Status", camera.motionStatus)
            debugRow("Current Orientation", camera.currentOrientationText)
            debugRow("Last JPG Orientation", camera.lastSavedJPGOrientation)
            debugRow("Distance Moved", String(format: "%.3f m", camera.lastDistanceMovedMeters))
            debugRow("Rotation Delta", String(format: "%.3f rad", camera.lastRotationChangeRadians))
            debugRow("View Change", String(format: "%.1f", camera.lastViewChangeScore))
            debugRow("Time Since Save", camera.timeSinceLastSaveText)
            debugRow("Last Save Reason", camera.lastSaveReason)
            debugRow("Last Reject Reason", camera.lastRejectReason)
            debugRow("Capture FPS", String(format: "%.1f", camera.captureFPS))
        }
        .font(.system(.caption, design: .monospaced))
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        }
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func reportRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func showFeedback(for status: String) {
        feedbackText = feedbackLabel(for: status)
        feedbackOpacity = 1

        let shouldFade = status == "Good frame" ||
            status == "Good new angle" ||
            status == "Good overlap" ||
            status == "Excellent new angle" ||
            status == "Scanning well" ||
            status == "Gathering frames" ||
            status == "Find a new angle" ||
            status == "Move slower" ||
            status == "Too blurry" ||
            status == "Moving too fast" ||
            status == "Frame unavailable" ||
            status == "Hold steady" ||
            status == "Keep object centered" ||
            status == "Raise camera slightly" ||
            status == "Lower camera slightly" ||
            status == "Continue smooth orbit" ||
            status == "Save failed"

        guard shouldFade else { return }

        guard camera.currentScanHealth != .lost else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeOut(duration: 0.35)) {
                feedbackOpacity = 0
            }
        }
    }

    private func feedbackLabel(for status: String) -> String {
        switch status {
        case "Good frame":
            "GOOD OVERLAP"
        case "Good new angle":
            "EXCELLENT NEW ANGLE"
        case "Move slower":
            "MOVE SLOWER"
        case "Too blurry":
            "TOO BLURRY"
        case "Moving too fast":
            "MOVING TOO FAST"
        case "Find a new angle":
            "FIND A NEW ANGLE"
        case "Keep object centered":
            "KEEP OBJECT CENTERED"
        case "Hold steady":
            "HOLD STEADY"
        case "Frame unavailable":
            "HOLD STEADY"
        case "Gathering frames":
            "GATHERING FRAMES"
        case "Scanning well":
            "SCANNING WELL"
        case "Scanning":
            "CONTINUE SMOOTH ORBIT"
        default:
            status.uppercased()
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct OverlayButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .padding(.vertical, 13)
            .padding(.horizontal, 14)
            .background(backgroundColor(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isProminent {
            return isPressed ? .orange.opacity(0.78) : .orange
        }

        return isPressed ? .black.opacity(0.66) : .black.opacity(0.48)
    }
}

#Preview {
    ContentView()
}
