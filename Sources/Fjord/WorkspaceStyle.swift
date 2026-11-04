import AppKit
import SwiftUI

/// Shared, opaque surfaces keep the workspace legible in both system appearances.
enum WorkspaceStyle {
    static let accent = Color.indigo
    static let canvas = adaptive(light: 0xF3F4F9, dark: 0x191B24)
    static let sidebar = adaptive(light: 0xECEEF6, dark: 0x20222D)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x2B2E3B)
    static let column = adaptive(light: 0xE9ECF4, dark: 0x21242F)
    static let border = adaptive(light: 0xD6DBE8, dark: 0x414657)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct WorkspaceSurface: ViewModifier {
    var radius: CGFloat = 14
    var emphasized = false
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(emphasized ? WorkspaceStyle.accent : (contrast == .increased ? Color.primary : WorkspaceStyle.border),
                                  lineWidth: emphasized || contrast == .increased ? 1.5 : 0.75)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(emphasized ? 0.10 : 0.04), radius: emphasized ? 8 : 3, y: 2)
    }
}

extension View {
    func workspaceSurface(radius: CGFloat = 14, emphasized: Bool = false) -> some View {
        modifier(WorkspaceSurface(radius: radius, emphasized: emphasized))
    }
}
