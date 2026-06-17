import CPrivateDisplay

/// Live scaling of the system mouse cursor via the private CGSSetCursorScale API. Because it
/// scales the real hardware cursor, ScreenCaptureKit captures the enlarged cursor into the
/// glasses too — used to make the pointer easy to spot while "find my cursor" mode is open.
public enum CursorScale {
    /// Current scale (1.0 = normal; accessibility max ≈ 4.0).
    public static var current: Float { VRDGetCursorScale() }

    /// Set the cursor scale. The cursor redraws at the new size on its next move.
    public static func set(_ scale: Float) { VRDSetCursorScale(scale) }
}
