import SwiftUI

/// A key combination drawn as separate caps: ⇧ ⌘ 2. Reads faster than "⇧⌘2" run together, and it
/// is how the recorder draws the same combination.
struct KeyCaps: View {
    let caps: [String]
    var tint: Color?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.callout.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(minWidth: 24)
                    .background(.quaternary, in: .rect(cornerRadius: Tokens.Radius.keyCap))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: Tokens.Radius.keyCap)
                                .strokeBorder(tint, lineWidth: 1)
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined())
    }
}
