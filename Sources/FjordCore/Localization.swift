import Foundation
import Observation

public enum AppBrand {
    public static let name = "Sprintwake Projects"
    public static let shortName = "Sprintwake"
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case norwegian = "nb"

    public static let preferenceKey = "appLanguage"
    public static let defaultSelection = AppLanguage.english
    public var id: String { rawValue }
    public static var current: AppLanguage {
        storedSelection(UserDefaults.standard.string(forKey: preferenceKey))
    }

    /// New installations start in English; keep every explicit language choice.
    public static func storedSelection(_ rawValue: String?) -> AppLanguage {
        rawValue.flatMap(AppLanguage.init(rawValue:)) ?? defaultSelection
    }

    public func identifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        // Unsupported system languages use English. Norwegian variants use Bokmål.
        for preferred in preferredLanguages {
            let language = preferred.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if ["nb", "nn", "no"].contains(language) { return "nb" }
            if language == "en" { return "en" }
        }
        return "en"
    }

    public var locale: Locale { Locale(identifier: identifier()) }
}

/// SwiftUI tracks reads made through L10n.ui, so switching language updates text
/// without recreating views or discarding unsaved form contents.
@MainActor @Observable
public final class LanguageSettings {
    public static let shared = LanguageSettings()
    public private(set) var selection: AppLanguage = .current
    private init() {}
    public func update(_ rawValue: String) { selection = AppLanguage.storedSelection(rawValue) }
}

/// Explicit bundles keep localization working in both `swift run` and the macOS app.
/// English strings are stable lookup keys; repository data is never translated.
public enum L10n {
    static let resourceBundle = Bundle.module

    public static func text(_ key: String, table: String, language: AppLanguage = .current) -> String {
        guard let url = resourceBundle.url(forResource: language.identifier(), withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: table)
    }

    @MainActor public static func ui(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, table: "Interface", language: LanguageSettings.shared.selection, arguments: arguments)
    }

    public static func core(_ key: String, _ arguments: CVarArg...) -> String {
        formatted(key, table: "Core", language: .current, arguments: arguments)
    }

    public static func formatted(_ key: String, table: String, language: AppLanguage, arguments: [CVarArg]) -> String {
        let translated = text(key, table: table, language: language)
        guard !arguments.isEmpty else { return translated }
        return String(format: translated, locale: language.locale, arguments: arguments)
    }
}
