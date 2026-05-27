import Foundation

enum L10n {
    static func string(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .main, locale: AppLanguage.currentLocale)
    }
}
