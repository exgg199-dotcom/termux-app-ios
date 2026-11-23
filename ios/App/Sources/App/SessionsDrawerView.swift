import SwiftUI
import UIKit

struct SessionsDrawerView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var sessionManager: SessionManager
    let usesBlackTheme: Bool

    var body: some View {
        let items = sessionManager.listItems
        VStack(alignment: .leading, spacing: 0) {
            Text("Termux")
                .font(.title2.bold())
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            List {
                ForEach(items) { item in
                    sessionRow(item)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.selectSession(withHandle: item.id)
                            controller.focusTerminal()
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                controller.killSession(withHandle: item.id)
                            } label: {
                                Label("Kill", systemImage: "xmark.circle")
                            }
                            Button {
                                controller.renameSession(withHandle: item.id)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                controller.renameSession(withHandle: item.id)
                            } label: {
                                Label("Rename session", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                controller.killSession(withHandle: item.id)
                            } label: {
                                Label("Kill session", systemImage: "xmark.circle")
                            }
                        }
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)

            Divider()

            HStack(spacing: 4) {
                drawerButton(title: "Settings", systemImage: "gearshape") {
                    controller.showSettings()
                }
                drawerButton(title: controller.isSoftKeyboardShown ? "Hide keyboard" : "Keyboard", systemImage: "keyboard") {
                    controller.onToggleSoftKeyboardRequest()
                    controller.isDrawerOpen = false
                }
                drawerButton(title: "New session", systemImage: "plus") {
                    controller.addNewSession(name: nil)
                    controller.focusTerminal()
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in
                    controller.promptForNewNamedSession()
                })
            }
            .padding(4)
            .frame(height: 64)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(drawerBackground.ignoresSafeArea())
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 2, y: 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sessions")
    }

    private var drawerBackground: Color {
        return usesBlackTheme ? Color.black : Color(UIColor.systemBackground)
    }

    private func sessionRow(_ item: SessionListItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: item.isCurrent ? .bold : .regular, design: .monospaced))
                    .foregroundColor(item.isRunning ? .primary : .red)
                    .lineLimit(1)
                if item.isRunning {
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("exited with code \(item.exitStatus)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if item.isCurrent {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    private func drawerButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.footnote)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
