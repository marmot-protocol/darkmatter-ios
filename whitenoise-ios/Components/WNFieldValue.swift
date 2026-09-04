import SwiftUI

/// The read-only twin of `WNInput`. A field that toggles between viewing and
/// editing keeps the same capsule, fill and height, so entering edit mode does
/// not reflow the form.
struct WNFieldValue: View {
    let value: String
    var placeholder: String?
    var kind = WNInputKind.text
    var fill = WNInputMetrics.fill

    @ScaledMetric(relativeTo: .body) private var height = WNInputMetrics.height

    var body: some View {
        let shape = WNInputMetrics.shape(for: kind).insettableShape

        return Text(WNFieldValuePresentation.display(value: value, placeholder: placeholder))
            .foregroundStyle(value.isEmpty ? .secondary : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WNInputMetrics.leadingInset)
            .padding(.vertical, WNInputMetrics.verticalInset(for: kind))
            .frame(minHeight: WNInputMetrics.fixesHeight(for: kind) ? height : nil)
            .background(fill, in: shape)
    }
}

nonisolated enum WNFieldValuePresentation {
    /// An empty value falls back to the field's placeholder, and to nothing at
    /// all when the caller supplied none — never to a stray blank capsule with
    /// a phantom label.
    static func display(value: String, placeholder: String?) -> String {
        value.isEmpty ? (placeholder ?? "") : value
    }
}

#Preview("WNFieldValue — Light") {
    VStack(spacing: 16) {
        WNFieldValue(value: "Marmota")
        WNFieldValue(value: "", placeholder: "Not set")
        WNFieldValue(
            value: "Building private messaging that stays private.",
            placeholder: "A little about you",
            kind: .multiline(3 ... 6)
        )
    }
    .padding()
    .frame(maxHeight: .infinity)
    .background(.background)
}

#Preview("WNFieldValue — Dark") {
    VStack(spacing: 16) {
        WNFieldValue(value: "marmota@whitenoise.example")
        WNFieldValue(value: "", placeholder: "Not set")
    }
    .padding()
    .frame(maxHeight: .infinity)
    .background(.background)
    .preferredColorScheme(.dark)
}
