import Foundation

/// Turns a byte stream into SSE event payloads for the chat-completions loop
/// by running it through upstream's `OpenAICompatibleStreamFramer` (#3266), so
/// the engine accepts what upstream accepts: `data:` without the space, LF /
/// CR / CRLF line ends, and (Router only) raw JSON lines and one JSON payload
/// split across several `data:` lines. The old loop matched the literal
/// prefix `"data: "` on `bytes.lines`.
///
/// Native wires (Anthropic, Gemini) pass `translate`: each non-empty line goes
/// through the translator, whose OpenAI-shaped `data: {...}` output lines are
/// each one payload (they need no blank-line event boundary).
struct IntelSSEEventSequence<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String

    let base: Base
    var options: OpenAICompatibleStreamFramer.Options = .strict
    /// Sees every logical line (with a trailing LF) as it completes; the
    /// wire-verification tap.
    var onLine: ((Data) -> Void)? = nil
    var translate: ((String) throws -> [String])? = nil

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), options: options, onLine: onLine, translate: translate)
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        let options: OpenAICompatibleStreamFramer.Options
        let onLine: ((Data) -> Void)?
        let translate: ((String) throws -> [String])?
        private var parser = OpenAICompatibleStreamFramer.SSELineParser()
        private var pending = Data()
        private var eventData = ""
        private var queue: [String] = []
        private var finished = false

        init(
            base: Base.AsyncIterator, options: OpenAICompatibleStreamFramer.Options,
            onLine: ((Data) -> Void)?, translate: ((String) throws -> [String])?
        ) {
            self.base = base
            self.options = options
            self.onLine = onLine
            self.translate = translate
        }

        mutating func next() async throws -> String? {
            while true {
                if !queue.isEmpty { return queue.removeFirst() }
                if finished { return nil }
                if let byte = try await base.next() {
                    pending.append(byte)
                    // LF or CR ends a line; a very long line is handed over in
                    // pieces (the parser keeps the partial line).
                    if byte == 0x0A || byte == 0x0D || pending.count >= 4096 {
                        parser.append(pending)
                        pending.removeAll(keepingCapacity: true)
                        try drain()
                    }
                } else {
                    finished = true
                    if !pending.isEmpty {
                        parser.append(pending)
                        pending.removeAll()
                    }
                    parser.flushPending()
                    try drain()
                    // An unterminated final event is still an event.
                    if !eventData.isEmpty {
                        queue.append(eventData)
                        eventData = ""
                    }
                }
            }
        }

        private mutating func drain() throws {
            while let line = parser.nextLine() {
                if let onLine {
                    var tapped = line
                    tapped.append(0x0A)
                    onLine(tapped)
                }
                if let translate {
                    guard !line.isEmpty else { continue }
                    for out in try translate(String(decoding: line, as: UTF8.self)) {
                        guard out.hasPrefix("data:") else { continue }
                        var payload = out.dropFirst("data:".count)
                        if payload.first == " " { payload = payload.dropFirst() }
                        queue.append(String(payload))
                    }
                    continue
                }
                if !line.isEmpty {
                    OpenAICompatibleStreamFramer.processLine(line, options: options, into: &eventData)
                    continue
                }
                // Blank line: SSE event boundary.
                guard !eventData.isEmpty else { continue }
                queue.append(eventData)
                eventData = ""
            }
        }
    }
}

/// Which accumulator slot a streamed tool-call delta belongs to. Upstream
/// `OpenAICompatibleToolCallAccumulator.resolveToolCallSlot` (#3266): an
/// explicit `index` wins; a delta with no index follows its `id`, else the
/// slot touched last (continuation chunks carry neither), else a new slot.
/// Servers that omit `index` otherwise merge parallel calls into one slot.
struct IntelToolCallSlotResolver {
    private var idToIndex: [String: Int] = [:]
    private var nextFallback = 0
    private(set) var lastTouchedSlot: Int?

    mutating func resolve(explicitIndex: Int?, callId: String?, accumulatedSlots: Set<Int>) -> Int {
        let idx = pick(explicitIndex: explicitIndex, callId: callId, accumulatedSlots: accumulatedSlots)
        lastTouchedSlot = idx
        return idx
    }

    private mutating func pick(explicitIndex: Int?, callId: String?, accumulatedSlots: Set<Int>) -> Int {
        if let idx = explicitIndex {
            if let id = callId { idToIndex[id] = idx }
            nextFallback = max(nextFallback, idx + 1)
            return idx
        }
        if let id = callId, let known = idToIndex[id] { return known }
        if callId == nil, let last = lastTouchedSlot, accumulatedSlots.contains(last) { return last }
        let highest = accumulatedSlots.max() ?? -1
        let idx = max(highest + 1, nextFallback)
        nextFallback = idx + 1
        if let id = callId { idToIndex[id] = idx }
        return idx
    }
}
