import AppKit
import CoreText

/// The typeface labels are set in: the system's, or any family installed on the Mac, picked in
/// Settings. One family for every label in every open editor — changing it re-sets what is
/// already drawn, the owner's call — while each label keeps its own size and weight.
@MainActor
enum LabelFont {
    /// `nil` is the system font. Settings writes it; nothing else does.
    static var family: String?

    /// The system font's weights, lightest first — all nine of SF's.
    static let systemWeights: [NSFont.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]

    /// The upright weights a family has, lightest first: one button each in the editor. Italics
    /// are left out, and so are two faces of the same weight.
    static func weights(of family: String?) -> [NSFont.Weight] {
        guard let family else { return systemWeights }
        return faces(of: family).map(\.weight)
    }

    static func font(size: CGFloat, weight: NSFont.Weight, family: String? = LabelFont.family) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: nearest(weight, in: systemWeights))
        guard let family else { return system }

        let faces = faces(of: family)
        guard let face = faces.min(by: { abs($0.weight.rawValue - weight.rawValue) < abs($1.weight.rawValue - weight.rawValue) })
        else { return system }
        return NSFont(name: face.postScriptName, size: size) ?? system
    }

    /// The weight next to `weight` in the family, for ⇧[ and ⇧].
    static func weight(after weight: NSFont.Weight, by step: Int, family: String? = LabelFont.family) -> NSFont.Weight {
        let all = weights(of: family)
        guard !all.isEmpty else { return weight }
        let current = all.firstIndex(of: nearest(weight, in: all)) ?? 0
        return all[min(max(current + step, 0), all.count - 1)]
    }

    static func nearest(_ weight: NSFont.Weight, in weights: [NSFont.Weight]) -> NSFont.Weight {
        weights.min(by: { abs($0.rawValue - weight.rawValue) < abs($1.rawValue - weight.rawValue) }) ?? weight
    }

    /// What a weight is called, for the button's tooltip.
    static func name(of weight: NSFont.Weight, family: String? = LabelFont.family) -> String {
        if let family, let face = faces(of: family).first(where: { $0.weight == weight }) {
            return face.styleName
        }
        let names: [NSFont.Weight: String] = [
            .ultraLight: "UltraLight", .thin: "Thin", .light: "Light", .regular: "Regular", .medium: "Medium",
            .semibold: "Semibold", .bold: "Bold", .heavy: "Heavy", .black: "Black",
        ]
        return names[weight] ?? ""
    }

    // MARK: - Faces

    private struct Face {
        let postScriptName: String
        let styleName: String
        let weight: NSFont.Weight
    }

    private static var cache: [String: [Face]] = [:]

    /// `availableMembers` answers `[PostScript name, style name, weight 1…14, traits]`. The weight
    /// that matters is the font's own `kCTFontWeightTrait` (-1…1), the same scale `NSFont.Weight`
    /// uses, so the system font and any family share one set of steps.
    private static func faces(of family: String) -> [Face] {
        if let cached = cache[family] {
            return cached
        }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        var faces: [Face] = []
        for member in members {
            guard
                member.count >= 4,
                let postScriptName = member[0] as? String,
                let styleName = member[1] as? String,
                let traits = (member[3] as? NSNumber)?.uintValue,
                traits & NSFontTraitMask.italicFontMask.rawValue == 0,
                let font = NSFont(name: postScriptName, size: 12)
            else { continue }

            let fontTraits = CTFontCopyTraits(font) as NSDictionary
            let weight = (fontTraits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let rounded = NSFont.Weight((weight * 100).rounded() / 100)
            guard !faces.contains(where: { $0.weight == rounded }) else { continue }
            faces.append(Face(postScriptName: postScriptName, styleName: styleName, weight: rounded))
        }
        faces.sort { $0.weight.rawValue < $1.weight.rawValue }
        cache[family] = faces
        return faces
    }
}
