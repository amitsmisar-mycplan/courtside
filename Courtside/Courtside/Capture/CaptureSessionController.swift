import AVFoundation
import OSLog
import QuartzCore

/// The only thing that touches `AVCaptureSession`. Records with `AVCaptureMovieFileOutput`
/// (not `AVAssetWriter` — far fewer ways to lose a game).
///
/// Session work runs on a private serial queue; recording state shared with the delegate
/// callbacks is guarded by `lock`.
final class CaptureSessionController: NSObject, RecordingService, CameraPreviewSource, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private static let log = Logger(subsystem: "Courtside", category: "Capture")
    /// Continuous autofocus hunts every time a player crosses the frame, so focus and
    /// exposure lock after this settle.
    private static let settleSeconds: Double = 3

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "courtside.capture.session")
    private let lock = NSLock()

    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    /// Bumped on every lens switch, so a focus lock scheduled for the old lens is skipped.
    private var settleGeneration = 0

    // Guarded by `lock`.
    private var startedAt: CFTimeInterval?
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var stopContinuation: CheckedContinuation<(url: URL, duration: Double), Error>?
    private var currentLens: CameraLens?
    private var currentDevice: AVCaptureDevice?
    private var foundLenses: [CameraLens] = []

    // Main thread only.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    var onUnexpectedFinish: (@MainActor (URL, Double) -> Void)?

    var lens: CameraLens? { lock.withLock { currentLens } }
    var availableLenses: [CameraLens] { lock.withLock { foundLenses } }

    // MARK: Lenses

    /// Lenses for the back cameras found, widest first. Separate from discovery so it can be tested
    /// without a camera.
    static func lenses(forDeviceTypes types: [AVCaptureDevice.DeviceType]) -> [CameraLens] {
        CameraLens.allCases.filter { types.contains(deviceType(for: $0)) }
    }

    static func deviceType(for lens: CameraLens) -> AVCaptureDevice.DeviceType {
        switch lens {
        case .ultraWide: .builtInUltraWideCamera
        case .wide: .builtInWideAngleCamera
        }
    }

    private static func backCamera(for lens: CameraLens) -> AVCaptureDevice? {
        AVCaptureDevice.default(deviceType(for: lens), for: .video, position: .back)
    }

    private static func discoverLenses() -> [CameraLens] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: CameraLens.allCases.map(deviceType(for:)), mediaType: .video, position: .back
        )
        return lenses(forDeviceTypes: discovery.devices.map(\.deviceType))
    }

    // MARK: Set-up

    func prepare(preferredLens: CameraLens?) async throws {
        let found = Self.discoverLenses()
        guard let chosen = LensSettings.choose(saved: preferredLens, available: found) else {
            throw RecordingError.noCamera
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw RecordingError.cameraDenied }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RecordingError.microphoneDenied }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    if !self.configured {
                        try self.configure(lens: chosen)
                        self.configured = true
                        self.lock.withLock { self.foundLenses = found }
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    self.lockFocusAfterSettle()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 1920×1080, 60 fps if the lens can, HEVC, the chosen back lens at its own 1× (so the ultra-wide
    /// stays 0.5×), audio on, stabilization off (tripod-mounted; stabilization only costs thermal
    /// headroom). Geometric distortion correction is left at the system default.
    private func configure(lens: CameraLens) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        try addVideoInput(for: lens)

        if let microphone = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: microphone),
           session.canAddInput(audioInput) {
            session.addInput(audioInput)
        } else {
            Self.log.error("No microphone input; recording without audio")
        }

        guard session.canAddOutput(movieOutput) else { throw RecordingError.configurationFailed("movie output") }
        session.addOutput(movieOutput)
        // Must stay invalid, or long games silently truncate.
        movieOutput.maxRecordedDuration = .invalid

        applyRecordingSettings()
    }

    /// Adds the camera for `lens` and sets its format. Call inside a configuration block.
    private func addVideoInput(for lens: CameraLens) throws {
        guard let device = Self.backCamera(for: lens) else { throw RecordingError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RecordingError.configurationFailed("camera input") }
        session.addInput(input)
        try configureFormat(of: device, lens: lens)
        videoInput = input
        videoDevice = device
        lock.withLock {
            currentLens = lens
            currentDevice = device
        }
    }

    private func configureFormat(of device: AVCaptureDevice, lens: CameraLens) throws {
        try device.lockForConfiguration()
        if let best = Self.bestFormat(for: device) {
            device.activeFormat = best.format
            let frameDuration = CMTime(value: 1, timescale: best.fps)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            Self.log.info("Recording format 1920x1080 @ \(best.fps) fps on the \(lens.label) lens")
        } else {
            Self.log.error("No 1080p format on the \(lens.label) lens; using the camera's default")
        }
        device.videoZoomFactor = 1.0
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()
    }

    /// HEVC and no stabilization on the movie output's video connection, which is rebuilt when the
    /// camera input changes.
    private func applyRecordingSettings() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
    }

    func selectLens(_ lens: CameraLens) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.switchLens(to: lens)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        await MainActor.run { observeRotation() }
    }

    /// Swaps the camera input. Never while recording; on failure the previous lens is put back.
    private func switchLens(to lens: CameraLens) throws {
        guard !movieOutput.isRecording else { throw RecordingError.lensLocked }
        guard configured, lens != self.lens else { return }
        guard let oldInput = videoInput, let oldLens = self.lens else { throw RecordingError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.removeInput(oldInput)
        do {
            try addVideoInput(for: lens)
        } catch {
            if session.canAddInput(oldInput) { session.addInput(oldInput) }
            videoInput = oldInput
            videoDevice = oldInput.device
            lock.withLock {
                currentLens = oldLens
                currentDevice = oldInput.device
            }
            applyRecordingSettings()
            throw error
        }
        applyRecordingSettings()
        settleGeneration += 1
        lockFocusAfterSettle()
    }

    /// 1080p at 60 fps, falling back to 1080p at 30 fps.
    static func bestFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, fps: Int32)? {
        let fullHD = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width == 1920 && size.height == 1080
        }
        for fps in [60, 30] {
            if let format = fullHD.first(where: { $0.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= Double(fps) } }) {
                return (format, Int32(fps))
            }
        }
        return nil
    }

    // MARK: Focus

    private func lockFocusAfterSettle() {
        let generation = settleGeneration
        sessionQueue.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
            guard let self, generation == self.settleGeneration,
                  let device = self.videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
            device.unlockForConfiguration()
        }
    }

    func refocus() {
        sessionQueue.async {
            guard let device = self.videoDevice, (try? device.lockForConfiguration()) != nil else { return }
            let centre = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
            if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
            self.lockFocusAfterSettle()
        }
    }

    // MARK: Preview

    @MainActor func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        previewLayer = layer
        observeRotation()
    }

    /// Keeps the preview level for the current lens; rebuilt after a lens switch.
    @MainActor private func observeRotation() {
        guard let layer = previewLayer,
              let device = lock.withLock({ currentDevice }) ?? lens.flatMap(Self.backCamera(for:)) else { return }
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.applyPreviewRotation(angle) }
            }
        }
    }

    @MainActor private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    // MARK: Recording

    func startRecording() async throws -> URL {
        let filename = StorageManager.makeGameVideoFilename(id: UUID(), fileExtension: "mov")
        // Final name from the first byte, never a `.partial` name: the launch sweep deletes
        // partials, and an interrupted recording must survive for recovery.
        let url = StorageManager.gameVideoURL(filename: filename)
        let captureAngle = await MainActor.run { rotationCoordinator?.videoRotationAngleForHorizonLevelCapture }

        return try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard !self.movieOutput.isRecording else {
                    continuation.resume(throwing: RecordingError.alreadyRecording)
                    return
                }
                if let captureAngle, let connection = self.movieOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(captureAngle) {
                    connection.videoRotationAngle = captureAngle
                }
                self.lock.withLock {
                    self.startedAt = nil
                    self.startContinuation = continuation
                }
                self.movieOutput.startRecording(to: url, recordingDelegate: self)
            }
        }
    }

    func stopRecording() async throws -> (url: URL, duration: Double) {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                guard self.movieOutput.isRecording else {
                    continuation.resume(throwing: RecordingError.notRecording)
                    return
                }
                self.lock.withLock { self.stopContinuation = continuation }
                self.movieOutput.stopRecording()
            }
        }
    }

    func mark() -> Double {
        guard let startedAt = lock.withLock({ startedAt }) else { return 0 }
        return max(0, CACurrentMediaTime() - startedAt)
    }

    func shutdown() {
        sessionQueue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let continuation = lock.withLock {
            startedAt = CACurrentMediaTime()
            defer { startContinuation = nil }
            return startContinuation
        }
        continuation?.resume(returning: fileURL)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let duration = output.recordedDuration.seconds
        let (pendingStart, pendingStop) = lock.withLock {
            defer {
                startContinuation = nil
                stopContinuation = nil
                startedAt = nil
            }
            return (startContinuation, stopContinuation)
        }
        if let error {
            let finishedAnyway = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
            Self.log.error("Recording finished with error (file kept: \(finishedAnyway)): \(error.localizedDescription)")
        }

        if let pendingStart {
            pendingStart.resume(throwing: RecordingError.startFailed(error))
            return
        }
        // Even after an error, whatever reached disk is kept and saved as a game.
        if let pendingStop {
            pendingStop.resume(returning: (outputFileURL, duration))
            return
        }
        let handler = onUnexpectedFinish
        Task { @MainActor in handler?(outputFileURL, duration) }
    }
}
