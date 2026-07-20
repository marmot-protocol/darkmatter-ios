import SwiftUI
import UIKit

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let fontSize: CGFloat
    let focusRequest: Int
    let onPasteImage: (UIImage) -> Void
    var onBeginEditing: () -> Void = {}

    private let minimumHeight: CGFloat = BottomInputChromeLayout.controlSize
    private let maximumHeight: CGFloat = 112

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ImagePasteTextView {
        let textView = ImagePasteTextView()
        textView.delegate = context.coordinator
        textView.onPasteImage = onPasteImage
        textView.backgroundColor = .clear
        textView.font = .systemFont(ofSize: fontSize)
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.textContainerInset = UIEdgeInsets(
            top: BottomInputChromeLayout.fieldVerticalPadding,
            left: 0,
            bottom: BottomInputChromeLayout.fieldVerticalPadding,
            right: 0
        )
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .default
        textView.autocapitalizationType = .sentences
        textView.keyboardDismissMode = .interactive
        textView.returnKeyType = .default
        textView.accessibilityLabel = L10n.string("Message")
        return textView
    }

    func updateUIView(_ uiView: ImagePasteTextView, context: Context) {
        context.coordinator.parent = self
        uiView.onPasteImage = onPasteImage
        if uiView.text != text {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
        }

        if focusRequest > context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            isFocused = true
        }

        if isFocused, !uiView.isFirstResponder {
            context.coordinator.scheduleFocus(for: uiView)
        } else {
            context.coordinator.cancelPendingFocus()
            if !isFocused, uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: ImagePasteTextView, coordinator: Coordinator) {
        coordinator.cancelPendingFocus()
        uiView.resignFirstResponder()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ImagePasteTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(maximumHeight, max(minimumHeight, fitting.height))
        uiView.isScrollEnabled = fitting.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var lastFocusRequest: Int
        private var pendingFocusTask: Task<Void, Never>?

        init(parent: ComposerTextInput) {
            self.parent = parent
            self.lastFocusRequest = 0
        }

        func scheduleFocus(for textView: ImagePasteTextView) {
            guard pendingFocusTask == nil else { return }
            pendingFocusTask = Task { @MainActor [weak self, weak textView] in
                guard let self else { return }
                defer { pendingFocusTask = nil }
                guard !Task.isCancelled,
                      parent.isFocused,
                      let textView,
                      !textView.isFirstResponder
                else { return }
                textView.becomeFirstResponder()
            }
        }

        func cancelPendingFocus() {
            pendingFocusTask?.cancel()
            pendingFocusTask = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.onBeginEditing()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
        }
    }
}

final class ImagePasteTextView: UITextView {
    var onPasteImage: ((UIImage) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image {
            onPasteImage?(image)
            return
        }
        super.paste(sender)
    }
}
