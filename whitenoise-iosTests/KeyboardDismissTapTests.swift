import Testing
import UIKit
@testable import whitenoise_ios

@MainActor
struct KeyboardDismissTapTests {
    @Test func dismissesWhenNothingWasTouched() {
        #expect(KeyboardDismissTap.resignsKeyboard(touching: nil))
    }

    @Test func dismissesOnPlainContent() {
        #expect(KeyboardDismissTap.resignsKeyboard(touching: UIView()))
        #expect(KeyboardDismissTap.resignsKeyboard(touching: UIButton()))
    }

    @Test func keepsKeyboardWhenTappingATextField() {
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: UITextField()))
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: UITextView()))
    }

    @Test func keepsKeyboardWhenTappingInsideATextFieldSubview() {
        let field = UITextField()
        let inner = UIView()
        field.addSubview(inner)
        #expect(!KeyboardDismissTap.resignsKeyboard(touching: inner))
    }

    @Test func dismissesForSiblingsOfATextField() {
        let row = UIView()
        let field = UITextField()
        let label = UILabel()
        row.addSubview(field)
        row.addSubview(label)
        #expect(KeyboardDismissTap.resignsKeyboard(touching: label))
    }
}
