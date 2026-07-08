//
//  CameraCaptureController.swift
//  SplatCoachCapture
//
//  Created by Michael Carlino on 7/3/26.
//

import AVFoundation
import Combine
import CoreImage
import CoreMotion
import Foundation
import UIKit

enum CaptureTuning {
    static let minimumSaveInterval: TimeInterval = 0.4
    static let blurThreshold = 28.0
    static let maxRotationRate = 2.5
    static let maxAcceleration = 1.25
    static let minimumRotationChangeRadians = 0.08
    static let minimumOverlapViewChangeScore = 1.0
    static let lumaSampleStep = 8
    static let signatureColumns = 12
    static let signatureRows = 8
    static let jpegQuality = 0.9
}

@MainActor
final class CameraCaptureController: NSObject, ObservableObject {
    @Published private(set) var statusText = "Ready"
    @Published private(set) var savedFrameCount = 0
    @Published private(set) var savedImageURLs: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isReady = false
    @Published private(set) var captureOrientation: AVCaptureVideoOrientation = .portrait

    @Published private(set) var framesSeen = 0
    @Published private(set) var framesRejected = 0
    @Published private(set) var lastBlurScore: Double?
    @Published private(set) var motionStatus = "OK"
    @Published private(set) var timeSinceLastSaveText = "--"
    @Published private(set) var lastSaveReason = "None"
    @Published private(set) var lastRejectReason = "None"
    @Published private(set) var currentOrientationText = "Portrait"
    @Published private(set) var lastDistanceMovedMeters = 0.0
    @Published private(set) var lastMotionScore = 0.0
    @Published private(set) var lastLinearAccelerationMagnitude = 0.0
    @Published private(set) var lastRotationRateMagnitude = 0.0
    @Published private(set) var lastViewChangeScore = 0.0
    @Published private(set) var lastRotationChangeRadians = 0.0
    @Published private(set) var lastSavedJPGOrientation = "None"
    @Published private(set) var captureFPS = 0.0
    @Published private(set) var savedForOverlapCount = 0
    @Published private(set) var savedNewAngleCount = 0
    @Published private(set) var rejectedBlurryCount = 0
    @Published private(set) var rejectedMotionCount = 0
    @Published private(set) var liveCoachingText = "Ready"
    @Published private(set) var scanConfidenceScore = 0
    @Published private(set) var postScanReport: CaptureIntelligenceSummary?
    @Published private(set) var currentScanHealth: ScanHealthState = .ready
    @Published private(set) var scanHealthReason = "Ready"
    @Published private(set) var healthDecisionInputs = "state=ready"
    @Published private(set) var finalActiveScanHealth = "ready"
    @Published private(set) var dominantScanHealth = "ready"
    @Published private(set) var dominantScanHealthPercent = 0.0
    @Published private(set) var timeInCapturing: TimeInterval = 0
    @Published private(set) var timeInCoach: TimeInterval = 0
    @Published private(set) var timeInHold: TimeInterval = 0
    @Published private(set) var timeInLost: TimeInterval = 0
    @Published private(set) var savedFramesWhileCapturing = 0
    @Published private(set) var savedFramesWhileCoach = 0
    @Published private(set) var framesBlockedWhileHold = 0
    @Published private(set) var framesBlockedWhileLost = 0
    @Published private(set) var framesRejectedDueToPoorHealth = 0
    @Published private(set) var workingScanExists = false
    @Published private(set) var workingScanImageCount = 0
    @Published private(set) var lastSavedFramePath = "None"
    @Published private(set) var exportedAt: Date?
    @Published private(set) var previousScanFound = false
    @Published private(set) var storageErrorMessage: String?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgressText: String?
    @Published private(set) var exportErrorMessage: String?

    let session = AVCaptureSession()
    let missionManager = MissionManager()

    var currentUIState: String {
        currentScanHealth.rawValue
    }

    private let sessionQueue = DispatchQueue(label: "com.splatcoach.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.splatcoach.capture.samples", qos: .userInitiated)
    private let motionManager = CMMotionManager()
    private let motionTrackingProvider: MotionTrackingProvider = CoreMotionProvider()

    private var videoOutput: AVCaptureVideoDataOutput?
    private var lastSavedAt = Date.distantPast
    private var frameIndex = 0
    private var outputDirectory: URL?
    private var lastSavedSignature: [Double]?
    private var lastSavedAttitude: CMAttitude?
    private var scanStartedAt: Date?
    private var scanEndedAt: Date?
    private var fpsWindowStartedAt: Date?
    private var fpsWindowFrameCount = 0
    private var frameEvents: [CaptureFrameEvent] = []
    private var motionDiagnostics: [CaptureMotionDiagnostic] = []
    private var savedIntervals: [TimeInterval] = []
    private var savedPitchSamples: [Double] = []
    private var lastSavedFrameNumber: Int?
    private var scanHealthLastUpdatedAt: Date?
    private var pendingScanHealth: ScanHealthAssessment?
    private var pendingScanHealthStartedAt: Date?
    private var movementEvidenceTracker = MovementEvidenceTracker()
    private var movementEvidenceSnapshot: MovementEvidenceSnapshot = .empty

    override init() {
        super.init()
        recoverWorkingScanIfAvailable()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        motionManager.stopDeviceMotionUpdates()
        session.stopRunning()
    }

    func prepareCamera() async {
        beginOrientationTracking()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                configureSession()
            } else {
                statusText = "Camera access denied"
                lastRejectReason = "Camera access denied"
            }
        default:
            statusText = "Camera access denied"
            lastRejectReason = "Camera access denied"
        }
    }

    func startScan() {
        guard isReady else { return }

        let startedAt = Date()
        outputDirectory = makeWorkingScanImagesDirectory()
        guard outputDirectory != nil else { return }
        savedFrameCount = 0
        savedImageURLs = []
        framesSeen = 0
        framesRejected = 0
        lastBlurScore = nil
        lastDistanceMovedMeters = 0
        lastMotionScore = 0
        lastLinearAccelerationMagnitude = 0
        lastRotationRateMagnitude = 0
        lastViewChangeScore = 0
        lastRotationChangeRadians = 0
        lastSavedJPGOrientation = "None"
        captureFPS = 0
        savedForOverlapCount = 0
        savedNewAngleCount = 0
        rejectedBlurryCount = 0
        rejectedMotionCount = 0
        liveCoachingText = "Continue smooth orbit"
        scanConfidenceScore = 0
        postScanReport = nil
        currentScanHealth = .capturing
        scanHealthReason = "Capturing usable frames"
        healthDecisionInputs = "state=capturing blur=unknown motion=stable confidence=0 saved=0"
        finalActiveScanHealth = ScanHealthState.capturing.rawValue
        dominantScanHealth = ScanHealthState.capturing.rawValue
        dominantScanHealthPercent = 0
        timeInCapturing = 0
        timeInCoach = 0
        timeInHold = 0
        timeInLost = 0
        savedFramesWhileCapturing = 0
        savedFramesWhileCoach = 0
        framesBlockedWhileHold = 0
        framesBlockedWhileLost = 0
        framesRejectedDueToPoorHealth = 0
        workingScanExists = true
        workingScanImageCount = 0
        lastSavedFramePath = "None"
        exportedAt = nil
        previousScanFound = false
        storageErrorMessage = nil
        frameIndex = 0
        lastSavedAt = .distantPast
        lastSavedFrameNumber = nil
        lastSavedSignature = nil
        lastSavedAttitude = nil
        frameEvents = []
        motionDiagnostics = []
        savedIntervals = []
        savedPitchSamples = []
        scanStartedAt = startedAt
        scanEndedAt = nil
        scanHealthLastUpdatedAt = startedAt
        pendingScanHealth = nil
        pendingScanHealthStartedAt = nil
        movementEvidenceTracker.reset()
        movementEvidenceSnapshot = .empty
        fpsWindowStartedAt = startedAt
        fpsWindowFrameCount = 0
        isScanning = true
        statusText = "Scanning"
        lastSaveReason = "None"
        lastRejectReason = "None"
        timeSinceLastSaveText = "--"
        missionManager.startScan()
        updateMissionTelemetry()
        startMotionUpdates()
        updateCaptureOrientation()
        persistWorkingScanMetadata()
    }

    func stopScan() {
        let endedAt = Date()
        accrueScanHealthTime(until: endedAt)
        finalActiveScanHealth = currentScanHealth.rawValue
        updateDominantScanHealthSummary()
        isScanning = false
        scanEndedAt = endedAt
        statusText = "Ready"
        currentScanHealth = .ready
        scanHealthReason = "Ready"
        if framesRejectedDueToPoorHealth == 0, scanConfidenceScore >= 85, savedFrameCount > 0 {
            healthDecisionInputs = "state=ready final=capturing-biased confidence=\(scanConfidenceScore) saved=\(savedFrameCount) blocked=0"
        } else {
            healthDecisionInputs = "state=ready"
        }
        pendingScanHealth = nil
        pendingScanHealthStartedAt = nil
        scanHealthLastUpdatedAt = endedAt
        missionManager.stopScan()
        postScanReport = makeCaptureIntelligenceSummary(endedAt: endedAt)
        liveCoachingText = postScanReport?.recommendation ?? "Ready"
        motionManager.stopDeviceMotionUpdates()
        persistWorkingScanMetadata()
    }

    func resetScan() {
        if isScanning {
            stopScan()
        }

        do {
            if FileManager.default.fileExists(atPath: workingScanDirectory.path) {
                try FileManager.default.removeItem(at: workingScanDirectory)
            }
            resetInMemoryScanState()
            missionManager.reset()
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Reset failed: \(error.localizedDescription)"
        }
    }

    func discardRecoveredScan() {
        resetScan()
        previousScanFound = false
    }

    func clearStorageError() {
        storageErrorMessage = nil
    }

    func clearExportError() {
        exportErrorMessage = nil
    }

    func clearExportProgress() {
        guard !isExporting else { return }
        exportProgressText = nil
    }

    func makeExportArchive() async -> URL? {
        guard !isExporting else { return nil }

        if savedImageURLs.isEmpty, workingScanImageCount > 0 {
            savedImageURLs = imageURLsInWorkingScan()
            savedFrameCount = savedImageURLs.count
        }

        guard !savedImageURLs.isEmpty else {
            exportErrorMessage = "No saved frames are available to export."
            return nil
        }

        isExporting = true
        exportErrorMessage = nil
        exportProgressText = "Preparing export"

        let scanName = "splatcoach-current-scan"
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(scanName).zip")
        let imageEntries = savedImageURLs.map { url in
            ZipFileEntry(sourceURL: url, path: "images/\(url.lastPathComponent)")
        }

        do {
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                try FileManager.default.removeItem(at: archiveURL)
            }

            let reportData = try makeCaptureReportData()
            let diagnosticsJSONData = try makeCaptureDiagnosticsJSONData()
            let diagnosticsCSVData = try makeCaptureDiagnosticsCSVData()
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try ZipArchiveWriter.write(
                    fileEntries: imageEntries,
                    dataEntries: [
                        ZipDataEntry(path: "capture_report.json", data: reportData),
                        ZipDataEntry(path: "capture_diagnostics.json", data: diagnosticsJSONData),
                        ZipDataEntry(path: "capture_diagnostics.csv", data: diagnosticsCSVData)
                    ],
                    to: archiveURL
                ) { completed, total in
                    Task { @MainActor in
                        self?.exportProgressText = "Zipping \(completed) / \(total)"
                    }
                }
            }.value

            exportProgressText = "Opening share sheet"
            exportedAt = Date()
            persistWorkingScanMetadata()
            isExporting = false
            return archiveURL
        } catch {
            isExporting = false
            exportProgressText = nil
            exportErrorMessage = "Export failed: \(error.localizedDescription)"
            statusText = "Export failed"
            lastRejectReason = "Export failed"
            return nil
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            guard
                let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: camera),
                self.session.canAddInput(input)
            else {
                Task { @MainActor in
                    self.statusText = "Camera unavailable"
                    self.lastRejectReason = "Camera unavailable"
                }
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            output.setSampleBufferDelegate(self, queue: self.sampleQueue)

            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
                self.videoOutput = output
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            Task { @MainActor in
                self.isReady = true
                self.statusText = "Ready"
                self.updateCaptureOrientation()
            }
        }
    }

    private func beginOrientationTracking() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        updateCaptureOrientation()
    }

    @objc private func deviceOrientationDidChange() {
        updateCaptureOrientation()
    }

    private func updateCaptureOrientation() {
        let newOrientation = AVCaptureVideoOrientation(deviceOrientation: UIDevice.current.orientation) ?? captureOrientation
        captureOrientation = newOrientation
        currentOrientationText = newOrientation.displayName

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.videoOutput?.connection(with: .video)?.setOrientationIfSupported(newOrientation)
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            motionStatus = "Unavailable"
            return
        }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates()
    }

    private func currentMotionSample() -> MotionSample {
        guard let motion = motionManager.deviceMotion else {
            return MotionSample(
                isAcceptable: true,
                status: "OK",
                attitude: nil,
                rotationDelta: .infinity,
                magnitude: 0,
                linearAccelerationMagnitude: 0,
                rotationRateMagnitude: 0
            )
        }

        let rotation = motion.rotationRate
        let rotationMagnitude = sqrt(
            rotation.x * rotation.x +
            rotation.y * rotation.y +
            rotation.z * rotation.z
        )

        let acceleration = motion.userAcceleration
        let accelerationMagnitude = sqrt(
            acceleration.x * acceleration.x +
            acceleration.y * acceleration.y +
            acceleration.z * acceleration.z
        )

        let attitudeDelta: Double
        if let lastSavedAttitude {
            attitudeDelta = motion.attitude.angularDifference(from: lastSavedAttitude)
        } else {
            attitudeDelta = .infinity
        }

        let isAcceptable = rotationMagnitude <= CaptureTuning.maxRotationRate &&
            accelerationMagnitude <= CaptureTuning.maxAcceleration

        return MotionSample(
            isAcceptable: isAcceptable,
            status: isAcceptable ? "OK" : "Too fast",
            attitude: motion.attitude.copy() as? CMAttitude,
            rotationDelta: attitudeDelta,
            magnitude: max(rotationMagnitude, accelerationMagnitude),
            linearAccelerationMagnitude: accelerationMagnitude,
            rotationRateMagnitude: rotationMagnitude
        )
    }

    private var workingScanDirectory: URL {
        documentsDirectory
            .appendingPathComponent("CurrentScan", isDirectory: true)
    }

    private var workingScanImagesDirectory: URL {
        workingScanDirectory
            .appendingPathComponent("images", isDirectory: true)
    }

    private var workingScanReportURL: URL {
        workingScanDirectory
            .appendingPathComponent("capture_report.json")
    }

    private var workingScanDiagnosticsJSONURL: URL {
        workingScanDirectory
            .appendingPathComponent("capture_diagnostics.json")
    }

    private var workingScanDiagnosticsCSVURL: URL {
        workingScanDirectory
            .appendingPathComponent("capture_diagnostics.csv")
    }

    private var workingScanStateURL: URL {
        workingScanDirectory
            .appendingPathComponent("scan_state.json")
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
    }

    private func makeWorkingScanImagesDirectory() -> URL? {
        do {
            try FileManager.default.createDirectory(at: workingScanImagesDirectory, withIntermediateDirectories: true)
            workingScanExists = true
            outputDirectory = workingScanImagesDirectory
            refreshWorkingScanStatus()
            return workingScanImagesDirectory
        } catch {
            statusText = "Save folder unavailable"
            lastRejectReason = "Save folder unavailable"
            storageErrorMessage = "Save folder unavailable: \(error.localizedDescription)"
            return nil
        }
    }

    private func recoverWorkingScanIfAvailable() {
        refreshWorkingScanStatus()
        guard workingScanImageCount > 0 else { return }

        outputDirectory = workingScanImagesDirectory
        savedImageURLs = imageURLsInWorkingScan()
        savedFrameCount = savedImageURLs.count
        frameIndex = savedFrameCount
        lastSavedFramePath = savedImageURLs.last?.path ?? "None"
        previousScanFound = true
        statusText = "Ready"
        liveCoachingText = "Previous scan found"
        currentScanHealth = .ready
        scanHealthReason = "Ready"
        healthDecisionInputs = "state=ready"
    }

    private func refreshWorkingScanStatus() {
        workingScanExists = FileManager.default.fileExists(atPath: workingScanDirectory.path)
        let imageURLs = imageURLsInWorkingScan()
        workingScanImageCount = imageURLs.count
        if let lastImage = imageURLs.last {
            lastSavedFramePath = lastImage.path
        } else {
            lastSavedFramePath = "None"
        }
    }

    private func imageURLsInWorkingScan() -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: workingScanImagesDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func resetInMemoryScanState() {
        savedFrameCount = 0
        savedImageURLs = []
        framesSeen = 0
        framesRejected = 0
        lastBlurScore = nil
        motionStatus = "OK"
        timeSinceLastSaveText = "--"
        lastSaveReason = "None"
        lastRejectReason = "None"
        lastDistanceMovedMeters = 0
        lastMotionScore = 0
        lastLinearAccelerationMagnitude = 0
        lastRotationRateMagnitude = 0
        lastViewChangeScore = 0
        lastRotationChangeRadians = 0
        lastSavedJPGOrientation = "None"
        captureFPS = 0
        savedForOverlapCount = 0
        savedNewAngleCount = 0
        rejectedBlurryCount = 0
        rejectedMotionCount = 0
        liveCoachingText = "Ready"
        scanConfidenceScore = 0
        postScanReport = nil
        currentScanHealth = .ready
        scanHealthReason = "Ready"
        healthDecisionInputs = "state=ready"
        finalActiveScanHealth = "ready"
        dominantScanHealth = "ready"
        dominantScanHealthPercent = 0
        timeInCapturing = 0
        timeInCoach = 0
        timeInHold = 0
        timeInLost = 0
        savedFramesWhileCapturing = 0
        savedFramesWhileCoach = 0
        framesBlockedWhileHold = 0
        framesBlockedWhileLost = 0
        framesRejectedDueToPoorHealth = 0
        workingScanExists = false
        workingScanImageCount = 0
        lastSavedFramePath = "None"
        exportedAt = nil
        previousScanFound = false
        frameIndex = 0
        lastSavedAt = .distantPast
        lastSavedFrameNumber = nil
        lastSavedSignature = nil
        lastSavedAttitude = nil
        outputDirectory = nil
        frameEvents = []
        motionDiagnostics = []
        savedIntervals = []
        savedPitchSamples = []
        scanStartedAt = nil
        scanEndedAt = nil
        scanHealthLastUpdatedAt = nil
        pendingScanHealth = nil
        pendingScanHealthStartedAt = nil
        movementEvidenceTracker.reset()
        movementEvidenceSnapshot = .empty
        fpsWindowStartedAt = nil
        fpsWindowFrameCount = 0
        isScanning = false
        statusText = "Ready"
        refreshWorkingScanStatus()
    }

    private func persistWorkingScanMetadata() {
        guard workingScanExists || !savedImageURLs.isEmpty || isScanning else { return }

        do {
            try FileManager.default.createDirectory(at: workingScanDirectory, withIntermediateDirectories: true)
            let reportData = try makeCaptureReportData()
            try reportData.write(to: workingScanReportURL, options: [.atomic])
            try makeCaptureDiagnosticsJSONData()
                .write(to: workingScanDiagnosticsJSONURL, options: [.atomic])
            try makeCaptureDiagnosticsCSVData()
                .write(to: workingScanDiagnosticsCSVURL, options: [.atomic])

            let state = WorkingScanState(
                savedImagePaths: savedImageURLs.map(\.path),
                framesSeen: framesSeen,
                framesSaved: savedFrameCount,
                framesRejected: framesRejected,
                scanConfidenceScore: scanConfidenceScore,
                currentScanHealth: currentScanHealth.rawValue,
                scanHealthReason: scanHealthReason,
                healthDecisionInputs: healthDecisionInputs,
                finalActiveScanHealth: finalActiveScanHealth,
                dominantScanHealth: dominantScanHealth,
                dominantScanHealthPercent: dominantScanHealthPercent,
                lastSavedFramePath: lastSavedFramePath == "None" ? nil : lastSavedFramePath,
                exportedAt: exportedAt
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let stateData = try encoder.encode(state)
            try stateData.write(to: workingScanStateURL, options: [.atomic])
            refreshWorkingScanStatus()
        } catch {
            storageErrorMessage = "Storage update failed: \(error.localizedDescription)"
        }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard isScanning else {
            updateElapsedTime(Date())
            return
        }

        let now = Date()
        framesSeen += 1
        updateCaptureFPS(now)
        updateElapsedTime(now)
        var missionMotion: MotionSample?
        var missionPoseChange: PoseChange?
        var missionViewChangeScore: Double?
        defer {
            if let missionMotion, let missionPoseChange {
                updateMovementEvidence(
                    at: now,
                    motion: missionMotion,
                    poseChange: missionPoseChange,
                    viewChangeScore: missionViewChangeScore
                )
            }
            updateMissionTelemetry()
        }

        let frameNumber = framesSeen
        let motion = currentMotionSample()
        missionMotion = motion
        motionStatus = motion.status
        lastMotionScore = motion.magnitude
        lastLinearAccelerationMagnitude = motion.linearAccelerationMagnitude
        lastRotationRateMagnitude = motion.rotationRateMagnitude

        let elapsed = now.timeIntervalSince(lastSavedAt)
        let timeSinceLastSaved = lastSavedAt == .distantPast ? nil : elapsed
        let poseChange = currentPoseChange(
            fallbackRotationDelta: motion.rotationDelta,
            timeSinceLastSaved: timeSinceLastSaved
        )
        missionPoseChange = poseChange
        lastDistanceMovedMeters = poseChange.distance
        lastRotationChangeRadians = poseChange.rotation

        guard elapsed >= CaptureTuning.minimumSaveInterval else {
            let assessment = makeScanHealthAssessment(
                blurScore: lastBlurScore,
                motion: motion,
                viewChangeScore: lastViewChangeScore,
                poseChange: poseChange,
                captureErrorReason: nil
            )
            updateScanHealth(assessment, at: now, immediate: assessment.isBlocking)
            appendMotionDiagnostic(
                frameNumber: frameNumber,
                timestamp: now,
                outcome: "skipped-minimum-interval",
                orientation: captureOrientation,
                motion: motion,
                poseChange: poseChange,
                blurScore: lastBlurScore,
                viewChangeScore: lastViewChangeScore,
                timeSinceLastSaved: timeSinceLastSaved,
                scanHealth: currentScanHealth,
                frameQuality: Self.frameQualityAssessment(
                    blurScore: lastBlurScore,
                    motionMagnitude: motion.magnitude,
                    rotationDelta: poseChange.rotation,
                    viewChangeScore: lastViewChangeScore,
                    exposureScore: nil,
                    textureRichnessScore: nil,
                    rejectionReason: nil
                )
            )
            updateLiveIntelligence(
                at: now,
                blurScore: lastBlurScore,
                motion: motion,
                viewChangeScore: lastViewChangeScore,
                poseChange: poseChange,
                selectedReason: nil
            )
            return
        }

        guard motion.isAcceptable else {
            let assessment = makeScanHealthAssessment(
                blurScore: nil,
                motion: motion,
                viewChangeScore: nil,
                poseChange: poseChange,
                captureErrorReason: nil
            )
            updateScanHealth(assessment, at: now, immediate: true)
            statusText = "Move slower"
            liveCoachingText = assessment.reason
            rejectedMotionCount += 1
            recordBlockedFrame(for: assessment.state)
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: assessment.reason,
                orientation: captureOrientation,
                blurScore: nil,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil,
                timeSinceLastSaved: timeSinceLastSaved,
                frameQuality: Self.frameQualityAssessment(
                    blurScore: nil,
                    motionMagnitude: motion.magnitude,
                    rotationDelta: poseChange.rotation,
                    viewChangeScore: nil,
                    exposureScore: nil,
                    textureRichnessScore: nil,
                    rejectionReason: assessment.reason
                )
            )
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            let assessment = makeScanHealthAssessment(
                blurScore: nil,
                motion: motion,
                viewChangeScore: nil,
                poseChange: poseChange,
                captureErrorReason: "Frame unavailable"
            )
            updateScanHealth(assessment, at: now, immediate: true)
            liveCoachingText = assessment.reason
            recordBlockedFrame(for: assessment.state)
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: "Frame unavailable",
                orientation: captureOrientation,
                blurScore: nil,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil,
                timeSinceLastSaved: timeSinceLastSaved,
                frameQuality: Self.frameQualityAssessment(
                    blurScore: nil,
                    motionMagnitude: motion.magnitude,
                    rotationDelta: poseChange.rotation,
                    viewChangeScore: nil,
                    exposureScore: nil,
                    textureRichnessScore: nil,
                    rejectionReason: "Frame unavailable"
                )
            )
            return
        }

        let blurScore = Self.blurScore(for: pixelBuffer)
        let lumaQuality = Self.lumaQualityStats(for: pixelBuffer)
        lastBlurScore = blurScore
        let blurPasses = blurScore.map { $0 >= CaptureTuning.blurThreshold } ?? true
        guard blurPasses else {
            let assessment = makeScanHealthAssessment(
                blurScore: blurScore,
                motion: motion,
                viewChangeScore: nil,
                poseChange: poseChange,
                captureErrorReason: nil
            )
            updateScanHealth(assessment, at: now, immediate: true)
            statusText = "Too blurry"
            liveCoachingText = assessment.reason
            rejectedBlurryCount += 1
            recordBlockedFrame(for: assessment.state)
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: "Too blurry",
                orientation: captureOrientation,
                blurScore: blurScore,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil,
                timeSinceLastSaved: timeSinceLastSaved,
                frameQuality: Self.frameQualityAssessment(
                    blurScore: blurScore,
                    motionMagnitude: motion.magnitude,
                    rotationDelta: poseChange.rotation,
                    viewChangeScore: nil,
                    exposureScore: lumaQuality.exposureScore,
                    textureRichnessScore: lumaQuality.textureRichnessScore,
                    rejectionReason: "Too blurry"
                )
            )
            return
        }

        let signature = Self.lumaSignature(for: pixelBuffer)
        let viewChangeScore = Self.viewChangeScore(previous: lastSavedSignature, current: signature)
        missionViewChangeScore = viewChangeScore
        lastViewChangeScore = viewChangeScore.isFinite ? viewChangeScore : 0

        let isFirstSave = lastSavedSignature == nil
        let rotatedEnough = poseChange.rotation >= CaptureTuning.minimumRotationChangeRadians
        let viewChangedEnough = viewChangeScore.isInfinite ||
            viewChangeScore >= CaptureTuning.minimumOverlapViewChangeScore
        let assessment = makeScanHealthAssessment(
            blurScore: blurScore,
            motion: motion,
            viewChangeScore: viewChangeScore,
            poseChange: poseChange,
            captureErrorReason: nil
        )
        let activeScanHealth = updateScanHealth(
            assessment,
            at: now,
            immediate: assessment.isBlocking
        )
        let frameQuality = Self.frameQualityAssessment(
            blurScore: blurScore,
            motionMagnitude: motion.magnitude,
            rotationDelta: poseChange.rotation,
            viewChangeScore: viewChangeScore,
            exposureScore: lumaQuality.exposureScore,
            textureRichnessScore: lumaQuality.textureRichnessScore,
            rejectionReason: activeScanHealth.blocksSaving ? scanHealthReason : nil
        )

        guard !activeScanHealth.blocksSaving else {
            recordBlockedFrame(for: activeScanHealth)
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: scanHealthReason,
                orientation: captureOrientation,
                blurScore: blurScore,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: viewChangeScore,
                timeSinceLastSaved: timeSinceLastSaved,
                frameQuality: frameQuality
            )
            liveCoachingText = scanHealthReason
            return
        }

        let reason = saveReason(
            isFirstSave: isFirstSave,
            rotatedEnough: rotatedEnough,
            viewChangedEnough: viewChangedEnough
        )

        updateLiveIntelligence(
            at: now,
            blurScore: blurScore,
            motion: motion,
            viewChangeScore: viewChangeScore,
            poseChange: poseChange,
            selectedReason: reason
        )

        saveFrame(
            pixelBuffer,
            frameNumber: frameNumber,
            capturedAt: now,
            signature: signature,
            attitude: motion.attitude,
            orientation: captureOrientation,
            blurScore: blurScore,
            motion: motion,
            poseChange: poseChange,
            viewChangeScore: viewChangeScore,
            reason: reason,
            scanHealth: activeScanHealth,
            timeSinceLastSaved: timeSinceLastSaved,
            frameQuality: frameQuality
        )
    }

    private func currentPoseChange(
        fallbackRotationDelta: Double,
        timeSinceLastSaved: TimeInterval?
    ) -> PoseChange {
        let trackingSample = motionTrackingProvider.sample(
            motion: motionManager.deviceMotion,
            fallbackRotationDelta: fallbackRotationDelta,
            timeSinceLastSaved: timeSinceLastSaved
        )

        return PoseChange(
            distance: trackingSample.estimatedTranslationDistance ?? 0,
            rotation: trackingSample.rotationDelta,
            estimatedTranslationAvailable: trackingSample.estimatedTranslationAvailable,
            estimatedTranslationDistance: trackingSample.estimatedTranslationDistance,
            estimatedTranslationVelocity: trackingSample.estimatedTranslationVelocity,
            translationMethod: trackingSample.translationMethod
        )
    }

    private func saveReason(isFirstSave: Bool, rotatedEnough: Bool, viewChangedEnough: Bool) -> String {
        if !isFirstSave && (rotatedEnough || viewChangedEnough) {
            savedNewAngleCount += 1
            return rotatedEnough ? "Saved new angle - rotation" : "Saved new angle - view change"
        }

        savedForOverlapCount += 1
        return isFirstSave ? "Saved overlap - first frame" : "Saved overlap"
    }

    private func rejectFrame(
        number: Int,
        timestamp: Date,
        reason: String,
        orientation: AVCaptureVideoOrientation,
        blurScore: Double?,
        motion: MotionSample,
        poseChange: PoseChange,
        viewChangeScore: Double?,
        timeSinceLastSaved: TimeInterval?,
        frameQuality: FrameQualityAssessment
    ) {
        framesRejected += 1
        lastRejectReason = reason
        appendMotionDiagnostic(
            frameNumber: number,
            timestamp: timestamp,
            outcome: "rejected-\(reason.diagnosticSlug)",
            orientation: orientation,
            motion: motion,
            poseChange: poseChange,
            blurScore: blurScore,
            viewChangeScore: viewChangeScore,
            timeSinceLastSaved: timeSinceLastSaved,
            scanHealth: currentScanHealth,
            frameQuality: frameQuality
        )
        appendFrameEvent(
            CaptureFrameEvent(
                frameNumber: number,
                timestamp: timestamp,
                saved: false,
                saveReason: nil,
                rejectReason: reason,
                orientation: orientation.displayName,
                blurScore: blurScore,
                motionMagnitude: motion.magnitude,
                distanceMoved: poseChange.distance.finiteOrNil,
                estimatedTranslationAvailable: poseChange.estimatedTranslationAvailable,
                estimatedTranslationDistance: poseChange.estimatedTranslationDistance?.finiteOrNil,
                estimatedTranslationVelocity: poseChange.estimatedTranslationVelocity?.finiteOrNil,
                translationMethod: poseChange.translationMethod,
                rotationDelta: poseChange.rotation.finiteOrNil,
                viewChangeScore: viewChangeScore?.finiteOrNil,
                timeSinceLastSaved: timeSinceLastSaved?.finiteOrNil,
                exposureScore: frameQuality.exposureScore?.finiteOrNil,
                textureRichnessScore: frameQuality.textureRichnessScore?.finiteOrNil,
                frameQualityTier: frameQuality.tier.rawValue,
                splatQualityScore: frameQuality.splatQualityScore,
                rejectionReason: frameQuality.rejectionReason,
                qualityReason: frameQuality.qualityReason,
                scanHealth: currentScanHealth.rawValue
            )
        )
    }

    private func recordBlockedFrame(for state: ScanHealthState) {
        framesRejectedDueToPoorHealth += 1

        if state == .lost {
            framesBlockedWhileLost += 1
        } else {
            framesBlockedWhileHold += 1
        }
    }

    private func saveFrame(
        _ pixelBuffer: CVPixelBuffer,
        frameNumber: Int,
        capturedAt: Date,
        signature: [Double],
        attitude: CMAttitude?,
        orientation: AVCaptureVideoOrientation,
        blurScore: Double?,
        motion: MotionSample,
        poseChange: PoseChange,
        viewChangeScore: Double,
        reason: String,
        scanHealth: ScanHealthState,
        timeSinceLastSaved: TimeInterval?,
        frameQuality: FrameQualityAssessment
    ) {
        guard let outputDirectory else { return }

        if lastSavedAt != .distantPast {
            savedIntervals.append(capturedAt.timeIntervalSince(lastSavedAt))
        }

        lastSavedAt = capturedAt
        lastSavedFrameNumber = frameNumber
        lastSavedSignature = signature
        lastSavedAttitude = attitude
        if let pitch = attitude?.pitch, pitch.isFinite {
            savedPitchSamples.append(pitch)
        }
        frameIndex += 1

        let url = outputDirectory.appendingPathComponent(
            "splatcoach_frame_\(String(format: "%04d", frameIndex)).jpg"
        )

        Task.detached(priority: .utility) { [pixelBuffer] in
            do {
                let result = try Self.writeJPEG(
                    from: pixelBuffer,
                    orientation: orientation,
                    to: url
                )

                await MainActor.run {
                    self.savedFrameCount += 1
                    self.savedImageURLs.append(url)
                    self.workingScanExists = true
                    self.workingScanImageCount = self.savedImageURLs.count
                    self.lastSavedFramePath = url.path
                    if scanHealth == .coach {
                        self.savedFramesWhileCoach += 1
                    } else {
                        self.savedFramesWhileCapturing += 1
                    }
                    self.lastSavedJPGOrientation = "\(orientation.displayName) \(result.width)x\(result.height)"
                    self.statusText = reason.contains("new angle") ? "Good new angle" : "Good frame"
                    if scanHealth == .coach {
                        self.liveCoachingText = self.scanHealthReason
                    } else {
                        self.liveCoachingText = reason.contains("new angle") ? "Excellent new angle" : "Good overlap"
                    }
                    self.lastSaveReason = reason
                    self.updateElapsedTime(capturedAt)
                    self.appendMotionDiagnostic(
                        frameNumber: frameNumber,
                        timestamp: capturedAt,
                        outcome: "saved-\(reason.diagnosticSlug)",
                        orientation: orientation,
                        motion: motion,
                        poseChange: poseChange,
                        blurScore: blurScore,
                        viewChangeScore: viewChangeScore,
                        timeSinceLastSaved: timeSinceLastSaved,
                        scanHealth: scanHealth,
                        frameQuality: frameQuality
                    )
                    self.appendFrameEvent(
                        CaptureFrameEvent(
                            frameNumber: frameNumber,
                            timestamp: capturedAt,
                            saved: true,
                            saveReason: reason,
                            rejectReason: nil,
                            orientation: orientation.displayName,
                            blurScore: blurScore,
                            motionMagnitude: motion.magnitude,
                            distanceMoved: poseChange.distance.finiteOrNil,
                            estimatedTranslationAvailable: poseChange.estimatedTranslationAvailable,
                            estimatedTranslationDistance: poseChange.estimatedTranslationDistance?.finiteOrNil,
                            estimatedTranslationVelocity: poseChange.estimatedTranslationVelocity?.finiteOrNil,
                            translationMethod: poseChange.translationMethod,
                            rotationDelta: poseChange.rotation.finiteOrNil,
                            viewChangeScore: viewChangeScore.finiteOrNil,
                            timeSinceLastSaved: timeSinceLastSaved?.finiteOrNil,
                            exposureScore: frameQuality.exposureScore?.finiteOrNil,
                            textureRichnessScore: frameQuality.textureRichnessScore?.finiteOrNil,
                            frameQualityTier: frameQuality.tier.rawValue,
                            splatQualityScore: frameQuality.splatQualityScore,
                            rejectionReason: frameQuality.rejectionReason,
                            qualityReason: frameQuality.qualityReason,
                            scanHealth: scanHealth.rawValue
                        )
                    )
                    self.updateMissionTelemetry()
                    self.persistWorkingScanMetadata()
                }
            } catch {
                await MainActor.run {
                    let assessment = ScanHealthAssessment(
                        state: .lost,
                        reason: "Save failed",
                        inputs: "state=lost rule=save-failed"
                    )
                    self.updateScanHealth(assessment, at: capturedAt, immediate: true)
                    self.recordBlockedFrame(for: assessment.state)
                    self.rejectFrame(
                        number: frameNumber,
                        timestamp: capturedAt,
                        reason: "Save failed",
                        orientation: orientation,
                        blurScore: blurScore,
                        motion: motion,
                        poseChange: poseChange,
                        viewChangeScore: viewChangeScore,
                        timeSinceLastSaved: timeSinceLastSaved,
                        frameQuality: FrameQualityAssessment(
                            tier: .reject,
                            splatQualityScore: 0,
                            exposureScore: frameQuality.exposureScore,
                            textureRichnessScore: frameQuality.textureRichnessScore,
                            rejectionReason: "Save failed",
                            qualityReason: "Rejected because image persistence failed."
                        )
                    )
                    self.statusText = "Save failed"
                }
            }
        }
    }

    private func appendFrameEvent(_ event: CaptureFrameEvent) {
        frameEvents.append(event)
        scanConfidenceScore = confidenceScore(endedAt: Date())
    }

    private func appendMotionDiagnostic(
        frameNumber: Int,
        timestamp: Date,
        outcome: String,
        orientation: AVCaptureVideoOrientation,
        motion: MotionSample,
        poseChange: PoseChange,
        blurScore: Double?,
        viewChangeScore: Double?,
        timeSinceLastSaved: TimeInterval?,
        scanHealth: ScanHealthState,
        frameQuality: FrameQualityAssessment
    ) {
        motionDiagnostics.append(
            CaptureMotionDiagnostic(
                frameNumber: frameNumber,
                timestamp: timestamp,
                outcome: outcome,
                orientation: orientation.displayName,
                estimatedTranslationAvailable: poseChange.estimatedTranslationAvailable,
                estimatedTranslationDistance: poseChange.estimatedTranslationDistance?.finiteOrNil,
                estimatedTranslationVelocity: poseChange.estimatedTranslationVelocity?.finiteOrNil,
                translationMethod: poseChange.translationMethod,
                rotationDelta: poseChange.rotation.finiteOrNil,
                viewChangeScore: viewChangeScore?.finiteOrNil,
                timeSinceLastSaved: timeSinceLastSaved?.finiteOrNil,
                motionMagnitude: motion.magnitude.isFinite ? motion.magnitude : nil,
                blurScore: blurScore?.finiteOrNil,
                exposureScore: frameQuality.exposureScore?.finiteOrNil,
                textureRichnessScore: frameQuality.textureRichnessScore?.finiteOrNil,
                frameQualityTier: frameQuality.tier.rawValue,
                splatQualityScore: frameQuality.splatQualityScore,
                rejectionReason: frameQuality.rejectionReason,
                qualityReason: frameQuality.qualityReason,
                scanHealth: scanHealth.rawValue
            )
        )
    }

    private func updateElapsedTime(_ now: Date) {
        guard lastSavedAt != .distantPast else {
            timeSinceLastSaveText = "--"
            return
        }

        timeSinceLastSaveText = String(format: "%.2fs", now.timeIntervalSince(lastSavedAt))
    }

    private func updateCaptureFPS(_ now: Date) {
        guard let fpsWindowStartedAt else {
            self.fpsWindowStartedAt = now
            fpsWindowFrameCount = 0
            return
        }

        fpsWindowFrameCount += 1
        let elapsed = now.timeIntervalSince(fpsWindowStartedAt)
        guard elapsed >= 1.0 else { return }

        captureFPS = Double(fpsWindowFrameCount) / elapsed
        self.fpsWindowStartedAt = now
        fpsWindowFrameCount = 0
    }

    private func updateMissionTelemetry() {
        missionManager.update(
            with: MissionTelemetry(
                isScanning: isScanning,
                framesSeen: framesSeen,
                savedFrameCount: savedFrameCount,
                savedNewAngleCount: savedNewAngleCount,
                savedOverlapCount: savedForOverlapCount,
                rejectedMotionCount: rejectedMotionCount,
                rejectedBlurryCount: rejectedBlurryCount,
                framesRejectedDueToPoorHealth: framesRejectedDueToPoorHealth,
                scanConfidenceScore: scanConfidenceScore,
                currentScanHealth: currentScanHealth,
                linearAccelerationMagnitude: lastLinearAccelerationMagnitude,
                rotationRateMagnitude: lastRotationRateMagnitude,
                recentLinearMotionImpulse: movementEvidenceSnapshot.recentLinearMotionImpulse,
                recentRotationImpulse: movementEvidenceSnapshot.recentRotationImpulse,
                rotationDominance: movementEvidenceSnapshot.rotationDominance,
                movementClassification: movementEvidenceSnapshot.movementClassification,
                translationEvidenceLevel: movementEvidenceSnapshot.translationEvidenceLevel,
                lastMotionScore: lastMotionScore,
                lastViewChangeScore: lastViewChangeScore,
                lastRotationChangeRadians: lastRotationChangeRadians,
                captureFPS: captureFPS,
                timeInCapturing: timeInCapturing,
                timeInCoach: timeInCoach,
                timeInHold: timeInHold,
                timeInLost: timeInLost
            )
        )
    }

    private func updateMovementEvidence(
        at timestamp: Date,
        motion: MotionSample,
        poseChange: PoseChange,
        viewChangeScore: Double?
    ) {
        movementEvidenceSnapshot = movementEvidenceTracker.record(
            timestamp: timestamp,
            linearAccelerationMagnitude: motion.linearAccelerationMagnitude,
            rotationRateMagnitude: motion.rotationRateMagnitude,
            attitudeRotationDelta: poseChange.rotation,
            savedFrameCount: savedFrameCount,
            savedNewAngleCount: savedNewAngleCount,
            viewChangeScore: viewChangeScore
        )
    }

    private func makeCaptureReportData() throws -> Data {
        let summary = makeCaptureIntelligenceSummary(endedAt: scanEndedAt ?? Date())
        let translationSummary = makeTranslationDiagnosticsSummary()
        let frameQualitySummary = makeFrameQualitySummary()
        let report = CaptureReport(
            appVersion: Bundle.main.appVersionString,
            deviceModel: UIDevice.current.modelIdentifier,
            iOSVersion: UIDevice.current.systemVersion,
            captureDate: ISO8601DateFormatter().string(from: scanStartedAt ?? Date()),
            captureDuration: (scanEndedAt ?? Date()).timeIntervalSince(scanStartedAt ?? Date()),
            framesSeen: framesSeen,
            framesSaved: savedFrameCount,
            framesRejected: framesRejected,
            blurThreshold: CaptureTuning.blurThreshold,
            motionThreshold: CaptureTuning.maxRotationRate,
            accelerationThreshold: CaptureTuning.maxAcceleration,
            rotationThreshold: CaptureTuning.minimumRotationChangeRadians,
            currentSettings: CaptureSettings(
                minimumSaveInterval: CaptureTuning.minimumSaveInterval,
                blurThreshold: CaptureTuning.blurThreshold,
                maxRotationRate: CaptureTuning.maxRotationRate,
                maxAcceleration: CaptureTuning.maxAcceleration,
                minimumRotationChangeRadians: CaptureTuning.minimumRotationChangeRadians,
                minimumOverlapViewChangeScore: CaptureTuning.minimumOverlapViewChangeScore,
                jpegQuality: CaptureTuning.jpegQuality
            ),
            averageBlurScore: frameEvents.compactMap(\.blurScore).average,
            averageMotionScore: frameEvents.map(\.motionMagnitude).average,
            averageTimeBetweenSaves: savedIntervals.average,
            workingScanExists: workingScanExists,
            workingScanImageCount: workingScanImageCount,
            lastSavedFramePath: lastSavedFramePath,
            exportedAt: exportedAt,
            currentScanHealth: finalActiveScanHealth,
            scanHealthReason: scanHealthReason,
            healthDecisionInputs: healthDecisionInputs,
            currentUIState: currentUIState,
            finalActiveScanHealth: finalActiveScanHealth,
            dominantScanHealth: dominantScanHealth,
            dominantScanHealthPercent: dominantScanHealthPercent,
            timeInGood: timeInCapturing,
            timeInMarginal: timeInCoach,
            timeInPoor: timeInHold,
            timeInCapturing: timeInCapturing,
            timeInCoach: timeInCoach,
            timeInHold: timeInHold,
            timeInLost: timeInLost,
            framesSavedWhileGood: savedFramesWhileCapturing,
            framesSavedWhileMarginal: savedFramesWhileCoach,
            savedFramesWhileCapturing: savedFramesWhileCapturing,
            savedFramesWhileCoach: savedFramesWhileCoach,
            framesBlockedWhileHold: framesBlockedWhileHold,
            framesBlockedWhileLost: framesBlockedWhileLost,
            framesRejectedDueToPoorHealth: framesRejectedDueToPoorHealth,
            averageTranslationDistance: translationSummary.averageTranslationDistance,
            maxTranslationDistance: translationSummary.maxTranslationDistance,
            averageTranslationVelocity: translationSummary.averageTranslationVelocity,
            maxTranslationVelocity: translationSummary.maxTranslationVelocity,
            translationSamplesAvailable: translationSummary.translationSamplesAvailable,
            translationMethodUsed: translationSummary.translationMethodUsed,
            averageSplatQualityScore: frameQualitySummary.averageSplatQualityScore,
            excellentFrameCount: frameQualitySummary.excellentFrameCount,
            acceptableFrameCount: frameQualitySummary.acceptableFrameCount,
            rejectedFrameCount: frameQualitySummary.rejectedFrameCount,
            percentExcellent: frameQualitySummary.percentExcellent,
            predictedSplatQuality: frameQualitySummary.predictedSplatQuality,
            captureIntelligence: summary,
            perFrame: frameEvents.map(\.jsonSafe)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    private func makeCaptureDiagnosticsJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(motionDiagnostics.map(\.jsonSafe))
    }

    private func makeCaptureDiagnosticsCSVData() throws -> Data {
        let header = [
            "frameNumber",
            "timestamp",
            "outcome",
            "orientation",
            "estimatedTranslationAvailable",
            "estimatedTranslationDistance",
            "estimatedTranslationVelocity",
            "translationMethod",
            "rotationDelta",
            "viewChangeScore",
            "timeSinceLastSaved",
            "motionMagnitude",
            "blurScore",
            "exposureScore",
            "textureRichnessScore",
            "frameQualityTier",
            "splatQualityScore",
            "rejectionReason",
            "qualityReason",
            "scanHealth"
        ].joined(separator: ",")

        let formatter = ISO8601DateFormatter()
        let rows = motionDiagnostics.map { diagnostic in
            [
                "\(diagnostic.frameNumber)",
                formatter.string(from: diagnostic.timestamp),
                diagnostic.outcome,
                diagnostic.orientation,
                diagnostic.estimatedTranslationAvailable ? "true" : "false",
                Self.csvNumber(diagnostic.estimatedTranslationDistance),
                Self.csvNumber(diagnostic.estimatedTranslationVelocity),
                diagnostic.translationMethod,
                Self.csvNumber(diagnostic.rotationDelta),
                Self.csvNumber(diagnostic.viewChangeScore),
                Self.csvNumber(diagnostic.timeSinceLastSaved),
                Self.csvNumber(diagnostic.motionMagnitude),
                Self.csvNumber(diagnostic.blurScore),
                Self.csvNumber(diagnostic.exposureScore),
                Self.csvNumber(diagnostic.textureRichnessScore),
                diagnostic.frameQualityTier,
                "\(diagnostic.splatQualityScore)",
                diagnostic.rejectionReason ?? "",
                diagnostic.qualityReason,
                diagnostic.scanHealth
            ]
            .map(Self.csvEscape)
            .joined(separator: ",")
        }

        let csv = ([header] + rows).joined(separator: "\n") + "\n"
        guard let data = csv.data(using: .utf8) else {
            throw CaptureDiagnosticsError.csvEncodingFailed
        }

        return data
    }

    private func makeTranslationDiagnosticsSummary() -> TranslationDiagnosticsSummary {
        let distances = motionDiagnostics
            .filter(\.estimatedTranslationAvailable)
            .compactMap(\.estimatedTranslationDistance)
            .filter(\.isFinite)
        let velocities = motionDiagnostics
            .filter(\.estimatedTranslationAvailable)
            .compactMap(\.estimatedTranslationVelocity)
            .filter(\.isFinite)
        let methods = Set(motionDiagnostics.map(\.translationMethod))
        let methodUsed: String

        if motionDiagnostics.isEmpty {
            methodUsed = "none"
        } else if distances.isEmpty {
            methodUsed = methods.sorted().joined(separator: "+")
        } else {
            methodUsed = Set(
                motionDiagnostics
                    .filter(\.estimatedTranslationAvailable)
                    .map(\.translationMethod)
            )
            .sorted()
            .joined(separator: "+")
        }

        return TranslationDiagnosticsSummary(
            averageTranslationDistance: distances.average,
            maxTranslationDistance: distances.max(),
            averageTranslationVelocity: velocities.average,
            maxTranslationVelocity: velocities.max(),
            translationSamplesAvailable: distances.count,
            translationMethodUsed: methodUsed
        )
    }

    private func makeFrameQualitySummary() -> FrameQualitySummary {
        let scores = motionDiagnostics.map { Double($0.splatQualityScore) }.filter(\.isFinite)
        let excellentCount = motionDiagnostics.filter { $0.frameQualityTier == FrameQualityTier.excellent.rawValue }.count
        let acceptableCount = motionDiagnostics.filter { $0.frameQualityTier == FrameQualityTier.acceptable.rawValue }.count
        let rejectedCount = motionDiagnostics.filter { $0.frameQualityTier == FrameQualityTier.reject.rawValue }.count
        let total = max(motionDiagnostics.count, 1)
        let percentExcellent = (Double(excellentCount) / Double(total)) * 100.0
        let average = scores.average ?? 0

        let predictedQuality: String
        switch average {
        case 85...100 where percentExcellent >= 45:
            predictedQuality = "Excellent"
        case 72...100:
            predictedQuality = "Good"
        case 55..<72:
            predictedQuality = "Fair"
        default:
            predictedQuality = "Poor"
        }

        return FrameQualitySummary(
            averageSplatQualityScore: average,
            excellentFrameCount: excellentCount,
            acceptableFrameCount: acceptableCount,
            rejectedFrameCount: rejectedCount,
            percentExcellent: percentExcellent,
            predictedSplatQuality: predictedQuality
        )
    }

    private static func csvNumber(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.6f", value)
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return value
    }

    private func updateLiveIntelligence(
        at now: Date,
        blurScore: Double?,
        motion: MotionSample,
        viewChangeScore: Double,
        poseChange: PoseChange,
        selectedReason: String?
    ) {
        scanConfidenceScore = confidenceScore(endedAt: now)

        if scanConfidenceScore >= 86, savedFrameCount >= 90 {
            liveCoachingText = "Capture complete enough"
            return
        }

        if currentScanHealth == .capturing {
            liveCoachingText = "Capturing usable frames"
            return
        }

        if currentScanHealth == .coach || currentScanHealth == .hold || currentScanHealth == .lost {
            liveCoachingText = scanHealthReason
            return
        }

        if let blurScore, blurScore < CaptureTuning.blurThreshold {
            liveCoachingText = "Too blurry"
            return
        }

        if !motion.isAcceptable || motion.magnitude > CaptureTuning.maxRotationRate * 0.82 {
            liveCoachingText = "Move slower"
            return
        }

        if let selectedReason {
            liveCoachingText = selectedReason.contains("new angle") ? "Excellent new angle" : "Good overlap"
            return
        }

        if savedFrameCount >= 24, pitchRange < 0.18 {
            liveCoachingText = averagePitch >= 0 ? "Lower camera slightly" : "Raise camera slightly"
            return
        }

        if savedFrameCount >= 8,
           viewChangeScore > CaptureTuning.minimumOverlapViewChangeScore * 2.8,
           poseChange.rotation < CaptureTuning.minimumRotationChangeRadians {
            liveCoachingText = "Keep object centered"
            return
        }

        liveCoachingText = "Continue smooth orbit"
    }

    private func makeCaptureIntelligenceSummary(endedAt: Date) -> CaptureIntelligenceSummary {
        let duration = endedAt.timeIntervalSince(scanStartedAt ?? endedAt)
        let blurScores = frameEvents.compactMap(\.blurScore).filter(\.isFinite)
        let motionScores = frameEvents.map(\.motionMagnitude).filter(\.isFinite)
        let viewScores = frameEvents.compactMap(\.viewChangeScore).filter(\.isFinite)
        let translationSummary = makeTranslationDiagnosticsSummary()
        let frameQualitySummary = makeFrameQualitySummary()
        let confidence = confidenceScore(endedAt: endedAt)
        let estimatedQuality = estimatedQualityLabel(for: confidence)
        let colmapReadiness = estimatedCOLMAPReadiness(for: confidence)

        return CaptureIntelligenceSummary(
            captureDuration: duration,
            framesSeen: framesSeen,
            framesSaved: savedFrameCount,
            framesRejected: framesRejected,
            rejectedBlurryFrames: rejectedBlurryCount,
            rejectedMotionFrames: rejectedMotionCount,
            savedOverlapFrames: savedForOverlapCount,
            savedNewAngleFrames: savedNewAngleCount,
            blur: CaptureMetricStats(values: blurScores),
            motion: CaptureMetricStats(values: motionScores),
            averageTimeBetweenSaves: savedIntervals.average,
            averageViewChangeScore: viewScores.average,
            viewpointDiversityScore: viewpointDiversityScore,
            verticalVariationRadians: pitchRange,
            confidenceScore: confidence,
            currentScanHealth: finalActiveScanHealth,
            scanHealthReason: scanHealthReason,
            healthDecisionInputs: healthDecisionInputs,
            currentUIState: currentUIState,
            finalActiveScanHealth: finalActiveScanHealth,
            dominantScanHealth: dominantScanHealth,
            dominantScanHealthPercent: dominantScanHealthPercent,
            timeInGood: timeInCapturing,
            timeInMarginal: timeInCoach,
            timeInPoor: timeInHold,
            timeInCapturing: timeInCapturing,
            timeInCoach: timeInCoach,
            timeInHold: timeInHold,
            timeInLost: timeInLost,
            framesSavedWhileGood: savedFramesWhileCapturing,
            framesSavedWhileMarginal: savedFramesWhileCoach,
            savedFramesWhileCapturing: savedFramesWhileCapturing,
            savedFramesWhileCoach: savedFramesWhileCoach,
            framesBlockedWhileHold: framesBlockedWhileHold,
            framesBlockedWhileLost: framesBlockedWhileLost,
            framesRejectedDueToPoorHealth: framesRejectedDueToPoorHealth,
            averageTranslationDistance: translationSummary.averageTranslationDistance,
            maxTranslationDistance: translationSummary.maxTranslationDistance,
            averageTranslationVelocity: translationSummary.averageTranslationVelocity,
            maxTranslationVelocity: translationSummary.maxTranslationVelocity,
            translationSamplesAvailable: translationSummary.translationSamplesAvailable,
            translationMethodUsed: translationSummary.translationMethodUsed,
            averageSplatQualityScore: frameQualitySummary.averageSplatQualityScore,
            excellentFrameCount: frameQualitySummary.excellentFrameCount,
            acceptableFrameCount: frameQualitySummary.acceptableFrameCount,
            rejectedFrameCount: frameQualitySummary.rejectedFrameCount,
            percentExcellent: frameQualitySummary.percentExcellent,
            predictedSplatQuality: frameQualitySummary.predictedSplatQuality,
            estimatedCaptureQuality: estimatedQuality,
            estimatedCOLMAPReadiness: colmapReadiness,
            recommendation: recommendation(confidence: confidence)
        )
    }

    @discardableResult
    private func updateScanHealth(
        _ assessment: ScanHealthAssessment,
        at now: Date,
        immediate: Bool = false
    ) -> ScanHealthState {
        accrueScanHealthTime(until: now)

        guard isScanning else {
            currentScanHealth = .ready
            scanHealthReason = "Ready"
            healthDecisionInputs = "state=ready"
            pendingScanHealth = nil
            pendingScanHealthStartedAt = nil
            return currentScanHealth
        }

        if assessment.state == currentScanHealth {
            scanHealthReason = assessment.reason
            healthDecisionInputs = assessment.inputs
            pendingScanHealth = nil
            pendingScanHealthStartedAt = nil
            return currentScanHealth
        }

        if immediate || assessment.isBlocking {
            applyScanHealth(assessment)
            return currentScanHealth
        }

        if assessment.state == .capturing {
            applyScanHealth(assessment)
            return currentScanHealth
        }

        if pendingScanHealth == assessment {
            let pendingDuration = now.timeIntervalSince(pendingScanHealthStartedAt ?? now)
            healthDecisionInputs = "\(assessment.inputs) pending=\(String(format: "%.1f", pendingDuration))s"
            if pendingDuration >= 2.0 {
                applyScanHealth(assessment)
            }
        } else {
            pendingScanHealth = assessment
            pendingScanHealthStartedAt = now
            healthDecisionInputs = "\(assessment.inputs) pending=0.0s"
        }

        return currentScanHealth
    }

    private func applyScanHealth(_ assessment: ScanHealthAssessment) {
        currentScanHealth = assessment.state
        scanHealthReason = assessment.reason
        healthDecisionInputs = assessment.inputs
        pendingScanHealth = nil
        pendingScanHealthStartedAt = nil
    }

    private func accrueScanHealthTime(until now: Date) {
        guard let scanHealthLastUpdatedAt else {
            self.scanHealthLastUpdatedAt = now
            return
        }

        let elapsed = max(now.timeIntervalSince(scanHealthLastUpdatedAt), 0)
        switch currentScanHealth {
        case .capturing:
            timeInCapturing += elapsed
        case .coach:
            timeInCoach += elapsed
        case .hold:
            timeInHold += elapsed
        case .lost:
            timeInLost += elapsed
        case .ready:
            break
        }

        self.scanHealthLastUpdatedAt = now
    }

    private func updateDominantScanHealthSummary() {
        let durations: [(state: ScanHealthState, duration: TimeInterval)] = [
            (.capturing, timeInCapturing),
            (.coach, timeInCoach),
            (.hold, timeInHold),
            (.lost, timeInLost)
        ]
        let total = durations.reduce(0) { $0 + max($1.duration, 0) }

        guard total > 0, let dominant = durations.max(by: { $0.duration < $1.duration }) else {
            dominantScanHealth = finalActiveScanHealth
            dominantScanHealthPercent = 0
            return
        }

        dominantScanHealth = dominant.state.rawValue
        dominantScanHealthPercent = (dominant.duration / total) * 100.0
    }

    private func makeScanHealthAssessment(
        blurScore: Double?,
        motion: MotionSample,
        viewChangeScore: Double?,
        poseChange: PoseChange,
        captureErrorReason: String?
    ) -> ScanHealthAssessment {
        let blurText = blurScore.map { String(format: "%.1f", $0) } ?? "unknown"
        let viewText = viewChangeScore.map { $0.isFinite ? String(format: "%.2f", $0) : "inf" } ?? "unknown"
        let savedRecently = lastSavedAt != .distantPast && Date().timeIntervalSince(lastSavedAt) <= 2.0
        let baseInputs = "confidence=\(scanConfidenceScore) saved=\(savedFrameCount) blocked=\(framesRejectedDueToPoorHealth) blur=\(blurText) motion=\(String(format: "%.2f", motion.magnitude)) view=\(viewText) rotation=\(String(format: "%.3f", poseChange.rotation)) savedRecently=\(savedRecently)"

        if let captureErrorReason {
            return ScanHealthAssessment(
                state: .lost,
                reason: captureErrorReason,
                inputs: "\(baseInputs) rule=capture-error"
            )
        }

        if let blurScore, blurScore < CaptureTuning.blurThreshold {
            return ScanHealthAssessment(
                state: .hold,
                reason: "Too blurry",
                inputs: "\(baseInputs) rule=blur-below-threshold"
            )
        }

        if !motion.isAcceptable {
            if motion.magnitude >= CaptureTuning.maxRotationRate * 1.6 {
                return ScanHealthAssessment(
                    state: .lost,
                    reason: "Tracking unstable",
                    inputs: "\(baseInputs) rule=severe-motion"
                )
            }

            return ScanHealthAssessment(
                state: .hold,
                reason: "Moving too fast",
                inputs: "\(baseInputs) rule=motion-rejected"
            )
        }

        if motion.magnitude >= CaptureTuning.maxRotationRate * 0.82 {
            return ScanHealthAssessment(
                state: .coach,
                reason: "Move slower",
                inputs: "\(baseInputs) rule=motion-near-threshold"
            )
        }

        if scanConfidenceScore >= 85, framesRejectedDueToPoorHealth == 0 {
            return ScanHealthAssessment(
                state: .capturing,
                reason: "Capturing usable frames",
                inputs: "\(baseInputs) rule=high-confidence-capturing-bias"
            )
        }

        if savedFrameCount > 0, savedRecently {
            return ScanHealthAssessment(
                state: .capturing,
                reason: "Capturing usable frames",
                inputs: "\(baseInputs) rule=saving-normally"
            )
        }

        if scanConfidenceScore < 45, framesSeen > 36, savedFrameCount < 12 {
            return ScanHealthAssessment(
                state: .coach,
                reason: "Find a new angle",
                inputs: "\(baseInputs) rule=low-confidence-low-saves"
            )
        }

        if let viewChangeScore,
           viewChangeScore.isFinite,
           viewChangeScore < CaptureTuning.minimumOverlapViewChangeScore * 0.35,
           savedFrameCount > 8 {
            return ScanHealthAssessment(
                state: .coach,
                reason: "Find a new angle",
                inputs: "\(baseInputs) rule=too-similar"
            )
        }

        return ScanHealthAssessment(
            state: .capturing,
            reason: "Capturing usable frames",
            inputs: "\(baseInputs) rule=stable-acceptable"
        )
    }

    private func confidenceScore(endedAt: Date) -> Int {
        let duration = endedAt.timeIntervalSince(scanStartedAt ?? endedAt)
        let blurScores = frameEvents.compactMap(\.blurScore).filter(\.isFinite)
        let motionScores = frameEvents.map(\.motionMagnitude).filter(\.isFinite)

        let blurQuality = blurScores.average.map {
            clamp(($0 - CaptureTuning.blurThreshold * 0.65) / CaptureTuning.blurThreshold)
        } ?? (savedFrameCount > 0 ? 0.7 : 0)

        let motionAverage = motionScores.average ?? 0
        let motionQuality = clamp(1.0 - (motionAverage / CaptureTuning.maxRotationRate))
        let frameQuality = clamp(Double(savedFrameCount) / 120.0)
        let durationQuality = clamp(duration / 55.0)

        let score = (blurQuality * 25.0) +
            (motionQuality * 20.0) +
            (frameQuality * 25.0) +
            (durationQuality * 10.0) +
            (viewpointDiversityScore * 20.0)

        return Int(score.rounded()).clamped(to: 0...100)
    }

    private var viewpointDiversityScore: Double {
        guard savedFrameCount > 0 else { return 0 }
        let newAngleProgress = clamp(Double(savedNewAngleCount) / 55.0)
        let newAngleRatio = clamp(Double(savedNewAngleCount) / Double(max(savedFrameCount, 1)) / 0.55)
        let verticalVariation = clamp(pitchRange / 0.45)
        return clamp((newAngleProgress * 0.5) + (newAngleRatio * 0.35) + (verticalVariation * 0.15))
    }

    private var pitchRange: Double {
        guard let minPitch = savedPitchSamples.min(), let maxPitch = savedPitchSamples.max() else {
            return 0
        }
        return maxPitch - minPitch
    }

    private var averagePitch: Double {
        savedPitchSamples.average ?? 0
    }

    private func estimatedQualityLabel(for confidence: Int) -> String {
        switch confidence {
        case 85...100:
            return "Good dataset"
        case 65..<85:
            return "Usable dataset"
        case 45..<65:
            return "Needs more coverage"
        default:
            return "Likely weak dataset"
        }
    }

    private func estimatedCOLMAPReadiness(for confidence: Int) -> String {
        switch confidence {
        case 80...100:
            return "Likely ready"
        case 60..<80:
            return "Probably usable"
        default:
            return "Needs another pass"
        }
    }

    private func recommendation(confidence: Int) -> String {
        if confidence >= 85, savedFrameCount >= 90 {
            return "Good dataset - Ready for export."
        }

        if rejectedMotionCount > max(8, framesSeen / 8) {
            return "Move slower next scan."
        }

        if rejectedBlurryCount > max(8, framesSeen / 8) {
            return "Move slower and keep the camera steady next scan."
        }

        if savedFrameCount < 80 || viewpointDiversityScore < 0.62 {
            return "Capture one more orbit around the object."
        }

        return "Good dataset - Ready for export."
    }

    private static func blurScore(for pixelBuffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let step = CaptureTuning.lumaSampleStep

        guard width > step * 2, height > step * 2 else { return nil }

        var count = 0
        var mean = 0.0
        var sumOfSquares = 0.0

        stride(from: step, to: height - step, by: step).forEach { y in
            stride(from: step, to: width - step, by: step).forEach { x in
                let center = Double(buffer[y * bytesPerRow + x])
                let left = Double(buffer[y * bytesPerRow + x - step])
                let right = Double(buffer[y * bytesPerRow + x + step])
                let up = Double(buffer[(y - step) * bytesPerRow + x])
                let down = Double(buffer[(y + step) * bytesPerRow + x])
                let laplacian = (4.0 * center) - left - right - up - down

                count += 1
                let delta = laplacian - mean
                mean += delta / Double(count)
                let deltaAfterMean = laplacian - mean
                sumOfSquares += delta * deltaAfterMean
            }
        }

        guard count > 1 else { return nil }
        return sumOfSquares / Double(count - 1)
    }

    private static func lumaQualityStats(for pixelBuffer: CVPixelBuffer) -> LumaQualityStats {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return LumaQualityStats(exposureScore: nil, textureRichnessScore: nil)
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let step = CaptureTuning.lumaSampleStep

        guard width > step * 2, height > step * 2 else {
            return LumaQualityStats(exposureScore: nil, textureRichnessScore: nil)
        }

        var count = 0
        var mean = 0.0
        var sumOfSquares = 0.0

        stride(from: step, to: height - step, by: step).forEach { y in
            stride(from: step, to: width - step, by: step).forEach { x in
                let value = Double(buffer[y * bytesPerRow + x])
                count += 1
                let delta = value - mean
                mean += delta / Double(count)
                let deltaAfterMean = value - mean
                sumOfSquares += delta * deltaAfterMean
            }
        }

        guard count > 1 else {
            return LumaQualityStats(exposureScore: nil, textureRichnessScore: nil)
        }

        let variance = sumOfSquares / Double(count - 1)
        let standardDeviation = sqrt(max(variance, 0))
        let exposureScore = clamp(1.0 - abs(mean - 128.0) / 128.0)
        let textureRichnessScore = clamp(standardDeviation / 52.0)

        return LumaQualityStats(
            exposureScore: exposureScore,
            textureRichnessScore: textureRichnessScore
        )
    }

    private static func frameQualityAssessment(
        blurScore: Double?,
        motionMagnitude: Double,
        rotationDelta: Double,
        viewChangeScore: Double?,
        exposureScore: Double?,
        textureRichnessScore: Double?,
        rejectionReason: String?
    ) -> FrameQualityAssessment {
        var score = 100.0
        var reasons: [String] = []

        // Frame Quality Scoring v1 is deliberately conservative and diagnostic-only.
        // It starts at 100, subtracts for conditions that make Gaussian splats weaker
        // (soft frames, unstable motion, poor overlap/novelty, extreme rotation,
        // bad exposure, or low texture), and never feeds back into save/reject logic.
        if let rejectionReason {
            score -= 45
            reasons.append("capture rejected: \(rejectionReason)")
        }

        if let blurScore {
            let blurRatio = blurScore / CaptureTuning.blurThreshold
            if blurRatio < 1.0 {
                score -= 35
                reasons.append("blur below capture threshold")
            } else if blurRatio < 1.25 {
                score -= 16
                reasons.append("sharpness is only marginal")
            } else if blurRatio >= 2.0 {
                reasons.append("sharp frame")
            }
        } else {
            score -= 10
            reasons.append("blur unavailable")
        }

        let motionRatio = motionMagnitude / CaptureTuning.maxRotationRate
        if motionRatio >= 1.0 {
            score -= 25
            reasons.append("motion over stability threshold")
        } else if motionRatio >= 0.72 {
            score -= 12
            reasons.append("motion near stability threshold")
        } else {
            reasons.append("stable motion")
        }

        if rotationDelta >= CaptureTuning.minimumRotationChangeRadians * 6.0 {
            score -= 12
            reasons.append("large rotation jump")
        } else if rotationDelta >= CaptureTuning.minimumRotationChangeRadians {
            reasons.append("meaningful rotation change")
        }

        if let viewChangeScore, viewChangeScore.isFinite {
            let viewRatio = viewChangeScore / CaptureTuning.minimumOverlapViewChangeScore
            if viewRatio < 0.35 {
                score -= 18
                reasons.append("view change too small")
            } else if viewRatio < 1.0 {
                score -= 8
                reasons.append("limited view change")
            } else {
                reasons.append("meaningful view change")
            }
        } else if viewChangeScore == nil {
            score -= 4
            reasons.append("view change unavailable")
        }

        if let exposureScore {
            let exposurePenalty = (1.0 - clamp(exposureScore)) * 14.0
            if exposurePenalty > 8 {
                reasons.append("exposure may be weak")
            }
            score -= exposurePenalty
        }

        if let textureRichnessScore {
            let texturePenalty = (1.0 - clamp(textureRichnessScore)) * 10.0
            if texturePenalty > 6 {
                reasons.append("low texture richness")
            }
            score -= texturePenalty
        }

        let finalScore = Int(score.rounded()).clamped(to: 0...100)
        let tier: FrameQualityTier
        if rejectionReason != nil || finalScore < 55 {
            tier = .reject
        } else if finalScore >= 82 {
            tier = .excellent
        } else {
            tier = .acceptable
        }

        return FrameQualityAssessment(
            tier: tier,
            splatQualityScore: finalScore,
            exposureScore: exposureScore,
            textureRichnessScore: textureRichnessScore,
            rejectionReason: tier == .reject ? rejectionReason ?? "Low splat quality score" : nil,
            qualityReason: reasons.joined(separator: "; ")
        )
    }

    private static func lumaSignature(for pixelBuffer: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return []
        }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let cellWidth = max(width / CaptureTuning.signatureColumns, 1)
        let cellHeight = max(height / CaptureTuning.signatureRows, 1)
        let sampleStride = CaptureTuning.lumaSampleStep
        var signature: [Double] = []
        signature.reserveCapacity(CaptureTuning.signatureColumns * CaptureTuning.signatureRows)

        for row in 0..<CaptureTuning.signatureRows {
            for column in 0..<CaptureTuning.signatureColumns {
                let startX = column * cellWidth
                let endX = min(startX + cellWidth, width)
                let startY = row * cellHeight
                let endY = min(startY + cellHeight, height)

                var total = 0.0
                var count = 0

                stride(from: startY, to: endY, by: sampleStride).forEach { y in
                    stride(from: startX, to: endX, by: sampleStride).forEach { x in
                        total += Double(buffer[y * bytesPerRow + x])
                        count += 1
                    }
                }

                signature.append(count > 0 ? total / Double(count) : 0)
            }
        }

        return signature
    }

    private static func viewChangeScore(previous: [Double]?, current: [Double]) -> Double {
        guard let previous, previous.count == current.count, !current.isEmpty else {
            return .infinity
        }

        let totalDifference = zip(previous, current).reduce(0.0) { partial, pair in
            partial + abs(pair.0 - pair.1)
        }
        return totalDifference / Double(current.count)
    }

    nonisolated private static func writeJPEG(
        from pixelBuffer: CVPixelBuffer,
        orientation: AVCaptureVideoOrientation,
        to url: URL
    ) throws -> SavedJPEGResult {
        let image = imageForJPEG(from: pixelBuffer, orientation: orientation)
        let context = CIContext()

        guard
            let cgImage = context.createCGImage(image, from: image.extent),
            let data = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
                .jpegData(compressionQuality: CaptureTuning.jpegQuality)
        else {
            throw CaptureSaveError.jpegEncodeFailed
        }

        try data.write(to: url, options: [.atomic])
        return SavedJPEGResult(width: Int(image.extent.width), height: Int(image.extent.height))
    }

    nonisolated private static func imageForJPEG(
        from pixelBuffer: CVPixelBuffer,
        orientation: AVCaptureVideoOrientation
    ) -> CIImage {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let isBufferLandscape = extent.width >= extent.height

        if orientation.isLandscape {
            guard !isBufferLandscape else { return image }
            return image.oriented(orientation.landscapeImageOrientation)
        }

        guard isBufferLandscape else { return image }
        return image.oriented(orientation.portraitImageOrientation)
    }
}

private enum CaptureSaveError: Error {
    case jpegEncodeFailed
}

private enum CaptureDiagnosticsError: Error {
    case csvEncodingFailed
}

private struct SavedJPEGResult {
    let width: Int
    let height: Int
}

private struct MotionSample {
    let isAcceptable: Bool
    let status: String
    let attitude: CMAttitude?
    let rotationDelta: Double
    let magnitude: Double
    let linearAccelerationMagnitude: Double
    let rotationRateMagnitude: Double
}

private struct PoseChange {
    let distance: Double
    let rotation: Double
    let estimatedTranslationAvailable: Bool
    let estimatedTranslationDistance: Double?
    let estimatedTranslationVelocity: Double?
    let translationMethod: String
}

private struct MotionTrackingSample {
    let estimatedTranslationAvailable: Bool
    let estimatedTranslationDistance: Double?
    let estimatedTranslationVelocity: Double?
    let translationMethod: String
    let rotationDelta: Double
}

private protocol MotionTrackingProvider {
    var methodName: String { get }

    func sample(
        motion: CMDeviceMotion?,
        fallbackRotationDelta: Double,
        timeSinceLastSaved: TimeInterval?
    ) -> MotionTrackingSample
}

private struct CoreMotionProvider: MotionTrackingProvider {
    let methodName = "coreMotion-unavailable"

    func sample(
        motion: CMDeviceMotion?,
        fallbackRotationDelta: Double,
        timeSinceLastSaved: TimeInterval?
    ) -> MotionTrackingSample {
        MotionTrackingSample(
            estimatedTranslationAvailable: false,
            estimatedTranslationDistance: nil,
            estimatedTranslationVelocity: nil,
            translationMethod: methodName,
            rotationDelta: fallbackRotationDelta.isFinite ? fallbackRotationDelta : 0
        )
    }
}

private struct FutureARKitProvider: MotionTrackingProvider {
    let methodName = "futureARKit"

    func sample(
        motion: CMDeviceMotion?,
        fallbackRotationDelta: Double,
        timeSinceLastSaved: TimeInterval?
    ) -> MotionTrackingSample {
        MotionTrackingSample(
            estimatedTranslationAvailable: false,
            estimatedTranslationDistance: nil,
            estimatedTranslationVelocity: nil,
            translationMethod: "\(methodName)-not-implemented",
            rotationDelta: fallbackRotationDelta.isFinite ? fallbackRotationDelta : 0
        )
    }
}

private struct FutureOpticalFlowProvider: MotionTrackingProvider {
    let methodName = "futureOpticalFlow"

    func sample(
        motion: CMDeviceMotion?,
        fallbackRotationDelta: Double,
        timeSinceLastSaved: TimeInterval?
    ) -> MotionTrackingSample {
        MotionTrackingSample(
            estimatedTranslationAvailable: false,
            estimatedTranslationDistance: nil,
            estimatedTranslationVelocity: nil,
            translationMethod: "\(methodName)-not-implemented",
            rotationDelta: fallbackRotationDelta.isFinite ? fallbackRotationDelta : 0
        )
    }
}

private struct TranslationDiagnosticsSummary {
    let averageTranslationDistance: Double?
    let maxTranslationDistance: Double?
    let averageTranslationVelocity: Double?
    let maxTranslationVelocity: Double?
    let translationSamplesAvailable: Int
    let translationMethodUsed: String
}

private struct LumaQualityStats {
    let exposureScore: Double?
    let textureRichnessScore: Double?
}

private enum FrameQualityTier: String, Encodable {
    case excellent
    case acceptable
    case reject
}

private struct FrameQualityAssessment {
    let tier: FrameQualityTier
    let splatQualityScore: Int
    let exposureScore: Double?
    let textureRichnessScore: Double?
    let rejectionReason: String?
    let qualityReason: String
}

private struct FrameQualitySummary {
    let averageSplatQualityScore: Double
    let excellentFrameCount: Int
    let acceptableFrameCount: Int
    let rejectedFrameCount: Int
    let percentExcellent: Double
    let predictedSplatQuality: String
}

enum ScanHealthState: String, Encodable, Equatable {
    case ready
    case capturing
    case coach
    case hold
    case lost

    var blocksSaving: Bool {
        self == .hold || self == .lost
    }
}

private struct ScanHealthAssessment: Equatable {
    let state: ScanHealthState
    let reason: String
    let inputs: String

    init(state: ScanHealthState, reason: String, inputs: String = "") {
        self.state = state
        self.reason = reason
        self.inputs = inputs
    }

    var isBlocking: Bool {
        state.blocksSaving
    }
}

struct CaptureReport: Encodable {
    let appVersion: String
    let deviceModel: String
    let iOSVersion: String
    let captureDate: String
    let captureDuration: TimeInterval
    let framesSeen: Int
    let framesSaved: Int
    let framesRejected: Int
    let blurThreshold: Double
    let motionThreshold: Double
    let accelerationThreshold: Double
    let rotationThreshold: Double
    let currentSettings: CaptureSettings
    let averageBlurScore: Double?
    let averageMotionScore: Double?
    let averageTimeBetweenSaves: Double?
    let workingScanExists: Bool
    let workingScanImageCount: Int
    let lastSavedFramePath: String
    let exportedAt: Date?
    let currentScanHealth: String
    let scanHealthReason: String
    let healthDecisionInputs: String
    let currentUIState: String
    let finalActiveScanHealth: String
    let dominantScanHealth: String
    let dominantScanHealthPercent: Double
    let timeInGood: TimeInterval
    let timeInMarginal: TimeInterval
    let timeInPoor: TimeInterval
    let timeInCapturing: TimeInterval
    let timeInCoach: TimeInterval
    let timeInHold: TimeInterval
    let timeInLost: TimeInterval
    let framesSavedWhileGood: Int
    let framesSavedWhileMarginal: Int
    let savedFramesWhileCapturing: Int
    let savedFramesWhileCoach: Int
    let framesBlockedWhileHold: Int
    let framesBlockedWhileLost: Int
    let framesRejectedDueToPoorHealth: Int
    let averageTranslationDistance: Double?
    let maxTranslationDistance: Double?
    let averageTranslationVelocity: Double?
    let maxTranslationVelocity: Double?
    let translationSamplesAvailable: Int
    let translationMethodUsed: String
    let averageSplatQualityScore: Double
    let excellentFrameCount: Int
    let acceptableFrameCount: Int
    let rejectedFrameCount: Int
    let percentExcellent: Double
    let predictedSplatQuality: String
    let captureIntelligence: CaptureIntelligenceSummary
    let perFrame: [CaptureFrameEvent]
}

struct CaptureIntelligenceSummary: Encodable {
    let captureDuration: TimeInterval
    let framesSeen: Int
    let framesSaved: Int
    let framesRejected: Int
    let rejectedBlurryFrames: Int
    let rejectedMotionFrames: Int
    let savedOverlapFrames: Int
    let savedNewAngleFrames: Int
    let blur: CaptureMetricStats
    let motion: CaptureMetricStats
    let averageTimeBetweenSaves: Double?
    let averageViewChangeScore: Double?
    let viewpointDiversityScore: Double
    let verticalVariationRadians: Double
    let confidenceScore: Int
    let currentScanHealth: String
    let scanHealthReason: String
    let healthDecisionInputs: String
    let currentUIState: String
    let finalActiveScanHealth: String
    let dominantScanHealth: String
    let dominantScanHealthPercent: Double
    let timeInGood: TimeInterval
    let timeInMarginal: TimeInterval
    let timeInPoor: TimeInterval
    let timeInCapturing: TimeInterval
    let timeInCoach: TimeInterval
    let timeInHold: TimeInterval
    let timeInLost: TimeInterval
    let framesSavedWhileGood: Int
    let framesSavedWhileMarginal: Int
    let savedFramesWhileCapturing: Int
    let savedFramesWhileCoach: Int
    let framesBlockedWhileHold: Int
    let framesBlockedWhileLost: Int
    let framesRejectedDueToPoorHealth: Int
    let averageTranslationDistance: Double?
    let maxTranslationDistance: Double?
    let averageTranslationVelocity: Double?
    let maxTranslationVelocity: Double?
    let translationSamplesAvailable: Int
    let translationMethodUsed: String
    let averageSplatQualityScore: Double
    let excellentFrameCount: Int
    let acceptableFrameCount: Int
    let rejectedFrameCount: Int
    let percentExcellent: Double
    let predictedSplatQuality: String
    let estimatedCaptureQuality: String
    let estimatedCOLMAPReadiness: String
    let recommendation: String
}

struct CaptureMetricStats: Encodable {
    let average: Double?
    let minimum: Double?
    let maximum: Double?
    let sampleCount: Int

    init(values: [Double]) {
        let finiteValues = values.filter(\.isFinite)
        average = finiteValues.average
        minimum = finiteValues.min()
        maximum = finiteValues.max()
        sampleCount = finiteValues.count
    }
}

struct CaptureSettings: Encodable {
    let minimumSaveInterval: TimeInterval
    let blurThreshold: Double
    let maxRotationRate: Double
    let maxAcceleration: Double
    let minimumRotationChangeRadians: Double
    let minimumOverlapViewChangeScore: Double
    let jpegQuality: Double
}

struct CaptureFrameEvent: Encodable {
    let frameNumber: Int
    let timestamp: Date
    let saved: Bool
    let saveReason: String?
    let rejectReason: String?
    let orientation: String
    let blurScore: Double?
    let motionMagnitude: Double
    let distanceMoved: Double?
    let estimatedTranslationAvailable: Bool
    let estimatedTranslationDistance: Double?
    let estimatedTranslationVelocity: Double?
    let translationMethod: String
    let rotationDelta: Double?
    let viewChangeScore: Double?
    let timeSinceLastSaved: Double?
    let exposureScore: Double?
    let textureRichnessScore: Double?
    let frameQualityTier: String
    let splatQualityScore: Int
    let rejectionReason: String?
    let qualityReason: String
    let scanHealth: String
}

struct CaptureMotionDiagnostic: Encodable {
    let frameNumber: Int
    let timestamp: Date
    let outcome: String
    let orientation: String
    let estimatedTranslationAvailable: Bool
    let estimatedTranslationDistance: Double?
    let estimatedTranslationVelocity: Double?
    let translationMethod: String
    let rotationDelta: Double?
    let viewChangeScore: Double?
    let timeSinceLastSaved: Double?
    let motionMagnitude: Double?
    let blurScore: Double?
    let exposureScore: Double?
    let textureRichnessScore: Double?
    let frameQualityTier: String
    let splatQualityScore: Int
    let rejectionReason: String?
    let qualityReason: String
    let scanHealth: String
}

struct WorkingScanState: Encodable {
    let savedImagePaths: [String]
    let framesSeen: Int
    let framesSaved: Int
    let framesRejected: Int
    let scanConfidenceScore: Int
    let currentScanHealth: String
    let scanHealthReason: String
    let healthDecisionInputs: String
    let finalActiveScanHealth: String
    let dominantScanHealth: String
    let dominantScanHealthPercent: Double
    let lastSavedFramePath: String?
    let exportedAt: Date?
}

private extension AVCaptureConnection {
    func setOrientationIfSupported(_ orientation: AVCaptureVideoOrientation) {
        guard isVideoOrientationSupported else { return }
        videoOrientation = orientation
    }
}

extension AVCaptureVideoOrientation {
    init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .portraitUpsideDown:
            self = .portraitUpsideDown
        case .landscapeLeft:
            self = .landscapeRight
        case .landscapeRight:
            self = .landscapeLeft
        default:
            return nil
        }
    }

    var displayName: String {
        switch self {
        case .portrait:
            "Portrait"
        case .portraitUpsideDown:
            "Portrait Upside Down"
        case .landscapeLeft:
            "Landscape Left"
        case .landscapeRight:
            "Landscape Right"
        @unknown default:
            "Unknown"
        }
    }

    var portraitImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait:
            .right
        case .portraitUpsideDown:
            .left
        case .landscapeLeft, .landscapeRight:
            .right
        @unknown default:
            .right
        }
    }

    var landscapeImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .landscapeLeft:
            .down
        case .landscapeRight:
            .up
        case .portrait, .portraitUpsideDown:
            .up
        @unknown default:
            .up
        }
    }

    var isLandscape: Bool {
        self == .landscapeLeft || self == .landscapeRight
    }
}

private extension CMAttitude {
    func angularDifference(from previous: CMAttitude) -> Double {
        let dotProduct = (quaternion.w * previous.quaternion.w) +
            (quaternion.x * previous.quaternion.x) +
            (quaternion.y * previous.quaternion.y) +
            (quaternion.z * previous.quaternion.z)
        let clampedDotProduct = min(max(abs(dotProduct), -1.0), 1.0)
        return 2.0 * acos(clampedDotProduct)
    }
}

private extension Bundle {
    var appVersionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

private extension UIDevice {
    var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
    }
}

private extension Array where Element == Double {
    var average: Double? {
        let finiteValues = filter(\.isFinite)
        guard !finiteValues.isEmpty else { return nil }
        return finiteValues.reduce(0, +) / Double(finiteValues.count)
    }
}

private extension Double {
    var finiteOrNil: Double? {
        isFinite ? self : nil
    }
}

private extension String {
    var diagnosticSlug: String {
        lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" {
                    return
                }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

private func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension CaptureFrameEvent {
    var jsonSafe: CaptureFrameEvent {
        CaptureFrameEvent(
            frameNumber: frameNumber,
            timestamp: timestamp,
            saved: saved,
            saveReason: saveReason,
            rejectReason: rejectReason,
            orientation: orientation,
            blurScore: blurScore?.finiteOrNil,
            motionMagnitude: motionMagnitude.isFinite ? motionMagnitude : 0,
            distanceMoved: distanceMoved?.finiteOrNil,
            estimatedTranslationAvailable: estimatedTranslationAvailable,
            estimatedTranslationDistance: estimatedTranslationDistance?.finiteOrNil,
            estimatedTranslationVelocity: estimatedTranslationVelocity?.finiteOrNil,
            translationMethod: translationMethod,
            rotationDelta: rotationDelta?.finiteOrNil,
            viewChangeScore: viewChangeScore?.finiteOrNil,
            timeSinceLastSaved: timeSinceLastSaved?.finiteOrNil,
            exposureScore: exposureScore?.finiteOrNil,
            textureRichnessScore: textureRichnessScore?.finiteOrNil,
            frameQualityTier: frameQualityTier,
            splatQualityScore: splatQualityScore,
            rejectionReason: rejectionReason,
            qualityReason: qualityReason,
            scanHealth: scanHealth
        )
    }
}

private extension CaptureMotionDiagnostic {
    var jsonSafe: CaptureMotionDiagnostic {
        CaptureMotionDiagnostic(
            frameNumber: frameNumber,
            timestamp: timestamp,
            outcome: outcome,
            orientation: orientation,
            estimatedTranslationAvailable: estimatedTranslationAvailable,
            estimatedTranslationDistance: estimatedTranslationDistance?.finiteOrNil,
            estimatedTranslationVelocity: estimatedTranslationVelocity?.finiteOrNil,
            translationMethod: translationMethod,
            rotationDelta: rotationDelta?.finiteOrNil,
            viewChangeScore: viewChangeScore?.finiteOrNil,
            timeSinceLastSaved: timeSinceLastSaved?.finiteOrNil,
            motionMagnitude: motionMagnitude?.finiteOrNil,
            blurScore: blurScore?.finiteOrNil,
            exposureScore: exposureScore?.finiteOrNil,
            textureRichnessScore: textureRichnessScore?.finiteOrNil,
            frameQualityTier: frameQualityTier,
            splatQualityScore: splatQualityScore,
            rejectionReason: rejectionReason,
            qualityReason: qualityReason,
            scanHealth: scanHealth
        )
    }
}

extension CameraCaptureController: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Task { @MainActor in
            self.handle(sampleBuffer)
        }
    }
}
