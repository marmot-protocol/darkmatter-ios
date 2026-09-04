import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNSecondaryButtonStyleTests {
    private typealias Metrics = WNSecondaryButtonStyle.Metrics

    @Test func lightSchemeLiftsTheCapsuleWhileDarkStaysTranslucent() {
        #expect(Metrics.surface(for: .light) == .lifted)
        #expect(Metrics.surface(for: .dark) == .translucent)
    }

    @Test func onlyTheLiftedSurfaceCastsAShadow() {
        #expect(Metrics.shadowOpacity(for: .light) > 0)
        #expect(Metrics.shadowOpacity(for: .light) < 1)
        #expect(Metrics.shadowOpacity(for: .dark) == 0)
    }

    @Test func shadowSitsBelowTheCapsuleRatherThanCenteredOnIt() {
        #expect(Metrics.shadowOffsetY > 0)
        #expect(Metrics.shadowRadius > 0)
    }

    @Test func labelStaysMonochromeAndDimsWhenDisabled() {
        #expect(Metrics.labelColor(isEnabled: true) == .primary)
        #expect(Metrics.labelColor(isEnabled: false) == .secondary)
    }

    @Test func pressFadesTheCapsuleWithoutHidingIt() {
        let pressed = Metrics.opacity(isPressed: true)
        #expect(Metrics.opacity(isPressed: false) == 1)
        #expect(pressed > 0)
        #expect(pressed < 1)
    }

    @Test func paddingKeepsAWiderThanTallPill() {
        for controlSize in ControlSize.allCases {
            #expect(Metrics.verticalPadding(for: controlSize) > 0)
            #expect(Metrics.horizontalPadding > Metrics.verticalPadding(for: controlSize))
        }
    }

    @Test func theCapsuleKeepsItsPaddingWhileTheCircleSizesFromItsDiameter() {
        for controlSize in ControlSize.allCases {
            let capsule = Metrics.insets(for: .capsule, controlSize: controlSize)
            #expect(capsule.horizontal == Metrics.horizontalPadding)
            #expect(capsule.vertical == Metrics.verticalPadding(for: controlSize))

            // Padding would stretch a bare glyph off center, so the circle
            // takes its size from the frame instead.
            let circle = Metrics.insets(for: .circle, controlSize: controlSize)
            #expect(circle.horizontal == 0)
            #expect(circle.vertical == 0)
        }
    }

    @Test func onlyTheCircleIsGivenAFixedDiameter() {
        #expect(Metrics.diameter(for: .circle, scaled: 52) == 52)
        #expect(Metrics.diameter(for: .capsule, scaled: 52) == nil)
    }

    @Test func circleDiameterClearsTheAppleMinimumTapTarget() {
        #expect(Metrics.circleDiameter >= 44)
    }

    @Test func extraLargeMatchesTheProminentCtaHeightAndHuggingPillsStaySmaller() {
        let cta = Metrics.verticalPadding(for: .extraLarge)
        #expect(cta == 15)
        for controlSize in ControlSize.allCases where controlSize != .extraLarge {
            #expect(Metrics.verticalPadding(for: controlSize) < cta)
        }
    }
}
