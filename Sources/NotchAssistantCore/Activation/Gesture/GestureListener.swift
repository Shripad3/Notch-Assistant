@preconcurrency import AVFoundation
import Vision

/// Watches the front camera for the two hand gestures (spec §6). The most
/// expensive component, so it is off by default and paused on battery.
/// Frames are capped at 10 per second at 640×480 and processed on a
/// low-priority queue; nothing is recorded or stored.
public final class GestureListener: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: `session`, `debouncer` and `lastFrame` are only touched on
    // `queue`.
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.shripad.NotchAssistant.gesture", qos: .utility)
    private var debouncer = GestureDebouncer()
    private var lastFrame = Date.distantPast
    private let onGesture: @Sendable (HandGesture) -> Void
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()

    public init(onGesture: @escaping @Sendable (HandGesture) -> Void) {
        self.onGesture = onGesture
    }

    public func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw AssistantFailure("Camera access is off for Notch Assistant", link: .camera)
        }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device else { throw ToolError("There's no camera") }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [session] in
                session.beginConfiguration()
                session.sessionPreset = .vga640x480
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    continuation.resume(throwing: ToolError("The camera is busy"))
                    return
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                session.startRunning()
                continuation.resume()
            }
        }
        Log.app.notice("gestures: watching")
    }

    public func stop() {
        queue.async { [session] in
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        // 10 frames a second is plenty for a held gesture.
        guard now.timeIntervalSince(lastFrame) >= 0.1 else { return }
        lastFrame = now
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
        try? handler.perform([request])
        let joints = request.results?.first.flatMap(Self.joints)
        if let gesture = debouncer.feed(joints?.gesture(), at: now) {
            Log.app.notice("gestures: \(String(describing: gesture), privacy: .public)")
            onGesture(gesture)
        }
    }

    private static func joints(_ observation: VNHumanHandPoseObservation) -> HandJoints? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        func point(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
            guard let p = points[name], p.confidence > 0.5 else { return nil }
            return p.location
        }
        let names: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
            (.indexTip, .indexPIP, .indexMCP), (.middleTip, .middlePIP, .middleMCP),
            (.ringTip, .ringPIP, .ringMCP), (.littleTip, .littlePIP, .littleMCP),
        ]
        guard let wrist = point(.wrist) else { return nil }
        var fingers: [HandJoints.Finger] = []
        for (tip, pip, mcp) in names {
            guard let t = point(tip), let p = point(pip), let m = point(mcp) else { return nil }
            fingers.append(.init(tip: t, pip: p, mcp: m))
        }
        return HandJoints(wrist: wrist, fingers: fingers)
    }
}
