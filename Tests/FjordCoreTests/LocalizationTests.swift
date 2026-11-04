import Foundation
import Testing
@testable import FjordCore

struct LocalizationTests {
    @Test func freshInstallStartsInEnglishAndPreservesSavedChoices() {
        #expect(AppLanguage.storedSelection(nil) == .english)
        #expect(AppLanguage.storedSelection("invalid") == .english)
        #expect(AppLanguage.storedSelection("en") == .english)
        #expect(AppLanguage.storedSelection("nb") == .norwegian)
        #expect(AppLanguage.storedSelection("system") == .system)
        #expect(AppLanguage.storedSelection(nil).identifier(preferredLanguages: ["nb-NO"]) == "en")
    }

    @Test func systemLanguageUsesSupportedPreferenceAndEnglishFallback() {
        #expect(AppLanguage.system.identifier(preferredLanguages: ["en-GB", "nb-NO"]) == "en")
        #expect(AppLanguage.system.identifier(preferredLanguages: ["nn-NO", "en-US"]) == "nb")
        #expect(AppLanguage.system.identifier(preferredLanguages: ["no", "en"]) == "nb")
        #expect(AppLanguage.system.identifier(preferredLanguages: ["fr-FR", "en-US"]) == "en")
        #expect(AppLanguage.system.identifier(preferredLanguages: []) == "en")
        #expect(AppLanguage.english.identifier(preferredLanguages: ["nb"]) == "en")
        #expect(AppLanguage.norwegian.identifier(preferredLanguages: ["en"]) == "nb")
    }

    @Test func tablesContainTheSameKeysAndCompatibleFormatArguments() throws {
        let placeholder = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ll|l)?[@diufgs]"#)
        func placeholders(_ text: String) -> [String] {
            placeholder.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                let match = String(text[Range($0.range, in: text)!])
                return match.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }.sorted()
        }
        for table in ["Interface", "Core"] {
            let english = try readTable(table, language: "en")
            let norwegian = try readTable(table, language: "nb")
            #expect(!english.isEmpty)
            #expect(Set(english.keys) == Set(norwegian.keys))
            for (key, value) in english {
                #expect(!value.isEmpty)
                let translation = try #require(norwegian[key])
                #expect(!translation.isEmpty)
                #expect(placeholders(value) == placeholders(translation), "Incompatible placeholders for \(table): \(key)")
                #expect(L10n.text(key, table: table, language: .english) == value)
                #expect(L10n.text(key, table: table, language: .norwegian) == translation)
            }
        }
    }

    @Test func missingTranslationKeepsReadableEnglishAndDoesNotInterpretPercentSigns() {
        #expect(L10n.text("A future message", table: "Core", language: .norwegian) == "A future message")
        #expect(L10n.formatted("100% ready", table: "Core", language: .english, arguments: []) == "100% ready")
    }

    @Test func translatedErrorsKeepServerMessagesAndFormatArguments() {
        #expect(L10n.formatted("GitHub returned %lld: %@", table: "Core", language: .english,
                               arguments: [403, "Permission denied"]) == "GitHub returned 403: Permission denied")
        #expect(L10n.formatted("GitHub returned %lld: %@", table: "Core", language: .norwegian,
                               arguments: [403, "Permission denied"]) == "GitHub svarte 403: Permission denied")
    }

    @Test func everyApplicationTranslationKeyExistsInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let call = try NSRegularExpression(pattern: #"L10n\.(ui|core)\("((?:[^"\\]|\\.)*)""#)
        let tables = try ["Interface": ["en": readTable("Interface", language: "en"), "nb": readTable("Interface", language: "nb")],
                          "Core": ["en": readTable("Core", language: "en"), "nb": readTable("Core", language: "nb")]]
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            for match in call.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let helper = String(source[try #require(Range(match.range(at: 1), in: source))])
                let literal = String(source[try #require(Range(match.range(at: 2), in: source))])
                #expect(!literal.contains("\\("), "Pass interpolation values separately in \(file.lastPathComponent)")
                let key = try JSONDecoder().decode(String.self, from: Data(("\"" + literal + "\"").utf8))
                let table = helper == "ui" ? "Interface" : "Core"
                for language in ["en", "nb"] {
                    #expect(tables[table]?[language]?[key] != nil, "Missing \(language) translation in \(file.lastPathComponent): \(key)")
                }
            }
        }
    }

    private func readTable(_ name: String, language: String) throws -> [String: String] {
        let url = try #require(L10n.resourceBundle.url(forResource: name, withExtension: "strings", subdirectory: "\(language).lproj"))
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
