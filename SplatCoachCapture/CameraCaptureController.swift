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
    @Published private(set) var lastViewChangeScore = 0.0
    @Published private(set) var lastRotationChangeRadians = 0.0
    @Published private(set) var lastSavedJPGOrientation = "None"
    @Published private(set) var captureFPS = 0.0
    @Published private(set) var savedForOverlapCount = 0
    @Published private(set) var savedNewAngleCount = 0
    @Published private(set) var rejectedBlurryCount = 0
    @Published private(set) var rejectedMotionCount = 0
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgressText: String?
    @Published private(set) var exportErrorMessage: String?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.splatcoach.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.splatcoach.capture.samples", qos: .userInitiated)
    private let motionManager = CMMotionManager()

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
    private var savedIntervals: [TimeInterval] = []
    private var lastSavedFrameNumber: Int?

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
        outputDirectory = makeOutputDirectory(capturedAt: startedAt)
        savedFrameCount = 0
        savedImageURLs = []
        framesSeen = 0
        framesRejected = 0
        lastBlurScore = nil
        lastDistanceMovedMeters = 0
        lastMotionScore = 0
        lastViewChangeScore = 0
        lastRotationChangeRadians = 0
        lastSavedJPGOrientation = "None"
        captureFPS = 0
        savedForOverlapCount = 0
        savedNewAngleCount = 0
        rejectedBlurryCount = 0
        rejectedMotionCount = 0
        frameIndex = 0
        lastSavedAt = .distantPast
        lastSavedFrameNumber = nil
        lastSavedSignature = nil
        lastSavedAttitude = nil
        frameEvents = []
        savedIntervals = []
        scanStartedAt = startedAt
        scanEndedAt = nil
        fpsWindowStartedAt = startedAt
        fpsWindowFrameCount = 0
        isScanning = true
        statusText = "Scanning"
        lastSaveReason = "None"
        lastRejectReason = "None"
        timeSinceLastSaveText = "--"
        startMotionUpdates()
        updateCaptureOrientation()
    }

    func stopScan() {
        isScanning = false
        scanEndedAt = Date()
        statusText = "Ready"
        motionManager.stopDeviceMotionUpdates()
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
        guard !savedImageURLs.isEmpty else {
            exportErrorMessage = "No saved frames are available to export."
            return nil
        }

        isExporting = true
        exportErrorMessage = nil
        exportProgressText = "Preparing export"

        let scanName = outputDirectory?.lastPathComponent ?? "splatcoach-scan"
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
            try await Task.detached(priority: .userInitiated) { [weak self] in
                try ZipArchiveWriter.write(
                    fileEntries: imageEntries,
                    dataEntries: [
                        ZipDataEntry(path: "capture_report.json", data: reportData)
                    ],
                    to: archiveURL
                ) { completed, total in
                    Task { @MainActor in
                        self?.exportProgressText = "Zipping \(completed) / \(total)"
                    }
                }
            }.value

            exportProgressText = "Opening share sheet"
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
            return MotionSample(isAcceptable: true, status: "OK", attitude: nil, rotationDelta: .infinity, magnitude: 0)
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
            magnitude: max(rotationMagnitude, accelerationMagnitude)
        )
    }

    private func makeOutputDirectory(capturedAt: Date) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = documents
            .appendingPathComponent("SplatCoachCapture", isDirectory: true)
            .appendingPathComponent("scan-\(formatter.string(from: capturedAt))", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            statusText = "Save folder unavailable"
            lastRejectReason = "Save folder unavailable"
            return nil
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

        let frameNumber = framesSeen
        let motion = currentMotionSample()
        motionStatus = motion.status
        lastMotionScore = motion.magnitude

        let poseChange = currentPoseChange(fallbackRotationDelta: motion.rotationDelta)
        lastDistanceMovedMeters = poseChange.distance
        lastRotationChangeRadians = poseChange.rotation

        let elapsed = now.timeIntervalSince(lastSavedAt)
        guard elapsed >= CaptureTuning.minimumSaveInterval else {
            return
        }

        guard motion.isAcceptable else {
            statusText = "Move slower"
            rejectedMotionCount += 1
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: "Move slower",
                orientation: captureOrientation,
                blurScore: nil,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil
            )
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: "Frame unavailable",
                orientation: captureOrientation,
                blurScore: nil,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil
            )
            return
        }

        let blurScore = Self.blurScore(for: pixelBuffer)
        lastBlurScore = blurScore
        let blurPasses = blurScore.map { $0 >= CaptureTuning.blurThreshold } ?? true
        guard blurPasses else {
            statusText = "Too blurry"
            rejectedBlurryCount += 1
            rejectFrame(
                number: frameNumber,
                timestamp: now,
                reason: "Too blurry",
                orientation: captureOrientation,
                blurScore: blurScore,
                motion: motion,
                poseChange: poseChange,
                viewChangeScore: nil
            )
            return
        }

        let signature = Self.lumaSignature(for: pixelBuffer)
        let viewChangeScore = Self.viewChangeScore(previous: lastSavedSignature, current: signature)
        lastViewChangeScore = viewChangeScore.isFinite ? viewChangeScore : 0

        let isFirstSave = lastSavedSignature == nil
        let rotatedEnough = poseChange.rotation >= CaptureTuning.minimumRotationChangeRadians
        let viewChangedEnough = viewChangeScore.isInfinite ||
            viewChangeScore >= CaptureTuning.minimumOverlapViewChangeScore

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
            reason: saveReason(
                isFirstSave: isFirstSave,
                rotatedEnough: rotatedEnough,
                viewChangedEnough: viewChangedEnough
            )
        )
    }

    private func currentPoseChange(fallbackRotationDelta: Double) -> PoseChange {
        return PoseChange(
            distance: 0,
            rotation: fallbackRotationDelta.isFinite ? fallbackRotationDelta : 0
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
        viewChangeScore: Double?
    ) {
        framesRejected += 1
        lastRejectReason = reason
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
                rotationDelta: poseChange.rotation.finiteOrNil,
                viewChangeScore: viewChangeScore?.finiteOrNil
            )
        )
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
        reason: String
    ) {
        guard let outputDirectory else { return }

        if lastSavedAt != .distantPast {
            savedIntervals.append(capturedAt.timeIntervalSince(lastSavedAt))
        }

        lastSavedAt = capturedAt
        lastSavedFrameNumber = frameNumber
        lastSavedSignature = signature
        lastSavedAttitude = attitude
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
                    self.lastSavedJPGOrientation = "\(orientation.displayName) \(result.width)x\(result.height)"
                    self.statusText = reason == "Saved for rotation" ? "Good new angle" : "Good frame"
                    self.lastSaveReason = reason
                    self.updateElapsedTime(capturedAt)
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
                            rotationDelta: poseChange.rotation.finiteOrNil,
                            viewChangeScore: viewChangeScore.finiteOrNil
                        )
                    )
                }
            } catch {
                await MainActor.run {
                    self.rejectFrame(
                        number: frameNumber,
                        timestamp: capturedAt,
                        reason: "Save failed",
                        orientation: orientation,
                        blurScore: blurScore,
                        motion: motion,
                        poseChange: poseChange,
                        viewChangeScore: viewChangeScore
                    )
                    self.statusText = "Save failed"
                }
            }
        }
    }

    private func appendFrameEvent(_ event: CaptureFrameEvent) {
        frameEvents.append(event)
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

    private func makeCaptureReportData() throws -> Data {
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
            perFrame: frameEvents.map(\.jsonSafe)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
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
}

private struct PoseChange {
    let distance: Double
    let rotation: Double
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
    let perFrame: [CaptureFrameEvent]
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
    let rotationDelta: Double?
    let viewChangeScore: Double?
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
            rotationDelta: rotationDelta?.finiteOrNil,
            viewChangeScore: viewChangeScore?.finiteOrNil
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
