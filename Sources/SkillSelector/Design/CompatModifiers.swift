import SwiftUI

/// The single-parameter `onChange` (available on macOS 12). The 14+ overload
/// would fork the modifier chain; one deprecated warning lives here, in this
/// file, and nowhere else.
extension View {
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onChange(of: value, perform: action)
    }
}
