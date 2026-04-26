import Foundation
import EventKit

// MARK: - AgentTool
//
// Read-only tools the LLM can invoke during a chat turn. Read-only by
// design for v1: creation actions (reminders, calendar events) stay on
// the existing `pendingAction` confirmation flow in ChatViewModel so
// the user always confirms side effects. Letting a 3B model directly
// schedule events without a human in the loop is a recipe for a 1-star
// review the first time it hallucinates a date.
//
// Tools advertise themselves to the model via a JSON Schema in the
// system prompt; they're invoked by the model emitting a tagged JSON
// block parsed by AgentLoop. This is provider-agnostic — works on
// Llama 3.2 3B today, will work unchanged after a swap to Qwen2.5-7B.

protocol AgentTool: Sendable {
    /// Snake_case identifier used in tool-call JSON. Stable wire ID —
    /// don't rename without considering any persisted chat history.
    var name: String { get }

    /// Human-readable description shown to the model so it can pick
    /// the right tool. Be concrete about WHEN to call this tool, not
    /// just what it does.
    var description: String { get }

    /// JSON Schema (parameters object only) describing the tool's
    /// arguments. Kept as a `[String: Any]`-ish dict via JSON Data so
    /// we don't drag a full schema library in for four tools.
    var parametersSchema: [String: AnySendable] { get }

    /// Execute the tool. `arguments` is whatever the model emitted in
    /// its tool_call block, already JSON-decoded. Return a string the
    /// model will see as the tool result on the next iteration.
    func execute(arguments: [String: AnySendable]) async throws -> String
}

/// Sendable wrapper around heterogeneous JSON values. We can't use
/// `Any` directly because tool execution crosses concurrency domains.
/// Carries only the JSON-representable scalar types we actually need.
enum AnySendable: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnySendable])
    case object([String: AnySendable])
    case null

    var asString: String? { if case .string(let v) = self { return v } else { return nil } }
    var asInt: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        case .string(let s): return Int(s)
        default: return nil
        }
    }
    var asArray: [AnySendable]? { if case .array(let v) = self { return v } else { return nil } }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
        if let v = try? c.decode(Int.self)    { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([AnySendable].self) { self = .array(v); return }
        if let v = try? c.decode([String: AnySendable].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Concrete tools

/// Search the user's indexed memory (photos, notes, contacts, events,
/// reminders, emails) for chunks matching a natural-language query.
struct SearchMemoryTool: AgentTool {
    let name = "search_memory"
    let description = """
    Search the user's personal data (photos, notes, contacts, events, reminders, emails) \
    for items matching a natural-language query. Use this whenever the user asks \
    about something specific they own, did, or said. Returns up to 8 ranked results.
    """

    let parametersSchema: [String: AnySendable] = [
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("The natural-language query to search for.")
            ]),
            "source_types": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("photo"), .string("contact"), .string("event"),
                        .string("reminder"), .string("note"), .string("email")
                    ])
                ]),
                "description": .string("Optional: restrict results to these source types. Omit to search everything.")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    let searchEngine: SemanticSearchEngine

    @MainActor
    func execute(arguments: [String: AnySendable]) async throws -> String {
        guard let query = arguments["query"]?.asString, !query.isEmpty else {
            return "Error: missing 'query' argument."
        }
        let typeFilter = arguments["source_types"]?.asArray?
            .compactMap { $0.asString }
            .compactMap { MemoryChunk.SourceType(rawValue: $0) }

        // Retrieve a wide window then filter — keeps semantic ranking
        // intact even when the user asks for a specific subset.
        let raw = await searchEngine.search(query: query, topK: 25)
        let filtered: [MemoryChunk]
        if let types = typeFilter, !types.isEmpty {
            let set = Set(types)
            filtered = raw.filter { set.contains($0.sourceType) }
        } else {
            filtered = raw
        }
        let top = filtered.prefix(8)

        if top.isEmpty {
            return "No matching memories found for '\(query)'."
        }
        return top.enumerated().map { i, chunk in
            "\(i + 1). [\(chunk.typeLabel)] \(chunk.content.prefix(180))"
        }.joined(separator: "\n")
    }
}

/// Convenience wrapper around `search_memory` constrained to photos.
/// The model could call `search_memory(source_types=["photo"])`, but a
/// dedicated tool yields better tool-selection accuracy on small models.
struct SearchPhotosTool: AgentTool {
    let name = "search_photos"
    let description = """
    Search the user's photo library by what's in the image (caption + location). \
    Use when the user explicitly asks for photos or pictures.
    """

    let parametersSchema: [String: AnySendable] = [
        "type": .string("object"),
        "properties": .object([
            "query": .object([
                "type": .string("string"),
                "description": .string("What the user is looking for in photos (e.g. 'beach sunsets', 'parking ticket').")
            ])
        ]),
        "required": .array([.string("query")])
    ]

    let searchEngine: SemanticSearchEngine

    @MainActor
    func execute(arguments: [String: AnySendable]) async throws -> String {
        guard let query = arguments["query"]?.asString, !query.isEmpty else {
            return "Error: missing 'query' argument."
        }
        let raw = await searchEngine.search(query: query, topK: 25)
        let photos = raw.filter { $0.sourceType == .photo }.prefix(8)
        if photos.isEmpty {
            return "No matching photos found for '\(query)'."
        }
        return photos.enumerated().map { i, chunk in
            "\(i + 1). \(chunk.content.prefix(180))"
        }.joined(separator: "\n")
    }
}

/// List events on the user's calendar in the next N days. Pulls
/// directly from EventKit so it stays current even between indexing
/// passes (events created today won't be in the embedding index yet).
struct ListUpcomingEventsTool: AgentTool {
    let name = "list_upcoming_events"
    let description = """
    List the user's upcoming calendar events, fresh from the calendar (not the search index). \
    Use when the user asks about their schedule, what's coming up, or a specific upcoming meeting.
    """

    let parametersSchema: [String: AnySendable] = [
        "type": .string("object"),
        "properties": .object([
            "days_ahead": .object([
                "type": .string("integer"),
                "description": .string("How many days into the future to look. Default 7. Max 60.")
            ])
        ]),
        "required": .array([])
    ]

    func execute(arguments: [String: AnySendable]) async throws -> String {
        let days = min(max(arguments["days_ahead"]?.asInt ?? 7, 1), 60)
        let store = EKEventStore()

        // Calendar access status check — we don't request here; that
        // belongs in the permissions flow on first launch. If the user
        // hasn't granted access, return a useful error the model can
        // relay rather than silently zero results.
        let status = EKEventStore.authorizationStatus(for: .event)
        // iOS 17+ replaced `.authorized` with `.fullAccess` for events.
        // Deployment target is 26.4 so `.fullAccess` is the only case
        // we need to honour.
        guard status == .fullAccess else {
            return "Calendar access not granted. Ask the user to grant it in Settings."
        }

        let start = Date()
        let end = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(15)

        if events.isEmpty {
            return "No events in the next \(days) day\(days == 1 ? "" : "s")."
        }
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return events.map { e in
            let when = df.string(from: e.startDate)
            let where_ = e.location.map { " @ \($0)" } ?? ""
            return "• \(when): \(e.title ?? "Untitled")\(where_)"
        }.joined(separator: "\n")
    }
}

/// Returns the current date and time. Sounds trivial but small models
/// frequently hallucinate "today" — anchoring them with this tool
/// dramatically improves date-relative answers ("what's tomorrow",
/// "next Friday", "in 3 days").
struct CurrentDateTimeTool: AgentTool {
    let name = "current_datetime"
    let description = """
    Get the current date, day of week, and time. Use whenever the user's question \
    involves any relative time reference (today, tomorrow, next week, this month, etc.).
    """

    let parametersSchema: [String: AnySendable] = [
        "type": .string("object"),
        "properties": .object([:]),
        "required": .array([])
    ]

    func execute(arguments: [String: AnySendable]) async throws -> String {
        let df = DateFormatter()
        df.dateFormat = "EEEE, MMMM d yyyy 'at' h:mm a zzz"
        return df.string(from: Date())
    }
}

// MARK: - Registry

/// Holds the set of tools available to the agent loop. A single
/// instance lives on AppContainer and is passed to AgentLoop.
@MainActor
final class ToolRegistry {
    let tools: [any AgentTool]

    init(searchEngine: SemanticSearchEngine) {
        self.tools = [
            CurrentDateTimeTool(),
            SearchMemoryTool(searchEngine: searchEngine),
            SearchPhotosTool(searchEngine: searchEngine),
            ListUpcomingEventsTool()
        ]
    }

    func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.name == name }
    }

    /// Renders the tool catalogue into the system prompt.
    /// Uses compact JSON and terse descriptions to stay well inside the
    /// model's context window — pretty-printed schemas waste ~30% tokens.
    func systemPromptSection() -> String {
        // One line per tool: name | compact-JSON params | short description.
        // This format is parseable by the model and saves hundreds of tokens
        // compared to a multi-line block per tool.
        let toolLines = tools.map { tool in
            let schema = serialise(tool.parametersSchema)
            return "- \(tool.name)(\(schema)): \(tool.description)"
        }.joined(separator: "\n")

        return """
        ## Tools
        \(toolLines)

        To call a tool emit exactly one line: <tool_call>{"name":"X","arguments":{...}}</tool_call>
        One call per turn. Write the answer directly if no tool is needed.
        """
    }

    /// Compact JSON — no pretty-printing. Saves ~30% tokens vs sorted+pretty.
    private func serialise(_ schema: [String: AnySendable]) -> String {
        let wrapped = AnySendable.object(schema)
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(wrapped),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}
