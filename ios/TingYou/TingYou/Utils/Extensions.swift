import Foundation
import SwiftUI

extension String {
    var trimmed: String { self.trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
