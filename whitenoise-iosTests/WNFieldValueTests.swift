import Testing
@testable import whitenoise_ios

struct WNFieldValueTests {
    @Test func aPresentValueWinsOverThePlaceholder() {
        #expect(
            WNFieldValuePresentation.display(value: "Marmota", placeholder: "Not set")
                == "Marmota"
        )
    }

    @Test func anEmptyValueFallsBackToThePlaceholder() {
        #expect(
            WNFieldValuePresentation.display(value: "", placeholder: "Not set")
                == "Not set"
        )
    }

    @Test func anEmptyValueWithoutAPlaceholderRendersNothing() {
        #expect(WNFieldValuePresentation.display(value: "", placeholder: nil).isEmpty)
    }

    @Test func theReadOnlyFieldKeepsTheEditableFieldsShapeAndHeight() {
        // The point of the read-only twin: toggling Edit must not reflow the
        // form, so it reuses WNInput's metrics rather than its own.
        #expect(WNInputMetrics.shape(for: .text) == .capsule)
        #expect(WNInputMetrics.fixesHeight(for: .text))
        #expect(!WNInputMetrics.fixesHeight(for: .multiline(3 ... 6)))
    }
}
