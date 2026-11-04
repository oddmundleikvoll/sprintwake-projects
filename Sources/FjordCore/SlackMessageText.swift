import Foundation

public enum SlackMessageText {
    public static func plainText(_ text: String, userNames: [String: String] = [:], channelNames: [String: String] = [:]) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard let open = text[index...].firstIndex(of: "<"), let close = text[open...].firstIndex(of: ">") else { output += decodeEntities(String(text[index...])); break }
            output += decodeEntities(String(text[index..<open]))
            let value = String(text[text.index(after: open)..<close])
            if value.first == "@", value.count > 1 {
                let id = String(value.dropFirst()); output += "@" + (userNames[id] ?? id)
            } else if value.first == "#" {
                let parts = value.dropFirst().split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let id = parts.first ?? ""
                output += id.isEmpty ? "<" + value + ">" : "#" + (parts.count > 1 ? decodeEntities(parts[1]) : (channelNames[id] ?? id))
            } else if value.contains("|") {
                let parts = value.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2, let url = URL(string: parts[0]), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    let label = decodeEntities(parts[1])
                    output += label.isEmpty ? decodeEntities(parts[0]) : "\(label) (\(parts[0]))"
                }
                else { output += decodeEntities("<" + value + ">") }
            } else if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                output += decodeEntities(value)
            } else { output += decodeEntities("<" + value + ">") }
            index = text.index(after: close)
        }
        return output
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
}
