import CoreGraphics
import Foundation

/// The two gestures (spec §6): an open palm starts listening, a fist
/// cancels, like Escape.
public enum HandGesture: Sendable, Equatable {
    case openPalm
    case fist
}

/// A hand's joints in image coordinates, from Vision's hand pose.
struct HandJoints: Sendable {
    struct Finger: Sendable {
        let tip: CGPoint
        let pip: CGPoint
        let mcp: CGPoint
    }

    let wrist: CGPoint
    /// Index, middle, ring and little fingers; the thumb is too ambiguous.
    let fingers: [Finger]

    /// Open palm: every finger straight out from the wrist. Fist: every
    /// fingertip folded back nearer the wrist than its middle joint.
    func gesture() -> HandGesture? {
        guard fingers.count == 4 else { return nil }
        let extended = fingers.allSatisfy { finger in
            let tip = distance(finger.tip, wrist)
            return tip > distance(finger.pip, wrist) * 1.1 && tip > distance(finger.mcp, wrist) * 1.35
        }
        if extended { return .openPalm }
        let curled = fingers.allSatisfy { distance($0.tip, wrist) < distance($0.pip, wrist) }
        return curled ? .fist : nil
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Fires a gesture only once it has been held for several consecutive
/// frames, then waits out a cooldown, so a passing wave or a stretch
/// doesn't start listening (spec §6's confirmation requirement).
struct GestureDebouncer {
    /// Frames in a row: 5 at 10 fps is half a second.
    var framesRequired = 5
    var cooldown: TimeInterval = 3

    private var candidate: HandGesture?
    private var count = 0
    private var lastFired = Date.distantPast

    mutating func feed(_ gesture: HandGesture?, at now: Date) -> HandGesture? {
        guard let gesture, now.timeIntervalSince(lastFired) >= cooldown else {
            candidate = nil
            count = 0
            return nil
        }
        if gesture == candidate {
            count += 1
        } else {
            candidate = gesture
            count = 1
        }
        guard count >= framesRequired else { return nil }
        candidate = nil
        count = 0
        lastFired = now
        return gesture
    }
}
