import SwiftUI
import RawViewCore

/// A filename split into segments for the tester. Each matched token is a tinted segment
/// with its token name under it. Literal text between tokens stays plain.
public struct GrammarTokenSegmentsView: View {
    public let pieces: [FilenamePiece]
    public let fields: [GrammarField]
    public var uiFontSize: Double = AppTypography.baselineFontSize
    public var fontFamily: String = "System"

    public init(
        pieces: [FilenamePiece],
        fields: [GrammarField],
        uiFontSize: Double = AppTypography.baselineFontSize,
        fontFamily: String = "System"
    ) {
        self.pieces = pieces
        self.fields = fields
        self.uiFontSize = uiFontSize
        self.fontFamily = fontFamily
    }

    public var body: some View {
        AppFlowLayout(horizontalSpacing: 2, verticalSpacing: 8) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                pieceView(piece)
            }
        }
    }

    @ViewBuilder
    private func pieceView(_ piece: FilenamePiece) -> some View {
        if let name = piece.tokenName {
            let field = fields.first(where: { $0.name == name })
            let family = GrammarTokenFamily(role: field?.role, type: field?.type)
            VStack(alignment: .leading, spacing: 2) {
                Text(piece.text)
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(family.tint.opacity(0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(family.tint.opacity(0.6), lineWidth: 0.75))
                Text(name)
                    .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name): \(piece.text)")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(piece.text)
                    .font(AppTypography.tokenCode(uiFontSize: uiFontSize))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                // Keeps literal text on the same baseline as token values, which have a label below.
                Text(" ")
                    .font(AppTypography.badge(uiFontSize: uiFontSize, fontFamily: fontFamily))
                    .hidden()
            }
            .accessibilityHidden(true)
        }
    }
}
