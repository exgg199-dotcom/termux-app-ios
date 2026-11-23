import SwiftUI

struct SettingsView: View {
    @ObservedObject var environment: TermuxEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var fontSize: Double = AppPreferences.DEFAULT_FONT_SIZE
    @State private var theme: AppTheme = .system
    @State private var bellVibrate = true
    @State private var isReloadAlertPresented = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Appearance"),
                        footer: Text("Pinch the terminal to change the font size. \"System\" follows night-mode in termux.properties.")) {
                    Stepper(value: $fontSize, in: AppPreferences.MIN_FONT_SIZE...AppPreferences.MAX_FONT_SIZE,
                            step: AppPreferences.FONT_SIZE_STEP) {
                        HStack {
                            Text("Font size")
                            Spacer()
                            Text("\(Int(fontSize)) pt")
                                .foregroundColor(.secondary)
                        }
                    }
                    Picker("Theme", selection: $theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Terminal"),
                        footer: Text("Used when bell-character is \"vibrate\" (the default) in termux.properties.")) {
                    Toggle("Vibrate on bell", isOn: $bellVibrate)
                }

                Section(header: Text("Configuration"), footer: Text(configurationFooter)) {
                    NavigationLink(destination: PropertiesEditorView(environment: environment,
                                                                     fileURL: environment.paths.propertiesFile,
                                                                     template: Bootstrap.defaultTermuxProperties)) {
                        Text("Edit termux.properties")
                    }
                    NavigationLink(destination: PropertiesEditorView(environment: environment,
                                                                     fileURL: environment.paths.colorsPropertiesFile,
                                                                     template: PropertiesEditorView.colorsTemplate)) {
                        Text("Edit colors.properties")
                    }
                    Button("Reload settings") {
                        environment.reloadSettings()
                        isReloadAlertPresented = true
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("~/.termux")
                        Text(environment.paths.termuxConfigDirectory.path)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(versionText)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Shell")
                        Spacer()
                        Text("Built-in (no packages)")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(isPresented: $isReloadAlertPresented) {
                Alert(title: Text("Settings reloaded"))
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            fontSize = environment.preferences.fontSize
            theme = environment.preferences.theme
            bellVibrate = environment.preferences.bellVibrate
        }
        .onChange(of: fontSize) { value in
            guard value != environment.preferences.fontSize else { return }
            environment.preferences.fontSize = value
            environment.preferencesDidChange()
        }
        .onChange(of: theme) { value in
            guard value != environment.preferences.theme else { return }
            environment.preferences.theme = value
            environment.preferencesDidChange()
        }
        .onChange(of: bellVibrate) { value in
            guard value != environment.preferences.bellVibrate else { return }
            environment.preferences.bellVibrate = value
            environment.preferencesDidChange()
        }
    }

    private var configurationFooter: String {
        return "The home directory is shown in the Files app under On My iPhone/iPad › Termux › home. "
            + "The Files app hides folders starting with a dot, so ~/.termux is edited here or from the shell. "
            + "Settings are reloaded automatically when the files change. "
            + "A custom font can be installed as ~/.termux/font.ttf."
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct PropertiesEditorView: View {
    static let colorsTemplate = """
    # Terminal colors, see https://wiki.termux.com/wiki/Terminal_Settings
    # Uncomment and change the values, then tap Save.
    # background=#000000
    # foreground=#ffffff
    # cursor=#ffffff
    # color0=#000000
    # color1=#cd0000
    # color2=#00cd00
    # color3=#cdcd00
    # color4=#6495ed
    # color5=#cd00cd
    # color6=#00cdcd
    # color7=#e5e5e5
    # color8=#7f7f7f
    # color9=#ff0000
    # color10=#00ff00
    # color11=#ffff00
    # color12=#5c5cff
    # color13=#ff00ff
    # color14=#00ffff
    # color15=#ffffff

    """

    let environment: TermuxEnvironment
    let fileURL: URL
    let template: String

    @Environment(\.presentationMode) private var presentationMode
    @State private var text = ""
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.footnote, design: .monospaced))
            .disableAutocorrection(true)
            .textInputAutocapitalization(.never)
            .navigationTitle(fileURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .alert(isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Alert(title: Text("Could not save \(fileURL.lastPathComponent)"), message: Text(errorMessage ?? ""))
            }
            .onAppear(perform: load)
    }

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        if let data = try? Data(contentsOf: fileURL), let contents = String(data: data, encoding: .utf8) {
            text = contents
        } else {
            text = template
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL, options: .atomic)
            environment.reloadSettings()
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
