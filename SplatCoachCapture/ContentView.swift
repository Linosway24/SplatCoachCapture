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
    @State private var feedbackText = "READY"
    @State private var feedbackOpacity = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                CameraPreviewView(session: camera.session, orientation: camera.captureOrientation)
                    .ignoresSafeArea()

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

                if isDebugVisible {
                    debugOverlay
                        .padding(.horizontal, 14)
                        .padding(.top, proxy.safeAreaInsets.top + 74)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .background(Color.black)
        .foregroundStyle(.white)
        .task {
            await camera.prepareCamera()
        }
        .onChange(of: camera.statusText) { _, newStatus in
            showFeedback(for: newStatus)
        }
        .sheet(isPresented: $isShowingShareSheet) {
            if let exportArchiveURL {
                ShareSheet(activityItems: [exportArchiveURL])
            }
        }
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

    private var centerFeedback: some View {
        Text(feedbackText)
            .font(.system(size: 42, weight: .black, design: .rounded))
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
    }

    private func bottomOverlay(isLandscape: Bool) -> some View {
        Group {
            if isLandscape {
                HStack(spacing: 12) {
                    controlButtons
                    exportButton
                        .frame(maxWidth: 220)
                }
            } else {
                VStack(spacing: 12) {
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
                camera.startScan()
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
        }
    }

    private var exportButton: some View {
        Button {
            exportArchiveURL = camera.makeExportArchive()
            isShowingShareSheet = exportArchiveURL != nil
        } label: {
            Label("Export ZIP", systemImage: "archivebox")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OverlayButtonStyle(isProminent: false))
        .disabled(camera.savedImageURLs.isEmpty)
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
            debugRow("Blur Score", camera.lastBlurScore.map { String(format: "%.1f", $0) } ?? "Unavailable")
            debugRow("Motion Status", camera.motionStatus)
            debugRow("Current Orientation", camera.currentOrientationText)
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

    private func showFeedback(for status: String) {
        feedbackText = feedbackLabel(for: status)
        feedbackOpacity = 1

        let shouldFade = status == "Good frame" ||
            status == "Move slower" ||
            status == "Too blurry" ||
            status == "Save failed"

        guard shouldFade else { return }

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
            "GOOD FRAME"
        case "Move slower":
            "MOVE SLOWER"
        case "Too blurry":
            "TOO BLURRY"
        case "Scanning":
            "SCANNING..."
        default:
            "READY"
        }
    }
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
