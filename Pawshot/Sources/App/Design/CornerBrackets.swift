import SwiftUI

/// The frame corners of the app icon as a SwiftUI shape. The geometry lives in
/// `SelectionGeometry.cornerBrackets`, so the overlay and the windows draw the same corners.
struct CornerBrackets: Shape {
    var armLength: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for bracket in SelectionGeometry.cornerBrackets(for: rect, armLength: armLength) {
            path.addLines(bracket)
        }
        return path
    }
}

extension CornerBrackets {
    /// How every bracket in the app is stroked: round ends, so the corner reads as the icon's and
    /// not as a crop mark.
    func bracketStroke(_ color: Color = .primary, width: CGFloat = 3) -> some View {
        stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
