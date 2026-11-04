import SwiftUI
import FjordCore

/// Selects the language used by the app. `system` follows the Mac language;
/// `en` and `nb` explicitly select English or Norwegian Bokmål.
struct LanguagePicker: View {
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.defaultSelection.rawValue
    var disabled = false

    var body: some View {
        Picker(L10n.ui("Language"), selection: $language) {
            Text(L10n.ui("System language")).tag("system")
            Text(L10n.ui("English")).tag("en")
            Text(L10n.ui("Norsk (bokmål)")).tag("nb")
        }
        .pickerStyle(.menu)
        .disabled(disabled)
        .accessibilityLabel(L10n.ui("Language"))
    }
}
