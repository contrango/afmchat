import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppConfiguration: Codable, Equatable, Sendable {
    static let userDefaultsKey = "FMChat.configuration"
    static let systemPromptUserDefaultsKey = "FMChat.systemPrompt"
    static let defaultSystemPrompt = "Du bist ein hilfreicher, klarer Assistent. Antworte in der Sprache des Nutzers. Halte Antworten kurz, sofern nicht ausdrücklich mehr Details gewünscht sind."
    static let defaults = AppConfiguration(
        temporaryDirectoryPath: "",
        dockerExecutablePath: "",
        dockerMCPProfile: "web_grounding",
        searxngURL: "http://host.docker.internal:8888",
        searxngImage: "isokoliuk/mcp-searxng:latest"
    )
    static let defaultJSON: String = {
        guard let data = try? JSONEncoder().encode(defaults),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }()

    var temporaryDirectoryPath: String
    var dockerExecutablePath: String
    var dockerMCPProfile: String
    var searxngURL: String
    var searxngImage: String

    static func decode(_ value: String) -> AppConfiguration {
        guard let data = value.data(using: .utf8),
              let configuration = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return .defaults
        }
        return configuration
    }

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else { return Self.defaultJSON }
        return value
    }

    var temporaryDirectoryURL: URL {
        let path = temporaryDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = path.isEmpty ? FileManager.default.temporaryDirectory : URL(fileURLWithPath: path, isDirectory: true)
        return base.appendingPathComponent("FMChat", isDirectory: true)
    }
}

struct AppSettingsView: View {
    @AppStorage(AppConfiguration.userDefaultsKey) private var configurationJSON = AppConfiguration.defaultJSON
    @State private var draft: AppConfiguration
    @State private var systemPromptDraft: String = AppConfiguration.defaultSystemPrompt
    @State private var validationMessage: String?
    @State private var savedMessage: String?

    init() {
        let saved = UserDefaults.standard.string(forKey: AppConfiguration.userDefaultsKey) ?? AppConfiguration.defaultJSON
        _draft = State(initialValue: AppConfiguration.decode(saved))
    }

    var body: some View {
        Form {
            Section("Temporäre Daten") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ordner für temporäre Upload-Kopien")
                        .font(.headline)
                    Text(draft.temporaryDirectoryURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                    HStack {
                        Button("Ordner auswählen …", action: chooseTemporaryDirectory)
                        Button("macOS-Standard") { draft.temporaryDirectoryPath = "" }
                            .disabled(draft.temporaryDirectoryPath.isEmpty)
                    }
                    Text("Die App legt während des Einlesens kurzzeitig eine Kopie der Datei im Unterordner „FMChat“ ab und löscht sie danach. Chatverläufe bleiben im bisherigen App-Speicherort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("System-Prompt") {
                Text("Hier legst du fest, wie sich das Modell grundsätzlich verhalten soll. Diese Anweisung gilt für neue Nachrichten in allen Chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $systemPromptDraft)
                    .font(.system(size: 13))
                    .frame(minHeight: 110)
                    .padding(6)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                    }
                HStack {
                    Button("Standardprompt wiederherstellen") {
                        systemPromptDraft = AppConfiguration.defaultSystemPrompt
                    }
                    Spacer()
                    Text("\(systemPromptDraft.count) Zeichen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Docker MCP") {
                TextField("Docker-MCP-Profil", text: $draft.dockerMCPProfile)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Docker-Programm (leer = automatisch)", text: $draft.dockerExecutablePath)
                        .textFieldStyle(.roundedBorder)
                    Button("Durchsuchen …", action: chooseDockerExecutable)
                }
                Text("Aufruf: docker mcp gateway run --profile <Profil>. Das Profil muss in Docker Desktop vorhanden sein.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SearXNG") {
                TextField("SearXNG-URL", text: $draft.searxngURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Docker-Image für den MCP-Server", text: $draft.searxngImage)
                    .textFieldStyle(.roundedBorder)
                Text("Standardwerte: http://host.docker.internal:8888 und isokoliuk/mcp-searxng:latest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let savedMessage {
                Text(savedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Standardwerte wiederherstellen") {
                    draft = .defaults
                    systemPromptDraft = AppConfiguration.defaultSystemPrompt
                    saveSettings()
                }
                Spacer()
                Button("Speichern") { saveSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620, height: 700)
        .onAppear {
            draft = AppConfiguration.decode(configurationJSON)
            systemPromptDraft = UserDefaults.standard.string(forKey: AppConfiguration.systemPromptUserDefaultsKey) ?? AppConfiguration.defaultSystemPrompt
            validationMessage = nil
            savedMessage = nil
        }
    }

    private func chooseTemporaryDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Ordner für temporäre Upload-Kopien auswählen"
        panel.prompt = "Ordner auswählen"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.temporaryDirectoryPath = url.path
            validationMessage = nil
            savedMessage = nil
        }
    }

    private func chooseDockerExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Docker-Programm auswählen"
        panel.prompt = "Auswählen"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.dockerExecutablePath = url.path
            validationMessage = nil
            savedMessage = nil
        }
    }

    private func saveSettings() {
        var cleaned = draft
        cleaned.temporaryDirectoryPath = cleaned.temporaryDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.dockerExecutablePath = cleaned.dockerExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.dockerMCPProfile = cleaned.dockerMCPProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned.searxngURL = cleaned.searxngURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.searxngURL.hasSuffix("/") { cleaned.searxngURL.removeLast() }
        cleaned.searxngImage = cleaned.searxngImage.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.dockerMCPProfile.isEmpty else {
            validationMessage = "Gib einen Docker-MCP-Profilnamen ein."
            return
        }
        guard let components = URLComponents(string: cleaned.searxngURL),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else {
            validationMessage = "Die SearXNG-URL muss mit http:// oder https:// beginnen und einen Host enthalten."
            return
        }
        guard !cleaned.searxngImage.isEmpty else {
            validationMessage = "Gib den Namen des SearXNG-Docker-Images ein."
            return
        }
        if !cleaned.dockerExecutablePath.isEmpty,
           !FileManager.default.isExecutableFile(atPath: cleaned.dockerExecutablePath) {
            validationMessage = "Der angegebene Docker-Pfad ist nicht ausführbar. Lass das Feld leer, um Docker automatisch suchen zu lassen."
            return
        }

        do {
            let directory = cleaned.temporaryDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let probe = directory.appendingPathComponent(".fmchat-write-test-\(UUID().uuidString)")
            try Data().write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
        } catch {
            validationMessage = "Der temporäre Ordner kann nicht beschrieben werden: \(error.localizedDescription)"
            return
        }

        draft = cleaned
        configurationJSON = cleaned.encoded
        let cleanedSystemPrompt = systemPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(cleanedSystemPrompt, forKey: AppConfiguration.systemPromptUserDefaultsKey)
        systemPromptDraft = cleanedSystemPrompt
        validationMessage = nil
        savedMessage = "Einstellungen gespeichert. Der System-Prompt gilt für neue Nachrichten; Docker- und SearXNG-Änderungen werden übernommen."
    }
}
