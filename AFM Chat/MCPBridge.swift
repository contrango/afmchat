import Foundation
import FoundationModels

struct MCPToolDescriptor: Sendable {
    let server: String
    let name: String
    let description: String
    let inputSchema: String
}

struct MCPStartupReport: Sendable {
    let catalog: String
    let connectedServices: [String]
    let errors: [String]
}

private enum MCPBridgeError: LocalizedError {
    case dockerNotFound
    case invalidDockerPath(String)
    case processClosed(String, String)
    case requestTimedOut(String, String)
    case invalidTransportOutput(String, String)
    case invalidMessage
    case remote(String)
    case unavailableTool(String)

    var errorDescription: String? {
        switch self {
        case .dockerNotFound:
            return "Docker CLI wurde nicht gefunden. Starte Docker Desktop und pruefe die Docker-Installation."
        case .invalidDockerPath(let path):
            return "Der konfigurierte Docker-Pfad ist nicht ausfuehrbar: \(path)"
        case .processClosed(let service, let details):
            return "Der MCP-Prozess fuer \(service) wurde beendet, bevor er geantwortet hat.\(details.isEmpty ? "" : "\nDocker-Ausgabe: \(details)")"
        case .requestTimedOut(let request, let details):
            return "Zeitueberschreitung beim Warten auf \(request).\(details.isEmpty ? "" : "\nDocker-Ausgabe: \(details)")"
        case .invalidTransportOutput(let service, let details):
            return "Ungueltige MCP-Antwort von \(service).\(details.isEmpty ? "" : "\nAusgabe: \(details)")"
        case .invalidMessage:
            return "Der MCP-Server hat eine ungueltige JSON-RPC-Nachricht zurueckgegeben."
        case .remote(let message):
            return message
        case .unavailableTool(let name):
            return "Das angeforderte MCP-Tool ist nicht aktiviert: \(name)"
        }
    }
}

private final class MCPStdoutBuffer: @unchecked Sendable {
    private let condition = NSCondition()
    private var data = Data()
    private var closed = false

    func append(_ bytes: Data) {
        condition.lock()
        if bytes.isEmpty { closed = true } else { data.append(bytes) }
        condition.broadcast()
        condition.unlock()
    }

    func finish() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func nextLine(timeout: TimeInterval, service: String, method: String) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while true {
            if let newline = data.firstIndex(of: 0x0A) {
                let line = Data(data[..<newline])
                data.removeSubrange(...newline)
                return line
            }
            if closed {
                if !data.isEmpty {
                    let remainder = data
                    data.removeAll()
                    return remainder
                }
                throw MCPBridgeError.processClosed(service, "")
            }
            if !condition.wait(until: deadline) {
                throw MCPBridgeError.requestTimedOut("\(method) from \(service)", "")
            }
        }
    }
}

private final class MCPTailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 6000

    func append(_ bytes: Data) {
        lock.lock()
        data.append(bytes)
        if data.count > limit { data.removeFirst(data.count - limit) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private actor MCPStdioClient {
    private let serverName: String
    private let process: Process
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let stdoutBuffer: MCPStdoutBuffer
    private let stderrBuffer: MCPTailBuffer
    private var nextID = 1

    init(serverName: String, arguments: [String], environment: [String: String] = [:], dockerExecutablePath: String = "") throws {
        self.serverName = serverName
        self.process = Process()
        self.inputPipe = Pipe()
        self.outputPipe = Pipe()
        self.errorPipe = Pipe()
        self.stdoutBuffer = MCPStdoutBuffer()
        self.stderrBuffer = MCPTailBuffer()

        let dockerURL = try Self.findDocker(preferredPath: dockerExecutablePath)
        process.executableURL = dockerURL
        process.arguments = arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { childEnvironment[key] = value }
        process.environment = childEnvironment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutBuffer = self.stdoutBuffer
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            stdoutBuffer.append(bytes)
            if bytes.isEmpty { handle.readabilityHandler = nil }
        }
        let stderrBuffer = self.stderrBuffer
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            stderrBuffer.append(bytes)
            if bytes.isEmpty { handle.readabilityHandler = nil }
        }
        process.terminationHandler = { _ in stdoutBuffer.finish() }

        try process.run()
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
    }

    func initialize() throws {
        _ = try request("initialize", parameters: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "AFM Chat", "version": "1.2"]
        ])
        try sendNotification("notifications/initialized")
    }

    func listTools() throws -> [MCPToolDescriptor] {
        let response = try request("tools/list", parameters: [:])
        guard let result = response["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw MCPBridgeError.invalidMessage
        }

        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            let description = tool["description"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            let schemaData = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data("{}".utf8)
            return MCPToolDescriptor(
                server: serverName,
                name: name,
                description: description,
                inputSchema: String(decoding: schemaData, as: UTF8.self)
            )
        }
    }

    func call(tool: String, argumentsJSON: String) throws -> String {
        var cleanedArguments = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedArguments.hasPrefix("```"), let firstNewline = cleanedArguments.firstIndex(of: "\n") {
            cleanedArguments = String(cleanedArguments[cleanedArguments.index(after: firstNewline)...])
            if let closingFence = cleanedArguments.range(of: "```", options: .backwards) {
                cleanedArguments = String(cleanedArguments[..<closingFence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = cleanedArguments.data(using: .utf8),
              let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MCPBridgeError.invalidMessage
        }
        let response = try request("tools/call", parameters: ["name": tool, "arguments": arguments], timeout: 120)
        guard let result = response["result"] as? [String: Any] else {
            throw MCPBridgeError.invalidMessage
        }

        let isError = result["isError"] as? Bool ?? false
        let content = result["content"] as? [[String: Any]] ?? []
        let textParts = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }
        var output = textParts.joined(separator: "\n")
        if output.isEmpty, let structured = result["structuredContent"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.sortedKeys, .prettyPrinted]) {
            output = String(decoding: data, as: UTF8.self)
        }
        if output.isEmpty {
            output = "MCP tool completed without a text result."
        }
        if isError { output = "MCP tool reported an error: \(output)" }
        return String(output.prefix(14000))
    }

    func stop() {
        try? inputPipe.fileHandleForWriting.close()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func request(_ method: String, parameters: [String: Any], timeout: TimeInterval = 60) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        try writeMessage([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": parameters
        ])

        while true {
            let message = try readMessage(method: method, timeout: timeout)
            if (message["id"] as? Int) == id {
                if let error = message["error"] as? [String: Any] {
                    throw MCPBridgeError.remote(error["message"] as? String ?? "MCP request failed.")
                }
                return message
            }
        }
    }

    private func sendNotification(_ method: String) throws {
        try writeMessage(["jsonrpc": "2.0", "method": method])
    }

    private func writeMessage(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func readMessage(method: String, timeout: TimeInterval) throws -> [String: Any] {
        while true {
            let line: Data
            do {
                line = try stdoutBuffer.nextLine(timeout: timeout, service: serverName, method: method)
            } catch MCPBridgeError.processClosed(let service, _) {
                throw MCPBridgeError.processClosed(service, stderrBuffer.text())
            } catch MCPBridgeError.requestTimedOut(let request, _) {
                throw MCPBridgeError.requestTimedOut(request, stderrBuffer.text())
            }

            var cleanLine = line
            if cleanLine.last == 0x0D { cleanLine.removeLast() }
            if cleanLine.isEmpty { continue }
            guard let object = try JSONSerialization.jsonObject(with: cleanLine) as? [String: Any] else {
                let excerpt = String(decoding: cleanLine.prefix(300), as: UTF8.self)
                let stderr = stderrBuffer.text()
                let details = stderr.isEmpty ? excerpt : "\(excerpt)\n\(stderr)"
                throw MCPBridgeError.invalidTransportOutput(serverName, details)
            }
            return object
        }
    }

    private static func findDocker(preferredPath: String) throws -> URL {
        let fileManager = FileManager.default
        let configuredPath = preferredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredPath.isEmpty {
            guard fileManager.isExecutableFile(atPath: configuredPath) else {
                throw MCPBridgeError.invalidDockerPath(configuredPath)
            }
            return URL(fileURLWithPath: configuredPath)
        }
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let pathValue = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for folder in pathValue.split(separator: ":") {
            let path = String(folder) + "/docker"
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw MCPBridgeError.dockerNotFound
    }
}

actor MCPServiceManager {
    private var clients: [String: MCPStdioClient] = [:]
    private var enabledTools: [MCPToolDescriptor] = []

    func connect(configuration: AppConfiguration) async -> MCPStartupReport {
        await stopAll()
        let temporaryDirectory = configuration.temporaryDirectoryURL
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            return MCPStartupReport(catalog: "", connectedServices: [], errors: ["Temporärer Ordner: \(error.localizedDescription)"])
        }
        var errors: [String] = []
        var connected: [String] = []
        var discovered: [MCPToolDescriptor] = []

        do {
            let client = try MCPStdioClient(
                serverName: "docker-web-grounding",
                arguments: ["mcp", "gateway", "run", "--profile", configuration.dockerMCPProfile],
                environment: ["TMPDIR": temporaryDirectory.path],
                dockerExecutablePath: configuration.dockerExecutablePath
            )
            do {
                try await client.initialize()
                let tools = try await client.listTools()
                let allowed = tools.filter(Self.isAllowedDockerTool)
                clients["docker-web-grounding"] = client
                var dockerTools = allowed
                // Docker may expose names such as fetch:fetch and playwright:browser_navigate.
                // Preserve names returned by the gateway; add qualified fallbacks only if absent.
                for fallback in Self.onDemandDockerTools()
                where !dockerTools.contains(where: { Self.matchesToolName($0.name, fallback.name) }) {
                    dockerTools.append(fallback)
                }
                discovered.append(contentsOf: dockerTools)
                connected.append("Docker MCP (\(configuration.dockerMCPProfile))")
            } catch {
                await client.stop()
                throw error
            }
        } catch {
            errors.append("Docker MCP (\(configuration.dockerMCPProfile)): \(error.localizedDescription)")
        }

        do {
            let client = try MCPStdioClient(
                serverName: "searxng",
                arguments: ["run", "-i", "--rm", "-e", "SEARXNG_URL", configuration.searxngImage],
                environment: ["SEARXNG_URL": configuration.searxngURL, "TMPDIR": temporaryDirectory.path],
                dockerExecutablePath: configuration.dockerExecutablePath
            )
            do {
                try await client.initialize()
                let tools = try await client.listTools()
                clients["searxng"] = client
                discovered.append(contentsOf: tools)
                connected.append("SearXNG")
            } catch {
                await client.stop()
                throw error
            }
        } catch {
            errors.append("SearXNG: \(error.localizedDescription)")
        }

        enabledTools = discovered
        // Only small, safe Docker tool schemas are placed in the model context.
        // SearXNG search has its own typed Tool and must not duplicate its large schemas here.
        let catalog = clients["docker-web-grounding"] == nil
            ? ""
            : Self.onDemandDockerTools().map { item in
                "- tool: \(item.name); \(item.description); input: \(item.inputSchema)"
            }.joined(separator: "\n")

        return MCPStartupReport(catalog: catalog, connectedServices: connected, errors: errors)
    }

    func perform(server: String, tool: String, argumentsJSON: String) async throws -> String {
        guard let descriptor = enabledTools.first(where: { $0.server == server && Self.matchesToolName($0.name, tool) }) else {
            throw MCPBridgeError.unavailableTool("\(server).\(tool)")
        }
        guard let client = clients[server] else {
            throw MCPBridgeError.remote("The MCP service \(server) is not connected.")
        }
        var normalizedArguments = argumentsJSON
        if server == "searxng" && tool == "searxng_web_search" {
            guard let data = argumentsJSON.data(using: .utf8),
                  var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPBridgeError.remote("SearXNG search needs a JSON object with the required field query.")
            }
            if object["query"] == nil {
                for alias in ["q", "prompt", "search_query", "text"] {
                    if let value = object[alias] as? String {
                        object["query"] = value
                        break
                    }
                }
            }
            guard let query = object["query"] as? String,
                  !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPBridgeError.remote("SearXNG search needs a non-empty string in the exact field query.")
            }
            let normalizedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            normalizedArguments = String(decoding: normalizedData, as: UTF8.self)
        }
        let actualToolName = descriptor.name
        do {
            return try await client.call(tool: actualToolName, argumentsJSON: normalizedArguments)
        } catch MCPBridgeError.remote(let message) where message.localizedCaseInsensitiveContains("unknown tool") {
            // Some Gateway versions list a bare name but route calls using server:name (or vice versa).
            let qualified = Self.qualifiedDockerToolName(tool)
            let alternate = actualToolName == tool ? qualified : tool
            guard alternate != actualToolName else { throw MCPBridgeError.remote(message) }
            return try await client.call(tool: alternate, argumentsJSON: normalizedArguments)
        }
    }

    func stopAll() async {
        for client in clients.values { await client.stop() }
        clients.removeAll()
        enabledTools.removeAll()
    }

    private static func matchesToolName(_ candidate: String, _ requested: String) -> Bool {
        let candidate = candidate.lowercased()
        let requested = requested.lowercased()
        if candidate == requested { return true }
        return candidate.hasSuffix(":" + requested)
            || candidate.hasSuffix("_" + requested)
            || candidate.hasSuffix("__" + requested)
    }

    private static func qualifiedDockerToolName(_ tool: String) -> String {
        if tool == "fetch" { return "fetch:fetch" }
        return "playwright:\(tool)"
    }

    private static func isAllowedDockerTool(_ tool: MCPToolDescriptor) -> Bool {
        let name = tool.name.lowercased()
        if name.contains("fetch") { return true }
        let readOnlyBrowserTools = ["browser_navigate", "browser_navigate_back", "browser_snapshot", "browser_wait_for"]
        return readOnlyBrowserTools.contains { name.contains($0) }
    }

    private static func onDemandDockerTools() -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                server: "docker-web-grounding",
                name: "fetch:fetch",
                description: "Fetch a URL and return its readable page content. Docker starts the Fetch server when this tool is called.",
                inputSchema: #"{"type":"object","properties":{"url":{"type":"string","description":"URL to fetch"}},"required":["url"]}"#
            ),
            MCPToolDescriptor(
                server: "docker-web-grounding",
                name: "playwright:browser_navigate",
                description: "Navigate the read-only Playwright browser to a URL. Docker starts the Playwright server when this tool is called.",
                inputSchema: #"{"type":"object","properties":{"url":{"type":"string","description":"URL to open"}},"required":["url"]}"#
            ),
            MCPToolDescriptor(
                server: "docker-web-grounding",
                name: "playwright:browser_snapshot",
                description: "Read the current browser page snapshot without clicking or changing page state.",
                inputSchema: #"{"type":"object","properties":{}}"#
            ),
            MCPToolDescriptor(
                server: "docker-web-grounding",
                name: "playwright:browser_navigate_back",
                description: "Navigate the read-only Playwright browser back one page.",
                inputSchema: #"{"type":"object","properties":{}}"#
            )
        ]
    }
}

struct MCPWebSearchTool: Tool {
    let name = "web_search"
    let description = "Search the configured local SearXNG service. Provide search terms in the query field. The app forwards the exact required MCP field named query; do not use q or prompt."
    private let manager: MCPServiceManager

    @Generable
    struct Arguments {
        @Guide(description: "The search phrase to send to SearXNG. This becomes the exact required JSON field query.")
        var query: String
    }

    init(manager: MCPServiceManager) {
        self.manager = manager
    }

    func call(arguments: Arguments) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["query": arguments.query], options: [.sortedKeys])
        let argumentsJSON = String(decoding: data, as: UTF8.self)
        return try await manager.perform(server: "searxng", tool: "searxng_web_search", argumentsJSON: argumentsJSON)
    }
}

struct MCPWebFetchTool: Tool {
    let name = "web_fetch"
    let description = "Fetch and read a web page through Docker Fetch. Give an absolute HTTP or HTTPS URL. Docker starts the Fetch container only when this tool is called."
    private let manager: MCPServiceManager

    @Generable
    struct Arguments {
        @Guide(description: "The exact absolute HTTP or HTTPS URL to fetch.")
        var url: String
    }

    init(manager: MCPServiceManager) { self.manager = manager }

    func call(arguments: Arguments) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["url": arguments.url], options: [.sortedKeys])
        return try await manager.perform(
            server: "docker-web-grounding",
            tool: "fetch",
            argumentsJSON: String(decoding: data, as: UTF8.self)
        )
    }
}

struct MCPBrowserReadTool: Tool {
    let name = "browser_read"
    let description = "Read a JavaScript-rendered web page with Docker Playwright. This opens the provided URL and returns a page snapshot. It is read-only: it never clicks, types, submits forms, or changes page state. Docker starts the Playwright container only when this tool is called."
    private let manager: MCPServiceManager

    @Generable
    struct Arguments {
        @Guide(description: "The exact absolute HTTP or HTTPS URL to open and read.")
        var url: String
    }

    init(manager: MCPServiceManager) { self.manager = manager }

    func call(arguments: Arguments) async throws -> String {
        let urlData = try JSONSerialization.data(withJSONObject: ["url": arguments.url], options: [.sortedKeys])
        _ = try await manager.perform(
            server: "docker-web-grounding",
            tool: "browser_navigate",
            argumentsJSON: String(decoding: urlData, as: UTF8.self)
        )
        let snapshot = try await manager.perform(
            server: "docker-web-grounding",
            tool: "browser_snapshot",
            argumentsJSON: "{}"
        )
        return String(snapshot.prefix(9000))
    }
}
