import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var environment: TermuxEnvironment
    @ObservedObject var sessionManager: SessionManager

    @State private var drawerDragOffset: CGFloat = 0

    private let drawerWidth: CGFloat = 300

    var body: some View {
        GeometryReader { geometry in
            let width = min(drawerWidth, geometry.size.width * 0.85)
            ZStack(alignment: .leading) {
                controller.terminalBackgroundColor
                    .ignoresSafeArea()

                TerminalContainerView(controller: controller)
                    .accessibilityHidden(controller.isDrawerOpen)

                edgeSwipeArea(width: width)

                if controller.isDrawerOpen || drawerDragOffset != 0 {
                    Color.black
                        .opacity(dimmingOpacity(width: width))
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .accessibilityLabel("Close sessions drawer")
                        .accessibilityAddTraits(.isButton)
                }

                SessionsDrawerView(controller: controller, sessionManager: sessionManager, usesBlackTheme: controller.usesBlackTheme)
                    .frame(width: width)
                    .offset(x: drawerOffset(width: width))
                    .simultaneousGesture(drawerCloseGesture(width: width))
                    .accessibilityHidden(!controller.isDrawerOpen)

                if let message = controller.toastMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(white: 0.2, opacity: 0.9))
                            .cornerRadius(12)
                            .padding(.bottom, 24)
                            .allowsHitTesting(false)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: controller.isDrawerOpen)
            .animation(.easeInOut(duration: 0.2), value: controller.toastMessage)
        }
        .statusBar(hidden: environment.properties.fullscreen)
        .preferredColorScheme(controller.colorScheme)
        .sheet(isPresented: $controller.isSettingsPresented, onDismiss: { controller.settingsDismissed() }) {
            SettingsView(environment: environment)
        }
        .onAppear { controller.onAppear() }
    }

    private func drawerOffset(width: CGFloat) -> CGFloat {
        let base: CGFloat = controller.isDrawerOpen ? 0 : -width - 16
        return min(0, max(-width - 16, base + drawerDragOffset))
    }

    private func dimmingOpacity(width: CGFloat) -> Double {
        let visible = width + 16 + drawerOffset(width: width)
        return Double(max(0, min(1, visible / (width + 16)))) * 0.4
    }

    private func closeDrawer() {
        controller.isDrawerOpen = false
        controller.focusTerminal()
    }

    private func edgeSwipeArea(width: CGFloat) -> some View {
        Color.clear
            .frame(width: 16)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { value in
                        guard !controller.isDrawerOpen else { return }
                        drawerDragOffset = max(0, min(width + 16, value.translation.width))
                    }
                    .onEnded { value in
                        let shouldOpen = value.translation.width > width / 3 || value.predictedEndTranslation.width > width / 2
                        drawerDragOffset = 0
                        if shouldOpen {
                            controller.isDrawerOpen = true
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    private func drawerCloseGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard controller.isDrawerOpen,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                drawerDragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                let shouldClose = isHorizontal
                    && (value.translation.width < -width / 3 || value.predictedEndTranslation.width < -width / 2)
                drawerDragOffset = 0
                if shouldClose {
                    closeDrawer()
                }
            }
    }
}
