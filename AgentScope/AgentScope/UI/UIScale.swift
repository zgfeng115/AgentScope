import AppKit
import SwiftUI

/// One knob for window and control sizes. Fonts and icon sizes deliberately do not use it.
enum UIScale {
    static let factor: CGFloat = 2

    static func size(_ value: CGFloat) -> CGFloat { value * factor }

    /// Scaled window size, clamped so the window still fits the current screen.
    static func windowSize(width: CGFloat, height: CGFloat) -> CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: width * factor, height: height * factor)
        return CGSize(width: min(width * factor, visible.width), height: min(height * factor, visible.height))
    }
}
