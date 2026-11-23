import SwiftUI
import UIKit

struct TerminalContainerView: UIViewRepresentable {
    let controller: TerminalController

    func makeUIView(context: Context) -> TerminalView {
        return controller.terminalView
    }

    func updateUIView(_ terminalView: TerminalView, context: Context) {
    }
}
