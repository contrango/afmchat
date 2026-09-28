import Foundation
import Darwin

struct ProjectDocument: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case pdf
        case text
        case image

        var displayName: String {
            switch self {
            case .pdf: return "PDF"
            case .text: return "Text"
            case .image: return "Bild"
            }
        }
    }

    let id: UUID
    var filename: String
    var kind: Kind
    var pageCount: Int
    var wasTruncated: Bool
    var importedAt: Date

    init(id: UUID = UUID(), filename: String, kind: Kind, pageCount: Int = 0, wasTruncated: Bool = false, importedAt: Date = Date()) {
        self.id = id
        self.filename = filename
        self.kind = kind
        self.pageCount = pageCount
        self.wasTruncated = wasTruncated
        self.importedAt = importedAt
    }
}

struct ChatProject: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var prompt: String
    var documents: [ProjectDocument]
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, prompt: String = "", documents: [ProjectDocument] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.documents = documents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ProjectStore {
    static var rootURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FMChat/Projects", isDirectory: true)
    }

    private static var metadataURL: URL {
        rootURL.appendingPathComponent("projects.json", isDirectory: false)
    }

    static func loadProjects() throws -> [ChatProject] {
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return [] }
        let data = try Data(contentsOf: metadataURL)
        return try JSONDecoder().decode([ChatProject].self, from: data)
    }

    static func saveProjects(_ projects: [ChatProject]) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(projects)
        try data.write(to: metadataURL, options: .atomic)
    }

    static func saveDocumentText(_ text: String, projectID: UUID, documentID: UUID) throws {
        let directory = documentDirectory(for: projectID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: documentTextURL(projectID: projectID, documentID: documentID), options: .atomic)
    }

    static func loadDocumentText(projectID: UUID, documentID: UUID) throws -> String {
        let url = documentTextURL(projectID: projectID, documentID: documentID)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text
    }

    static func removeDocumentText(projectID: UUID, documentID: UUID) throws {
        let url = documentTextURL(projectID: projectID, documentID: documentID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func removeProjectFiles(projectID: UUID) throws {
        let url = rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func documentDirectory(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private static func documentTextURL(projectID: UUID, documentID: UUID) -> URL {
        documentDirectory(for: projectID).appendingPathComponent("\(documentID.uuidString).txt", isDirectory: false)
    }
}

enum ProjectKeywordSearch {
    private struct Chunk {
        let documentID: UUID
        let filename: String
        let page: String?
        let text: String
        let terms: [String]
    }

    private struct ScoredChunk {
        let chunk: Chunk
        let score: Double
    }

    private static let chunkLimit = 1800
    private static let maximumPassagesPerDocument = 2
    private static let wordExpression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]{2,}")
    private static let pageExpression = try! NSRegularExpression(pattern: "Seite\\s+(\\d+)", options: [.caseInsensitive])
    private static let stopwords: Set<String> = [
        "aber", "alle", "alles", "als", "also", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "das", "dass", "dein", "deine", "dem", "den", "der", "des", "die", "dies", "diese", "dieser", "du", "durch", "ein", "eine", "einem", "einen", "einer", "eines", "er", "es", "fuer", "hat", "hier", "ich", "im", "in", "ist", "mit", "nach", "nicht", "oder", "sein", "sie", "sind", "so", "und", "uns", "von", "vor", "was", "wenn", "wie", "wir", "zu", "zum", "zur",
        "about", "and", "are", "for", "from", "have", "how", "into", "is", "it", "that", "the", "their", "this", "to", "was", "what", "when", "where", "which", "with", "you", "your"
    ]

    static func relevantContext(query: String, project: ChatProject, maximumCharacters: Int = 5000, maximumPassages: Int = 4) -> String? {
        let queryTerms = Set(tokens(in: query).filter { !stopwords.contains($0) })
        guard !queryTerms.isEmpty else { return nil }

        var chunks: [Chunk] = []
        for document in project.documents {
            guard let text = try? ProjectStore.loadDocumentText(projectID: project.id, documentID: document.id) else { continue }
            chunks.append(contentsOf: makeChunks(text, document: document))
        }
        guard !chunks.isEmpty else { return nil }

        let lengths = chunks.map { max($0.terms.count, 1) }
        let averageLength = Double(lengths.reduce(0, +)) / Double(lengths.count)
        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            for term in Set(chunk.terms).intersection(queryTerms) {
                documentFrequency[term, default: 0] += 1
            }
        }

        let scored = chunks.compactMap { chunk -> ScoredChunk? in
            var frequencies: [String: Int] = [:]
            for term in chunk.terms where queryTerms.contains(term) {
                frequencies[term, default: 0] += 1
            }
            guard !frequencies.isEmpty else { return nil }
            let length = Double(max(chunk.terms.count, 1))
            var score = 0.0
            for (term, frequency) in frequencies {
                let df = Double(documentFrequency[term, default: 0])
                let total = Double(chunks.count)
                let inverseFrequency = log(1 + (total - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                let normalization = tf + 1.2 * (0.25 + 0.75 * length / averageLength)
                score += inverseFrequency * tf * 2.2 / normalization
            }
            return ScoredChunk(chunk: chunk, score: score)
        }.sorted { $0.score > $1.score }

        guard !scored.isEmpty else { return nil }
        var passages: [String] = []
        var selectedCounts: [UUID: Int] = [:]
        var remaining = maximumCharacters

        for result in scored {
            guard passages.count < maximumPassages,
                  selectedCounts[result.chunk.documentID, default: 0] < maximumPassagesPerDocument else { continue }
            let pageText = result.chunk.page.map { ", Seite \($0)" } ?? ""
            let heading = "[Quelle: \(result.chunk.filename)\(pageText)]\n"
            let available = remaining - heading.count - 2
            guard available >= 180 else { break }
            let excerpt = String(result.chunk.text.prefix(min(result.chunk.text.count, available)))
            passages.append(heading + excerpt)
            selectedCounts[result.chunk.documentID, default: 0] += 1
            remaining -= heading.count + excerpt.count + 2
        }
        return passages.isEmpty ? nil : passages.joined(separator: "\n\n")
    }

    private static func makeChunks(_ text: String, document: ProjectDocument) -> [Chunk] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [Chunk] = []
        var current = ""
        var activePage: String?

        func appendChunk(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let page = pageNumber(in: trimmed) ?? activePage
            result.append(Chunk(
                documentID: document.id,
                filename: document.filename,
                page: page,
                text: trimmed,
                terms: tokens(in: trimmed)
            ))
        }

        for paragraph in paragraphs {
            if let page = pageNumber(in: paragraph) {
                appendChunk(current)
                current = paragraph
                activePage = page
                continue
            }

            if paragraph.count > chunkLimit {
                if current.count > 100 { appendChunk(current) }
                current = ""
                let pagePrefix = activePage.map { "[Seite \($0)]\n" } ?? ""
                let contentLimit = max(200, chunkLimit - pagePrefix.count)
                var start = paragraph.startIndex
                while start < paragraph.endIndex {
                    let end = paragraph.index(start, offsetBy: contentLimit, limitedBy: paragraph.endIndex) ?? paragraph.endIndex
                    let piece = pagePrefix + String(paragraph[start..<end])
                    appendChunk(piece)
                    start = end
                }
            } else if current.isEmpty {
                current = activePage.map { "[Seite \($0)]\n" + paragraph } ?? paragraph
            } else if current.count + paragraph.count + 2 <= chunkLimit {
                current += "\n\n" + paragraph
            } else {
                appendChunk(current)
                current = activePage.map { "[Seite \($0)]\n" + paragraph } ?? paragraph
            }
        }
        appendChunk(current)
        return result
    }

    private static func pageNumber(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pageExpression.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[numberRange])
    }

    private static func tokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordExpression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return String(text[tokenRange])
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
                .lowercased()
        }
    }
}
