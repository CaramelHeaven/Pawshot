import AppKit

/// Keeps the shot centred while it is smaller than the window. In that case the stock
/// `NSClipView` pins the content to the top left corner and the picture hangs in a corner of a
/// grey field.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: CGRect) -> CGRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }

        let content = documentView.frame

        if content.width < rect.width {
            rect.origin.x = (content.width - rect.width) / 2
        }
        if content.height < rect.height {
            rect.origin.y = (content.height - rect.height) / 2
        }

        return rect
    }
}
