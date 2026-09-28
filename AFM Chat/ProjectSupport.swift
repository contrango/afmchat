import Foundation
import Darwin
import NaturalLanguage

struct ProjectDocument: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
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

struct ChatProject: Identifiable, Codable, Equatable, Sendable {
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

    static func loadSemanticIndex(projectID: UUID) throws -> StoredProjectSemanticIndex? {
        let url = semanticIndexURL(projectID: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(StoredProjectSemanticIndex.self, from: Data(contentsOf: url))
    }

    static func saveSemanticIndex(_ index: StoredProjectSemanticIndex, projectID: UUID) throws {
        let directory = rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(index).write(to: semanticIndexURL(projectID: projectID), options: .atomic)
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

    private static func semanticIndexURL(projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("semantic-index-v1.json", isDirectory: false)
    }

    private static func documentDirectory(for projectID: UUID) -> URL {
        rootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }

    private static func documentTextURL(projectID: UUID, documentID: UUID) -> URL {
        documentDirectory(for: projectID).appendingPathComponent("\(documentID.uuidString).txt", isDirectory: false)
    }
}

struct StoredSemanticChunk: Codable, Sendable {
    let documentID: UUID
    let filename: String
    let page: String?
    let text: String
    let terms: [String]
    let languageCode: String?
    let vector: [Float]?
}

struct StoredProjectSemanticIndex: Codable, Sendable {
    let schemaVersion: Int
    let sourceFingerprint: String
    let chunks: [StoredSemanticChunk]
}

actor ProjectSemanticSearch {
    static let shared = ProjectSemanticSearch()

    private struct DocumentSource {
        let document: ProjectDocument
        let text: String
    }

    private struct DraftChunk {
        let documentID: UUID
        let filename: String
        let page: String?
        let text: String
        let terms: [String]
    }

    private struct ScoredChunk {
        let chunk: StoredSemanticChunk
        let score: Double
        let lexicalScore: Double
    }

    private let schemaVersion = 1
    private let chunkLimit = 1800
    private let maximumPassagesPerDocument = 2
    private let supportedLanguageCodes: Set<String> = ["de", "en", "es", "fr", "it", "pt", "zh-Hans"]
    private var cachedIndexes: [UUID: StoredProjectSemanticIndex] = [:]
    private var embeddingModels: [String: NLEmbedding] = [:]

    private let wordExpression = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}]{2,}")
    private let pageExpression = try! NSRegularExpression(pattern: "Seite\\s+(\\d+)", options: [.caseInsensitive])
    private let stopwords: Set<String> = [
        "aber", "alle", "alles", "als", "also", "am", "an", "auch", "auf", "aus", "bei", "bin", "bis", "das", "dass", "dein", "deine", "dem", "den", "der", "des", "die", "dies", "diese", "dieser", "du", "durch", "ein", "eine", "einem", "einen", "einer", "eines", "er", "es", "fur", "fuer", "hat", "hier", "ich", "im", "in", "ist", "mit", "nach", "nicht", "oder", "sein", "sie", "sind", "so", "und", "uns", "von", "vor", "was", "wenn", "wie", "wir", "zu", "zum", "zur",
        "about", "and", "are", "for", "from", "have", "how", "into", "is", "it", "that", "the", "their", "this", "to", "was", "what", "when", "where", "which", "with", "you", "your"
    ]

    func relevantContext(query: String, project: ChatProject, maximumCharacters: Int = 5000, maximumPassages: Int = 4) -> String? {
        guard let index = loadOrBuildIndex(for: project), !index.chunks.isEmpty else { return nil }
        let queryTerms = Set(tokens(in: query).filter { !stopwords.contains($0) })
        let queryLanguage = detectedLanguage(in: query)
        let queryVector: [Double]?
        if let queryLanguage, let embedding = sentenceEmbedding(for: queryLanguage) {
            queryVector = embedding.vector(for: String(query.prefix(1200)))
        } else {
            queryVector = nil
        }

        let chunks = index.chunks
        let lengths = chunks.map { max($0.terms.count, 1) }
        let averageLength = Double(lengths.reduce(0, +)) / Double(lengths.count)
        var documentFrequency: [String: Int] = [:]
        for chunk in chunks {
            for term in Set(chunk.terms).intersection(queryTerms) {
                documentFrequency[term, default: 0] += 1
            }
        }

        // BM25 scores lexical overlap; later it is combined with cosine similarity.
        let lexicalScores: [Double] = chunks.map { chunk in
            guard !queryTerms.isEmpty else { return 0 }
            var frequencies: [String: Int] = [:]
            for term in chunk.terms where queryTerms.contains(term) {
                frequencies[term, default: 0] += 1
            }
            guard !frequencies.isEmpty else { return 0 }
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
            return score
        }
        let maximumLexicalScore = lexicalScores.max() ?? 0
        let hasComparableVectors = queryVector != nil && chunks.contains {
            $0.languageCode == queryLanguage && $0.vector != nil
        }

        var scored: [ScoredChunk] = []
        for (chunkIndex, chunk) in chunks.enumerated() {
            let lexicalScore = maximumLexicalScore > 0 ? lexicalScores[chunkIndex] / maximumLexicalScore : 0
            var semanticScore = 0.0
            if hasComparableVectors,
               chunk.languageCode == queryLanguage,
               let queryVector,
               let chunkVector = chunk.vector,
               let similarity = cosineSimilarity(queryVector, chunkVector) {
                // Ignore weak similarities, then scale useful cosine matches to 0...1.
                semanticScore = max(0, min(1, (similarity - 0.25) / 0.5))
            }
            let combinedScore = hasComparableVectors
                ? 0.72 * semanticScore + 0.28 * lexicalScore
                : lexicalScore
            if combinedScore > 0.015 {
                scored.append(ScoredChunk(chunk: chunk, score: combinedScore, lexicalScore: lexicalScore))
            }
        }
        scored.sort {
            if abs($0.score - $1.score) < 0.000001 { return $0.lexicalScore > $1.lexicalScore }
            return $0.score > $1.score
        }
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

    func removeCachedIndex(projectID: UUID) {
        cachedIndexes.removeValue(forKey: projectID)
    }

    private func loadOrBuildIndex(for project: ChatProject) -> StoredProjectSemanticIndex? {
        let sources = project.documents.compactMap { document -> DocumentSource? in
            guard let text = try? ProjectStore.loadDocumentText(projectID: project.id, documentID: document.id) else { return nil }
            return DocumentSource(document: document, text: text)
        }.sorted { $0.document.id.uuidString < $1.document.id.uuidString }
        guard !sources.isEmpty else { return nil }
        let fingerprint = sourceFingerprint(sources)

        if let cached = cachedIndexes[project.id], cached.schemaVersion == schemaVersion,
           cached.sourceFingerprint == fingerprint {
            return cached
        }
        do {
            if let diskIndex = try ProjectStore.loadSemanticIndex(projectID: project.id),
               diskIndex.schemaVersion == schemaVersion,
               diskIndex.sourceFingerprint == fingerprint {
                cachedIndexes[project.id] = diskIndex
                return diskIndex
            }
        } catch {
            // A missing or outdated local index is rebuilt from the saved document text.
        }

        var indexedChunks: [StoredSemanticChunk] = []
        for source in sources {
            let language = detectedLanguage(in: source.text)
            let embedding = language.flatMap { sentenceEmbedding(for: $0) }
            for chunk in makeChunks(source.text, document: source.document) {
                let vector = embedding?.vector(for: chunk.text)?.map { Float($0) }
                indexedChunks.append(StoredSemanticChunk(
                    documentID: chunk.documentID,
                    filename: chunk.filename,
                    page: chunk.page,
                    text: chunk.text,
                    terms: chunk.terms,
                    languageCode: language,
                    vector: vector
                ))
            }
        }
        let index = StoredProjectSemanticIndex(
            schemaVersion: schemaVersion,
            sourceFingerprint: fingerprint,
            chunks: indexedChunks
        )
        cachedIndexes[project.id] = index
        try? ProjectStore.saveSemanticIndex(index, projectID: project.id)
        return index
    }

    private func sentenceEmbedding(for languageCode: String) -> NLEmbedding? {
        if let model = embeddingModels[languageCode] { return model }
        guard supportedLanguageCodes.contains(languageCode) else { return nil }
        let model = NLEmbedding.sentenceEmbedding(for: NLLanguage(rawValue: languageCode))
        if let model { embeddingModels[languageCode] = model }
        return model
    }

    private func detectedLanguage(in text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(3000)))
        guard let language = recognizer.dominantLanguage?.rawValue,
              supportedLanguageCodes.contains(language) else { return nil }
        return language
    }

    private func sourceFingerprint(_ sources: [DocumentSource]) -> String {
        var hash: UInt64 = 14695981039346656037
        for source in sources {
            for part in [source.document.id.uuidString, source.document.filename, source.text] {
                for byte in part.utf8 {
                    hash = (hash ^ UInt64(byte)) &* 1099511628211
                }
                hash = (hash ^ 255) &* 1099511628211
            }
        }
        return String(hash, radix: 16)
    }

    private func makeChunks(_ text: String, document: ProjectDocument) -> [DraftChunk] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var result: [DraftChunk] = []
        var current = ""
        var activePage: String?

        func appendChunk(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let page = pageNumber(in: trimmed) ?? activePage
            result.append(DraftChunk(
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
                    appendChunk(pagePrefix + String(paragraph[start..<end]))
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

    private func pageNumber(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = pageExpression.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[numberRange])
    }

    private func tokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordExpression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return String(text[tokenRange])
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
                .lowercased()
        }
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var lhsNorm = 0.0
        var rhsNorm = 0.0
        for index in lhs.indices {
            let left = lhs[index]
            let right = Double(rhs[index])
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }
        guard lhsNorm > 0, rhsNorm > 0 else { return nil }
        return dot / (sqrt(lhsNorm) * sqrt(rhsNorm))
    }
}
