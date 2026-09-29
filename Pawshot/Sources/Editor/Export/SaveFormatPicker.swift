import SwiftUI

/// The format row under Save As…'s file browser. It tells the panel each change, so the name's
/// extension follows the pick.
struct SaveFormatPicker: View {
    let onChange: (ImageFormat) -> Void
    @State private var format: ImageFormat

    init(initial: ImageFormat, onChange: @escaping (ImageFormat) -> Void) {
        _format = State(initialValue: initial)
        self.onChange = onChange
    }

    var body: some View {
        Picker("Format:", selection: $format) {
            ForEach(ImageFormat.allCases, id: \.self) { format in
                Text(verbatim: format.name).tag(format)
            }
        }
        .fixedSize()
        .padding(12)
        .onChange(of: format) { _, format in onChange(format) }
    }
}
