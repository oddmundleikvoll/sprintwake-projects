import SwiftUI

// macOS 27's SDK also exports a State macro whose plugin is absent from the
// Command Line Tools. Resolve the established property-wrapper type explicitly
// so this package builds with the CLT as well as Xcode, back to macOS 14.
typealias ViewState<Value> = SwiftUI.State<Value>
