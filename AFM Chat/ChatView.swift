import SwiftUI
import FoundationModels
import PDFKit
import UniformTypeIdentifiers
import Vision

private enum UploadKind: String, Codable, Sendable {
    case pdf
    case text
    case image

    var symbolName: String {
        switch self {
        case .pdf: return "doc.text"
        case .text: return "doc.plaintext"
        case .image: return "photo"
        }
    }
}

private struct ChatAttachment: Identifiable, Codable, Sendable {
    let id: UUID
    let filename: String
    let pageCount: Int
    let wasTruncated: Bool
    let kind: UploadKind

    var detail: String {
        switch kind {
        case .pdf:
            return wasTruncated ? "PDF - gekuerzter Auszug" : "PDF - \(pageCount) Seiten"
        case .text:
            return wasTruncated ? "Textdatei - gekuerzter Auszug" : "Textdatei"
        case .image:
            return "Bild - lokal analysiert"
        }
    }

    private enum CodingKeys: String, CodingKey { case id, filename, pageCount, wasTruncated, kind }

    init(id: UUID = UUID(), filename: String, pageCount: Int = 0, wasTruncated: Bool = false, kind: UploadKind) {
        self.id = id
        self.filename = filename
        self.pageCount = pageCount
        self.wasTruncated = wasTruncated
        self.kind = kind
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        filename = try values.decode(String.self, forKey: .filename)
        pageCount = try values.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        wasTruncated = try values.decodeIfPresent(Bool.self, forKey: .wasTruncated) ?? false
        // Existing saved chats only had PDFs and do not include a kind field.
        kind = try values.decodeIfPresent(UploadKind.self, forKey: .kind) ?? .pdf
    }
}

private struct PendingUpload: Identifiable, Sendable {
    var id: UUID { attachment.id }
    let attachment: ChatAttachment
    let extractedText: String
}

private enum UploadImportError: LocalizedError {
    case unreadablePDF
    case noSelectablePDFText
    case unsupportedFile
    case unreadableText
    case emptyText
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "Die PDF-Datei konnte nicht geoeffnet werden."
        case .noSelectablePDFText: return "In der PDF wurde kein auslesbarer Text gefunden. Gescannte PDFs werden hier noch nicht per OCR gelesen."
        case .unsupportedFile: return "Dieser Dateityp wird nicht unterstuetzt. Erlaubt sind PDF, gaengige Textdateien sowie PNG- und JPEG-Bilder."
        case .unreadableText: return "Die Textdatei konnte nicht als UTF-8-, UTF-16- oder Latin-1-Text gelesen werden."
        case .emptyText: return "Die Datei enthaelt keinen auslesbaren Text."
        case .unreadableImage: return "Das Bild konnte nicht lokal analysiert werden."
        }
    }
}

private enum UploadProcessor {
    static let maximumCharacters = 12000
    static let maximumImageTextCharacters = 6000
    static let supportedTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "mdown", "json", "jsonl", "jsonc", "xml",
        "csv", "tsv", "yaml", "yml", "toml", "ini", "conf", "log", "html", "htm",
        "css", "js", "mjs", "cjs", "ts", "jsx", "tsx", "swift", "py", "java",
        "c", "h", "cpp", "hpp", "sql", "sh", "bash", "rb", "go", "rs", "php"
    ]
    static let supportedImageExtensions: Set<String> = ["png", "jpg", "jpeg"]

    static func process(from url: URL, temporaryDirectory: URL) throws -> PendingUpload {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || supportedTextExtensions.contains(ext) || supportedImageExtensions.contains(ext) else {
            throw UploadImportError.unsupportedFile
        }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let stagedURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: url, to: stagedURL)
        defer { try? FileManager.default.removeItem(at: stagedURL) }

        if ext == "pdf" { return try PDFTextExtractor.extract(from: stagedURL, filename: url.lastPathComponent) }
        if supportedTextExtensions.contains(ext) { return try extractText(from: stagedURL, filename: url.lastPathComponent) }
        return try analyzeImage(at: stagedURL, filename: url.lastPathComponent)
    }

    private static func extractText(from url: URL, filename: String) throws -> PendingUpload {
        let data = try Data(contentsOf: url)
        guard var text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw UploadImportError.unreadableText
        }
        if text.first == "\u{feff}" { text.removeFirst() }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UploadImportError.emptyText
        }
        let wasTruncated = text.count > maximumCharacters
        text = String(text.prefix(maximumCharacters))
        return PendingUpload(
            attachment: ChatAttachment(filename: filename, wasTruncated: wasTruncated, kind: .text),
            extractedText: "Textdatei \(filename):\n\(text)"
        )
    }

    private static func analyzeImage(at url: URL, filename: String) throws -> PendingUpload {
        let handler = VNImageRequestHandler(url: url, options: [:])
        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true

        do {
            try handler.perform([classifyRequest, textRequest])
        } catch {
            throw UploadImportError.unreadableImage
        }

        let labels = (classifyRequest.results ?? [])
            .prefix(5)
            .map { "\($0.identifier) (\(Int(($0.confidence * 100).rounded()))%)" }
        let recognizedLines = (textRequest.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        var summary = "Bilddatei \(filename) - lokale Vision-Analyse.\n"
        summary += labels.isEmpty
            ? "Erkannte Motive: keine eindeutige Klassifikation.\n"
            : "Erkannte Motive: \(labels.joined(separator: ", ")).\n"
        if recognizedLines.isEmpty {
            summary += "Im Bild wurde kein lesbarer Text erkannt."
        } else {
            summary += "Erkannter Text im Bild:\n\(recognizedLines.joined(separator: "\n"))"
        }
        let wasTruncated = summary.count > maximumImageTextCharacters
        summary = String(summary.prefix(maximumImageTextCharacters))
        return PendingUpload(
            attachment: ChatAttachment(filename: filename, wasTruncated: wasTruncated, kind: .image),
            extractedText: summary
        )
    }
}

private enum PDFTextExtractor {
    static let maximumCharacters = 12000

    static func extract(from url: URL, filename: String) throws -> PendingUpload {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw UploadImportError.unreadablePDF
        }

        var sections: [String] = []
        var characterCount = 0
        var wasTruncated = false

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pageText.isEmpty else { continue }

            let header = "[\(filename) - Seite \(pageIndex + 1)]\n"
            let remaining = maximumCharacters - characterCount - header.count
            guard remaining > 0 else {
                wasTruncated = true
                break
            }
            if pageText.count > remaining {
                sections.append(header + String(pageText.prefix(remaining)))
                wasTruncated = true
                break
            }
            sections.append(header + pageText)
            characterCount += header.count + pageText.count
        }

        let extractedText = sections.joined(separator: "\n\n")
        guard !extractedText.isEmpty else { throw UploadImportError.noSelectablePDFText }

        return PendingUpload(
            attachment: ChatAttachment(
                filename: filename,
                pageCount: document.pageCount,
                wasTruncated: wasTruncated,
                kind: .pdf
            ),
            extractedText: extractedText
        )
    }
}

private struct ChatMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    let text: String
    let attachments: [ChatAttachment]
    let contextText: String?

    init(id: UUID = UUID(), role: Role, text: String, attachments: [ChatAttachment] = [], contextText: String? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.attachments = attachments
        self.contextText = contextText
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, attachments, contextText }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        attachments = try values.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        contextText = try values.decodeIfPresent(String.self, forKey: .contextText)
    }
}

private struct SavedConversation: Identifiable, Codable {
    var id: UUID
    var title: String
    var messages: [ChatMessage]
    var transcriptData: Data?
    var updatedAt: Date
}

struct ChatView: View {
    @Environment(\.openSettings) private var openSettings
    @State private var conversations: [SavedConversation] = []
    @State private var activeConversationID: UUID?
    @State private var messages: [ChatMessage] = []
    @State private var draft = ""
    @State private var isGenerating = false
    @State private var modelReady = false
    @State private var modelChecked = false
    @State private var modelDisplayName = "Modell wird geprueft ..."
    @State private var didLoadStorage = false
    @State private var hoveredConversationID: UUID?
    @State private var alertTitle = ""
    @State private var alertMessage: String?
    @State private var pendingUploads: [PendingUpload] = []
    @State private var isImportingFile = false
    @State private var isProcessingUpload = false
    @State private var isDropTarget = false
    @State private var isConnectingWeb = false
    @State private var webToolsReady = false
    @State private var webSearchReady = false
    @State private var dockerGroundingReady = false
    @State private var webServicesChecked = false
    @State private var webStatus = "Web-Dienste werden verbunden ..."
    @State private var mcpManager = MCPServiceManager()
    @AppStorage(AppConfiguration.userDefaultsKey) private var configurationJSON = AppConfiguration.defaultJSON
    @State private var needsWebReconnect = false
    @State private var session = LanguageModelSession(instructions: "You are a helpful assistant. Respond in the user's language.")
    @FocusState private var composerFocused: Bool

    private let suggestions = [
        "Fasse einen Text kurz zusammen",
        "Hilf mir, eine E-Mail zu formulieren",
        "Erklaere ein schwieriges Thema einfach"
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            mainPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            checkModel()
            loadConversations()
            await connectWebServices()
        }
        .onChange(of: configurationJSON) { oldValue, newValue in
            Task { await applyConfigurationChange(from: oldValue, to: newValue) }
        }
        .onChange(of: isGenerating) { _, generating in
            if !generating { Task { await reconnectWebServicesIfNeeded() } }
        }
        .onChange(of: isProcessingUpload) { _, processing in
            if !processing { Task { await reconnectWebServicesIfNeeded() } }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "Unbekannter Fehler.")
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: allowedUploadTypes,
            allowsMultipleSelection: true,
            onCompletion: handleFileSelection
        )
    }

    private var appConfiguration: AppConfiguration {
        AppConfiguration.decode(configurationJSON)
    }

    private var allowedUploadTypes: [UTType] {
        var types: [UTType] = [.pdf, .text, .plainText, .xml, .json, .png, .jpeg]
        for ext in UploadProcessor.supportedTextExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("AFM Chat")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 24)

            Button(action: newChat) {
                Label("Neuer Chat", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            .disabled(isGenerating || isProcessingUpload)

            Text("GESPEICHERTE CHATS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(sortedConversations) { conversation in
                        conversationRow(conversation)
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 8)

            HStack(spacing: 9) {
                Circle()
                    .fill(modelReady ? Color.green : (modelChecked ? Color.orange : Color.gray))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(modelReady ? "Lokales Modell bereit" : (modelChecked ? "Modell nicht bereit" : "Pruefe Modell"))
                        .font(.system(size: 12, weight: .medium))
                    Text(modelDisplayName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Modellvariante, die AFM Chat ueber SystemLanguageModel.default verwendet")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            Button {
                Task { await connectWebServices() }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(webToolsReady ? Color.green : (webServicesChecked ? Color.orange : Color.gray))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isConnectingWeb ? "Verbinde Webdienste ..." : (webToolsReady ? "Web-Grounding bereit" : (webServicesChecked ? "Webdienste nicht verbunden" : "Web-Grounding")))
                            .font(.system(size: 12, weight: .medium))
                        Text(webStatus)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isConnectingWeb ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isConnectingWeb || isGenerating || isProcessingUpload)
            .help("Docker-MCP und SearXNG verbinden oder erneut verbinden")
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Button { openSettings() } label: {
                Label("Einstellungen", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 245)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func conversationRow(_ conversation: SavedConversation) -> some View {
        let isActive = conversation.id == activeConversationID
        let isHovered = conversation.id == hoveredConversationID
        return HStack(spacing: 2) {
            Button {
                selectConversation(conversation)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(conversation.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 9)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isGenerating || isProcessingUpload)

            Button(role: .destructive) {
                deleteConversation(conversation)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 27, height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Chat loeschen")
            .accessibilityLabel("Chat loeschen")
            .opacity(isHovered || isActive ? 1 : 0)
            .disabled(isGenerating || isProcessingUpload)
        }
        .background(isActive ? Color.primary.opacity(0.07) : (isHovered ? Color.primary.opacity(0.035) : .clear), in: RoundedRectangle(cornerRadius: 8))
        .onHover { inside in hoveredConversationID = inside ? conversation.id : nil }
    }

    private var mainPanel: some View {
        VStack(spacing: 0) {
            topBar
            if messages.isEmpty {
                welcomeView
            } else {
                conversationView
            }
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTarget {
                Label("Dateien hier ablegen", systemImage: "doc.badge.plus")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget, perform: handleFileDrop)
    }

    private var topBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(modelDisplayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Aktive Modellvariante, wie von SystemLanguageModel.default gemeldet")
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .medium))
                Text(webToolsReady ? "Lokal + Web" : "Lokal")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1) }
    }

    private var welcomeView: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "sparkle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 58, height: 58)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 19))
                .padding(.bottom, 22)

            Text("Womit kann ich dir helfen?")
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.5)
            Text(modelReady ? "Frag das lokale Apple-Modell direkt auf deinem Mac." : modelStatusText)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .padding(.horizontal, 24)

            VStack(spacing: 9) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        draft = suggestion
                        composerFocused = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(suggestion)
                                .font(.system(size: 13))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(width: 390)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.07), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(!modelReady)
                }
            }
            .padding(.top, 30)
            Spacer(minLength: 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 25) {
                    ForEach(messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    if isGenerating {
                        HStack(alignment: .top, spacing: 12) {
                            assistantMark
                            HStack(spacing: 9) {
                                ProgressView().controlSize(.small)
                                Text("FM denkt nach ...")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 3)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: 720)
                        .id("generating")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 24)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            .onChange(of: isGenerating) { _, generating in
                if generating { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("generating", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 90)
                VStack(alignment: .trailing, spacing: 7) {
                    ForEach(message.attachments) { attachment in
                        HStack(spacing: 7) {
                            Image(systemName: attachment.kind.symbolName)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(attachment.filename).lineLimit(1)
                                Text(attachment.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    }
                    Text(.init(message.text))
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .background(Color.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .frame(maxWidth: 720)
        } else {
            HStack(alignment: .top, spacing: 12) {
                assistantMark
                Text(.init(message.text))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var assistantMark: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 26, height: 26)
            .background(Color.accentColor.opacity(0.1), in: Circle())
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !pendingUploads.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pendingUploads) { upload in
                            HStack(spacing: 8) {
                                Image(systemName: upload.attachment.kind.symbolName)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(upload.attachment.filename)
                                        .lineLimit(1)
                                    Text(upload.attachment.detail)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Button {
                                    pendingUploads.removeAll { $0.id == upload.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Anhang entfernen")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Button { isImportingFile = true } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isGenerating || isProcessingUpload || pendingUploads.count >= 3)
                .help("Dateien anhaengen (maximal 3)")
                .accessibilityLabel("Datei anhaengen")

                TextField("Nachricht an FM ...", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit { sendMessage() }
                    .disabled(!modelReady || isGenerating || isProcessingUpload)

                Button(action: sendMessage) {
                    Image(systemName: isGenerating ? "hourglass" : "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.accentColor : Color.gray.opacity(0.45), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Nachricht senden (Cmd+Enter)")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.primary.opacity(0.13), lineWidth: 1))

            Text(composerStatusText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 26)
        .padding(.top, 13)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var composerStatusText: String {
        if isProcessingUpload { return "Dateien werden lokal gelesen ..." }
        if isConnectingWeb { return "Verbinde Docker-MCP und SearXNG ..." }
        if webToolsReady { return "FM laeuft lokal; Websuchen gehen ueber deine Docker-MCP-Dienste und SearXNG." }
        if modelReady { return "Dateien und Chat bleiben lokal auf deinem Mac. Web-Grounding ist nicht verbunden." }
        return modelStatusText
    }

    private var canSend: Bool {
        modelReady && !isGenerating && !isProcessingUpload && !isConnectingWeb && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentTitle: String {
        conversations.first(where: { $0.id == activeConversationID })?.title ?? "Neue Unterhaltung"
    }

    private var sortedConversations: [SavedConversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var modelStatusText: String {
        if !modelChecked { return "Pruefe, ob das Apple-Modell bereit ist ..." }
        return "Das Apple-Modell ist gerade nicht verfuegbar. Pruefe Apple Intelligence und die Modellbereitstellung in den Systemeinstellungen."
    }

    private var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("FMChat", isDirectory: true).appendingPathComponent("conversations.json")
    }

    private func checkModel() {
        let model = SystemLanguageModel.default
        if case .available = model.availability {
            modelReady = true
            modelDisplayName = model.variant.displayName
        } else {
            modelReady = false
            modelDisplayName = "Modell nicht verfuegbar"
        }
        modelChecked = true
    }

    private func loadConversations() {
        guard !didLoadStorage else { return }
        didLoadStorage = true
        do {
            let data = try Data(contentsOf: storageURL)
            conversations = try JSONDecoder().decode([SavedConversation].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            conversations = []
        } catch {
            conversations = []
            showAlert(title: "Chats konnten nicht geladen werden", message: error.localizedDescription)
        }

        if let latest = sortedConversations.first {
            activate(latest)
        } else {
            createConversation()
        }
    }

    private func activate(_ conversation: SavedConversation) {
        activeConversationID = conversation.id
        messages = conversation.messages
        pendingUploads.removeAll()
        draft = ""
        // Rebuild a bounded context from locally saved messages. This avoids replaying
        // obsolete MCP tool calls and prevents an old transcript from exceeding the model limit.
        session = makeSession()
    }

    private func createConversation() {
        let conversation = SavedConversation(
            id: UUID(),
            title: "Neue Unterhaltung",
            messages: [],
            transcriptData: nil,
            updatedAt: Date()
        )
        conversations.insert(conversation, at: 0)
        activeConversationID = conversation.id
        messages = []
        pendingUploads.removeAll()
        draft = ""
        session = makeSession()
        persistConversations()
    }

    private func newChat() {
        guard !isGenerating, !isProcessingUpload else { return }
        saveCurrentConversation()
        createConversation()
        composerFocused = true
    }

    private func selectConversation(_ conversation: SavedConversation) {
        guard !isGenerating, !isProcessingUpload, conversation.id != activeConversationID else { return }
        saveCurrentConversation()
        activate(conversation)
    }

    private func deleteConversation(_ conversation: SavedConversation) {
        guard !isGenerating, !isProcessingUpload else { return }
        let wasActive = conversation.id == activeConversationID
        conversations.removeAll { $0.id == conversation.id }
        persistConversations()

        if wasActive {
            if let replacement = sortedConversations.first {
                activate(replacement)
            } else {
                createConversation()
            }
        }
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, modelReady, !isGenerating, !isProcessingUpload else { return }
        let attachments = pendingUploads
        let priorMessages = messages
        let modelPrompt = makeModelPrompt(question: text, uploads: attachments, history: priorMessages)
        let requestSession = makeSession()
        session = requestSession
        let savedAttachmentContext = attachments.map(\.extractedText).joined(separator: "\n\n")
        messages.append(ChatMessage(
            role: .user,
            text: text,
            attachments: attachments.map(\.attachment),
            contextText: savedAttachmentContext.isEmpty ? nil : savedAttachmentContext
        ))
        pendingUploads.removeAll()
        draft = ""
        updateCurrentTitle()
        saveCurrentConversation()
        isGenerating = true

        Task {
            do {
                let response = try await requestSession.respond(to: modelPrompt)
                messages.append(ChatMessage(role: .assistant, text: response.content))
            } catch {
                if isContextLimitError(error) {
                    let retrySession = makeSession()
                    session = retrySession
                    let compactPrompt = makeModelPrompt(question: text, uploads: attachments, history: priorMessages, compact: true)
                    do {
                        let response = try await retrySession.respond(to: compactPrompt)
                        messages.append(ChatMessage(role: .assistant, text: response.content))
                    } catch {
                        let retryDetail = error.localizedDescription
                        let message = isContextLimitError(error)
                            ? "Der Chatkontext ist weiterhin zu gross. Bitte starte einen neuen Chat oder kuerze die Frage."
                            : "Die erneute Anfrage ist fehlgeschlagen: \(retryDetail)"
                        messages.append(ChatMessage(role: .assistant, text: message))
                    }
                } else {
                    messages.append(ChatMessage(role: .assistant, text: "Die Anfrage konnte nicht abgeschlossen werden. \(error.localizedDescription)"))
                }
            }
            isGenerating = false
            saveCurrentConversation()
        }
    }

    private func updateCurrentTitle() {
        guard let firstUserMessage = messages.first(where: { $0.role == .user }),
              let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        let title = firstUserMessage.text
        conversations[index].title = title.count > 34 ? String(title.prefix(34)) + "..." : title
        conversations[index].updatedAt = Date()
    }

    private func saveCurrentConversation() {
        guard let index = conversations.firstIndex(where: { $0.id == activeConversationID }) else { return }
        conversations[index].messages = messages
        conversations[index].transcriptData = nil
        conversations[index].updatedAt = Date()
        persistConversations()
    }

    private func persistConversations() {
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(conversations)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            showAlert(title: "Lokales Speichern fehlgeschlagen", message: error.localizedDescription)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): importFiles(urls)
        case .failure(let error): showAlert(title: "Datei konnte nicht ausgewaehlt werden", message: error.localizedDescription)
        }
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        guard !isGenerating, !isProcessingUpload else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var droppedURLs: [URL] = []
        for provider in fileProviders {
            group.enter()
            provider.loadObject(ofClass: URL.self) { item, _ in
                defer { group.leave() }
                let url = item
                if let url {
                    lock.lock()
                    droppedURLs.append(url)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !droppedURLs.isEmpty else {
                showAlert(title: "Datei konnte nicht gelesen werden", message: "Ziehe eine PDF, Textdatei oder ein PNG/JPEG-Bild aus dem Finder in den Chat.")
                return
            }
            importFiles(droppedURLs)
        }
        return true
    }

    private func importFiles(_ urls: [URL]) {
        let supportedURLs = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "pdf"
                || UploadProcessor.supportedTextExtensions.contains(ext)
                || UploadProcessor.supportedImageExtensions.contains(ext)
        }
        guard !supportedURLs.isEmpty else {
            showAlert(title: "Dateityp nicht unterstuetzt", message: UploadImportError.unsupportedFile.localizedDescription)
            return
        }
        let availableSlots = max(0, 3 - pendingUploads.count)
        guard availableSlots > 0 else {
            showAlert(title: "Maximale Anzahl erreicht", message: "Du kannst bis zu drei Dateien gleichzeitig an eine Nachricht anhaengen.")
            return
        }
        let selectedURLs = Array(supportedURLs.prefix(availableSlots))
        if supportedURLs.count > availableSlots {
            showAlert(title: "Maximal drei Dateien", message: "Es wurden nur die ersten freien Plaetze importiert.")
        }
        Task {
            isProcessingUpload = true
            for url in selectedURLs {
                do {
                    let temporaryDirectory = appConfiguration.temporaryDirectoryURL
                    let upload = try await Task.detached(priority: .utility) {
                        try UploadProcessor.process(from: url, temporaryDirectory: temporaryDirectory)
                    }.value
                    pendingUploads.append(upload)
                } catch {
                    showAlert(title: "Datei konnte nicht gelesen werden", message: "\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            isProcessingUpload = false
        }
    }

    private func makeModelPrompt(question: String, uploads: [PendingUpload], history: [ChatMessage], compact: Bool = false) -> String {
        var historyBudget = compact ? 1600 : 3600
        var entries: [String] = []
        for message in history.suffix(8).reversed() where historyBudget > 0 {
            let role = message.role == .user ? "Nutzer" : "Assistent"
            let messageExcerpt = String(message.text.prefix(min(compact ? 350 : 600, historyBudget)))
            var entry = "\(role): \(messageExcerpt)"
            historyBudget -= messageExcerpt.count
            if let priorAttachment = message.contextText, !priorAttachment.isEmpty, historyBudget > 0 {
                let documentExcerpt = String(priorAttachment.prefix(min(compact ? 700 : 1200, historyBudget)))
                entry += "\nFrueherer Datei-Auszug: \(documentExcerpt)"
                historyBudget -= documentExcerpt.count
            }
            entries.append(entry)
        }
        let historyText = entries.reversed().joined(separator: "\n")

        var attachmentBudget = compact ? 5000 : 10000
        var attachmentSections: [String] = []
        for upload in uploads where attachmentBudget > 0 {
            let excerpt = String(upload.extractedText.prefix(attachmentBudget))
            attachmentBudget -= excerpt.count
            let note = (upload.attachment.wasTruncated || excerpt.count < upload.extractedText.count) ? "\n[Text gekuerzt.]" : ""
            attachmentSections.append("--- \(upload.attachment.kind.rawValue.uppercased()): \(upload.attachment.filename) ---\n\(excerpt)\(note)")
        }

        var parts: [String] = []
        if !historyText.isEmpty {
            parts.append("Letzte Chatnachrichten (aeltere Teile koennen fehlen; fehlende Details nicht erfinden):\n\(historyText)")
        }
        if !attachmentSections.isEmpty {
            parts.append("Beantworte die Frage anhand der angehaengten Datei- und Bildanalyse-Texte. Bei Bildern stehen erkannte Motive und gegebenenfalls OCR-Text bereit; behaupte nicht, das Originalbild direkt gesehen zu haben. Wenn die bereitgestellten Inhalte die Antwort nicht enthalten, sage das klar.\n\nAngehaengte Dateien:\n\(attachmentSections.joined(separator: "\n\n"))")
        }
        parts.append("Aktuelle Anfrage:\n\(question)")
        return parts.joined(separator: "\n\n")
    }

    private func isContextLimitError(_ error: Error) -> Bool {
        let detail = error.localizedDescription.lowercased()
        return detail.contains("maximum allowed") || detail.contains("context window") || detail.contains("token limit")
    }

    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
    }

    private func makeSession() -> LanguageModelSession {
        var tools: [any Tool] = []
        if webSearchReady { tools.append(MCPWebSearchTool(manager: mcpManager)) }
        if dockerGroundingReady {
            tools.append(MCPWebFetchTool(manager: mcpManager))
            tools.append(MCPBrowserReadTool(manager: mcpManager))
        }
        let baseInstructions = "You are a helpful, clear assistant. Respond in the language used by the user. Keep answers concise unless the user asks for detail."
        var webInstructions = ""
        if webSearchReady {
            webInstructions += " For current questions, use web_search. It takes a single query string. If the search fails, do not answer from guesses."
        }
        if dockerGroundingReady {
            webInstructions += " Use web_fetch for ordinary pages and browser_read for JavaScript-rendered pages. These tools are already bound to Docker; do not pass a server name. Docker starts each backend only when called. Cite returned URLs. If a tool fails, say verification failed and do not invent names, addresses, or facts."
        }
        return LanguageModelSession(tools: tools, instructions: baseInstructions + webInstructions)
    }

    private func applyConfigurationChange(from oldValue: String, to newValue: String) async {
        let oldConfiguration = AppConfiguration.decode(oldValue)
        let newConfiguration = AppConfiguration.decode(newValue)
        guard oldConfiguration != newConfiguration else { return }
        needsWebReconnect = true
        await reconnectWebServicesIfNeeded()
    }

    private func reconnectWebServicesIfNeeded() async {
        guard needsWebReconnect, webServicesChecked,
              !isConnectingWeb, !isGenerating, !isProcessingUpload else { return }
        await connectWebServices()
    }

    private func connectWebServices() async {
        guard !isConnectingWeb, !isGenerating, !isProcessingUpload else { return }
        isConnectingWeb = true
        let configurationUsed = appConfiguration
        webStatus = "Starte Docker MCP (\(configurationUsed.dockerMCPProfile)) und SearXNG ..."
        let report = await mcpManager.connect(configuration: configurationUsed)
        webSearchReady = report.connectedServices.contains("SearXNG")
        dockerGroundingReady = report.connectedServices.contains { $0.hasPrefix("Docker MCP (") }
        webToolsReady = webSearchReady || dockerGroundingReady
        webServicesChecked = true

        if report.errors.isEmpty {
            webStatus = report.connectedServices.joined(separator: " + ")
        } else if report.connectedServices.isEmpty {
            webStatus = "Verbindung fehlgeschlagen. Docker Desktop und Einstellungen pruefen."
        } else {
            webStatus = report.connectedServices.joined(separator: " + ") + " (teilweise)"
        }

        // Rebuilding the model session must not discard pending file attachments.
        session = makeSession()
        isConnectingWeb = false
        needsWebReconnect = appConfiguration != configurationUsed

        if !report.errors.isEmpty {
            showAlert(title: "Webdienste teilweise nicht verfuegbar", message: report.errors.joined(separator: "\n"))
        }
        if needsWebReconnect {
            await reconnectWebServicesIfNeeded()
        }
    }

}
