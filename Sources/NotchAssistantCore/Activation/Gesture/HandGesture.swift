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

    /// Wrist to middle knuckle, as a fraction of the frame: how close the
    /// hand is to the camera.
    var size: CGFloat {
        guard fingers.count > 1 else { return 0 }
        return hypot(fingers[1].mcp.x - wrist.x, fingers[1].mcp.y - wrist.y)
    }

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
/// frames, close to the camera and still, then waits out a cooldown. A
/// passing wave, a stretch, or someone in the background doesn't start
/// listening (spec §6's confirmation requirement).
struct GestureDebouncer {
    public static let holdKey = "gesture.hold"
    /// Frames in a row: 5 at 10 fps is half a second (a setting: 5 or 10).
    var framesRequired = UserDefaults.standard.object(forKey: GestureDebouncer.holdKey) as? Int ?? 5
    var cooldown: TimeInterval = 3
    /// Wrist to middle knuckle, as a fraction of the frame: closer than an
    /// arm's length. Hands further away (people behind you) are ignored.
    var minimumSize: CGFloat = 0.07
    /// How far the wrist may drift during the hold: a wave moves more.
    var maximumDrift: CGFloat = 0.06

    private var candidate: HandGesture?
    private var count = 0
    private var anchor: CGPoint?
    private var lastFired = Date.distantPast

    mutating func feed(_ gesture: HandGesture?, at now: Date) -> HandGesture? {
        feed(gesture, wrist: nil, size: .infinity, at: now)
    }

    mutating func feed(_ gesture: HandGesture?, wrist: CGPoint?, size: CGFloat, at now: Date) -> HandGesture? {
        guard let gesture, size >= minimumSize, now.timeIntervalSince(lastFired) >= cooldown else {
            reset()
            return nil
        }
        if gesture == candidate, let anchor, let wrist, hypot(wrist.x - anchor.x, wrist.y - anchor.y) > maximumDrift {
            // Moving: start the hold again from here.
            reset()
        }
        if gesture == candidate {
            count += 1
        } else {
            candidate = gesture
            count = 1
            anchor = wrist
        }
        guard count >= framesRequired else { return nil }
        reset()
        lastFired = now
        return gesture
    }

    private mutating func reset() {
        candidate = nil
        count = 0
        anchor = nil
    }
}
