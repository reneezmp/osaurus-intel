//
//  AppleToolExecutionTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Executes representative Apple tools against fake services to pin the
//  `AppleToolBase` contract: argument validation → `invalid_args` with a
//  field, limit clamping, `Encodable` payloads → JSON envelopes, and the
//  typed error kinds (`not_found`, `permission_denied`, `unavailable`,
//  `timeout`) the model branches on. No TCC or app access is touched.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Envelope helpers

private func envelope(_ raw: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
}

private func result(_ raw: String) throws -> [String: Any] {
    let env = try envelope(raw)
    #expect(env["ok"] as? Bool == true, "expected success: \(raw)")
    return try #require(env["result"] as? [String: Any])
}

// MARK: - Fakes

private final class FakeCalendarService: CalendarServicing, @unchecked Sendable {
    var calendars: [CalendarInfo] = [
        CalendarInfo(id: "cal-1", title: "Work", account: "iCloud", color: "#FF0000", isEditable: true, isDefault: true, isSubscribed: false, type: "calDAV"),
        CalendarInfo(id: "cal-2", title: "Holidays", account: "Subscribed", color: nil, isEditable: false, isDefault: false, isSubscribed: true, type: "subscription"),
    ]
    var events: [CalendarEventInfo] = []
    var error: AppleToolError?
    private(set) var lastQuery: CalendarEventQuery?
    private(set) var lastDraft: CalendarEventDraft?
    private(set) var deleted: [(String, Date?, CalendarEditSpan)] = []

    func calendars() async throws -> [CalendarInfo] {
        if let error { throw error }
        return calendars
    }
    var clampEnd = false
    func events(_ query: CalendarEventQuery) async throws -> CalendarEventsResult {
        if let error { throw error }
        lastQuery = query
        let effectiveEnd = clampEnd ? (Calendar.current.date(byAdding: .year, value: 4, to: query.start) ?? query.end) : query.end
        return CalendarEventsResult(events: events, effectiveEnd: effectiveEnd, endWasClamped: clampEnd && effectiveEnd < query.end)
    }
    func event(id: String, occurrenceStart: Date?) async throws -> CalendarEventInfo {
        if let error { throw error }
        guard let e = events.first(where: { $0.id == id }) else { throw AppleToolError.notFound("No event `\(id)`.") }
        return e
    }
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventInfo {
        if let error { throw error }
        lastDraft = draft
        return Self.event(id: "new-1", title: draft.title, start: draft.start, end: draft.end, allDay: draft.isAllDay)
    }
    func update(id: String, occurrenceStart: Date?, span: CalendarEditSpan, patch: CalendarEventPatch) async throws -> CalendarEventInfo {
        if let error { throw error }
        return try await event(id: id, occurrenceStart: occurrenceStart)
    }
    func delete(id: String, occurrenceStart: Date?, span: CalendarEditSpan) async throws -> CalendarEventInfo {
        if let error { throw error }
        let e = try await event(id: id, occurrenceStart: occurrenceStart)
        deleted.append((id, occurrenceStart, span))
        return e
    }

    static func event(id: String, title: String, start: Date, end: Date, allDay: Bool = false, recurring: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(
            id: id, calendarId: "cal-1", calendarTitle: "Work", title: title, start: start, end: end, isAllDay: allDay,
            allDayDates: allDay ? CalendarArgs.allDayRange(start: start, end: end) : nil,
            location: nil, notes: nil, url: nil, status: "confirmed", availability: "busy", organizer: nil,
            attendees: [], alarms: [], recurrence: nil, isRecurring: recurring, isDetached: false, lastModified: nil,
            openURL: "ical://ekevent/\(id)"
        )
    }
}

private final class FakeShortcutsService: ShortcutsServicing, @unchecked Sendable {
    var shortcuts = [ShortcutInfo(name: "Morning Brief", identifier: "0F0F0F0F-0000-4000-8000-000000000001", folder: nil), ShortcutInfo(name: "Log Water", identifier: nil, folder: nil)]
    var runError: AppleToolError?
    private(set) var lastRun: (name: String, input: String?, timeout: TimeInterval)?

    func list() async throws -> [ShortcutInfo] { shortcuts }
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult {
        lastRun = (name, input, timeout)
        if let runError { throw runError }
        return ShortcutRunResult(name: name, output: "ran \(name) with \(input ?? "-")", outputIsEmpty: false, outputIsBinary: false, outputBytes: 10, outputTruncated: false, durationSeconds: 0.5)
    }
}

// MARK: - Calendar

@Suite("Apple tools: Calendar over a fake service")
struct CalendarToolExecutionTests {

    @Test("calendar_list returns typed calendars with ids")
    func listCalendars() async throws {
        let service = FakeCalendarService()
        let tool = CalendarListTool(service: service)
        let payload = try result(await tool.execute(argumentsJSON: "{}"))
        let calendars = try #require(payload["calendars"] as? [[String: Any]])
        #expect(calendars.count == 2)
        #expect(calendars.first?["id"] as? String == "cal-1")
        #expect(calendars.first?["isDefault"] as? Bool == true)
        #expect(payload["count"] as? Int == 2)
    }

    @Test("calendar_events defaults to now → +7d, parses dates, and clamps the limit")
    func eventsDefaultsAndClamp() async throws {
        let service = FakeCalendarService()
        let tool = CalendarEventsTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: "{}"))
        let q = try #require(service.lastQuery)
        let span = q.end.timeIntervalSince(q.start)
        #expect(span > 6.9 * 86_400 && span < 7.1 * 86_400)
        #expect(q.includeAllDay)

        _ = try result(await tool.execute(argumentsJSON: #"{"start":"2026-09-19","end":"2026-09-19","limit":99999,"calendars":["cal-1"],"query":"standup"}"#))
        let q2 = try #require(service.lastQuery)
        // Date-only end is inclusive → exclusive bound is the next day.
        #expect(q2.end.timeIntervalSince(q2.start) >= 23 * 3600)
        #expect(q2.calendarIds == ["cal-1"])
        #expect(q2.query == "standup")
    }

    @Test("calendar_events emits ISO 8601 with local offset and total/truncated")
    func eventsOutputShape() async throws {
        let service = FakeCalendarService()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        service.events = (0 ..< 3).map { i in
            FakeCalendarService.event(id: "e\(i)", title: "Event \(i)", start: start.addingTimeInterval(Double(i) * 3600), end: start.addingTimeInterval(Double(i + 1) * 3600))
        }
        let tool = CalendarEventsTool(service: service)
        let payload = try result(await tool.execute(argumentsJSON: #"{"limit":2}"#))
        let events = try #require(payload["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(payload["total_in_range"] as? Int == 3)
        #expect(payload["truncated"] as? Bool == true)
        let startText = try #require(events.first?["start"] as? String)
        #expect(startText == AppleDateParsing.format(start))
        #expect(!startText.hasSuffix("Z"))
        #expect(events.first?["openURL"] as? String == "ical://ekevent/e0")
    }

    @Test("bad dates and missing required args produce invalid_args with the field named")
    func invalidArgs() async throws {
        let tool = CalendarEventsTool(service: FakeCalendarService())
        let env = try envelope(await tool.execute(argumentsJSON: #"{"start":"tomorrow-ish"}"#))
        #expect(env["ok"] as? Bool == false)
        #expect(env["kind"] as? String == "invalid_args")
        #expect(env["field"] as? String == "start")
        #expect((env["expected"] as? String)?.contains("ISO 8601") == true)

        let create = CalendarCreateEventTool(service: FakeCalendarService())
        let env2 = try envelope(await create.execute(argumentsJSON: #"{"start":"2026-09-19T10:00"}"#))
        #expect(env2["kind"] as? String == "invalid_args")
        #expect(env2["field"] as? String == "title")

        let env3 = try envelope(await create.execute(argumentsJSON: "not json"))
        #expect(env3["ok"] as? Bool == false)
        #expect(env3["kind"] as? String == "invalid_args")
    }

    @Test("calendar_create_event: bare start makes an all-day event; timed start defaults end to +1h")
    func createDefaults() async throws {
        let service = FakeCalendarService()
        let tool = CalendarCreateEventTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Offsite","start":"2026-10-02"}"#))
        let allDay = try #require(service.lastDraft)
        #expect(allDay.isAllDay)
        #expect(allDay.title == "Offsite")

        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Standup","start":"2026-10-02T09:00:00-07:00"}"#))
        let timed = try #require(service.lastDraft)
        #expect(!timed.isAllDay)
        #expect(timed.end.timeIntervalSince(timed.start) == 3600)
    }

    @Test("typed service errors map to their envelope kinds with retryable/permission metadata")
    func errorKinds() async throws {
        let service = FakeCalendarService()
        let tool = CalendarListTool(service: service)

        service.error = .permissionDenied(.calendar)
        var env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "permission_denied")
        #expect(env["retryable"] as? Bool == false)
        // Metadata is flattened onto the envelope root.
        #expect(env["permission"] as? String == SystemPermission.calendar.rawValue)
        #expect((env["system_settings_url"] as? String)?.isEmpty == false)
        #expect((env["message"] as? String)?.contains("System Settings") == true)

        service.error = .unavailable("EventKit is unavailable", retryable: true)
        env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "unavailable")
        #expect(env["retryable"] as? Bool == true)

        service.error = .timeout("took too long")
        env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "timeout")

        service.error = nil
        let open = CalendarOpenEventTool(service: service)
        env = try envelope(await open.execute(argumentsJSON: #"{"id":"nope"}"#))
        #expect(env["kind"] as? String == "not_found")
    }

    @Test("calendar_delete_event is per-call approval and forwards span + occurrence")
    func deleteContract() async throws {
        let service = FakeCalendarService()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        service.events = [FakeCalendarService.event(id: "e1", title: "Weekly", start: start, end: start.addingTimeInterval(1800))]
        let tool = CalendarDeleteEventTool(service: service)
        #expect(tool is PerCallApprovalTool)
        #expect(tool.defaultPermissionPolicy == .ask)
        let payload = try result(await tool.execute(argumentsJSON: #"{"id":"e1","occurrence_start":"2026-09-19T10:00:00-07:00","span":"future_events"}"#))
        #expect(payload["deleted"] as? Bool == true)
        #expect(payload["span"] as? String == "future_events")
        #expect(service.deleted.count == 1)
        #expect(service.deleted.first?.2 == .futureEvents)
        #expect(service.deleted.first?.1 != nil)
    }
}

// MARK: - Shortcuts

@Suite("Apple tools: Shortcuts over a fake service")
struct ShortcutsToolExecutionTests {

    @Test("shortcuts_list filters by query and pages")
    func listFilters() async throws {
        let tool = ShortcutsListTool(service: FakeShortcutsService())
        let all = try result(await tool.execute(argumentsJSON: "{}"))
        #expect(all["count"] as? Int == 2)
        let filtered = try result(await tool.execute(argumentsJSON: #"{"query":"water"}"#))
        let items = try #require(filtered["shortcuts"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?["name"] as? String == "Log Water")
        let paged = try result(await tool.execute(argumentsJSON: #"{"limit":1}"#))
        #expect(paged["truncated"] as? Bool == true)
        #expect(paged["total"] as? Int == 2)
    }

    @Test("shortcuts_run requires a name, clamps the timeout, and is a write")
    func runContract() async throws {
        let service = FakeShortcutsService()
        let tool = ShortcutsRunTool(service: service)
        #expect(tool.defaultPermissionPolicy == .ask)
        let missing = try envelope(await tool.execute(argumentsJSON: #"{"input":"x"}"#))
        #expect(missing["kind"] as? String == "invalid_args")
        #expect(missing["field"] as? String == "name")

        let payload = try result(await tool.execute(argumentsJSON: #"{"name":"Morning Brief","input":"hello","timeout_seconds":99999}"#))
        let run = try #require(payload["result"] as? [String: Any])
        #expect(run["output"] as? String == "ran Morning Brief with hello")
        #expect(service.lastRun?.timeout == 600)

        _ = try result(await tool.execute(argumentsJSON: #"{"name":"Morning Brief"}"#))
        #expect(service.lastRun?.timeout == ShortcutsRunTool.defaultTimeout)
        #expect(service.lastRun?.input == nil)

        service.runError = .notFound("No shortcut named `Nope`.")
        let nf = try envelope(await tool.execute(argumentsJSON: #"{"name":"Nope"}"#))
        #expect(nf["kind"] as? String == "not_found")
    }
}

// Intel: the Messages and Maps suites arrive with their staged releases
// (docs/APPLE_APPS_INTEL_PLAN.md).

// MARK: - Contacts argument contracts

private final class FakeContactsService: ContactsServicing, @unchecked Sendable {
    var lastDraft: ContactDraft?
    private func card(_ d: ContactDraft) -> ContactInfo {
        ContactInfo(
            id: "c-1", displayName: "\(d.givenName ?? "") \(d.familyName ?? "")", givenName: d.givenName ?? "",
            familyName: d.familyName ?? "", middleName: nil, nickname: nil, organization: nil, jobTitle: nil,
            department: nil, phones: d.phones ?? [], emails: d.emails ?? [], urls: d.urls ?? [],
            postalAddresses: d.postalAddresses ?? [], birthday: nil, relations: [], socialProfiles: [],
            hasImage: false, openURL: "addressbook://c-1"
        )
    }
    func me() async throws -> ContactInfo? { nil }
    func search(query: String, field: ContactSearchField) async throws -> [ContactSummary] { [] }
    func list(offset: Int, limit: Int) async throws -> (contacts: [ContactSummary], total: Int) { ([], 0) }
    func contact(id: String) async throws -> ContactInfo { throw AppleToolError.notFound("no contact \(id)") }
    func create(_ draft: ContactDraft) async throws -> ContactInfo { lastDraft = draft; return card(draft) }
    func update(id: String, draft: ContactDraft, replaceLabeledValues: Bool) async throws -> ContactInfo { lastDraft = draft; return card(draft) }
}

@Suite("Apple tools: Contacts argument contracts")
struct ContactsToolArgumentContractTests {

    @Test("contacts_create accepts bare strings and {label, value} objects for phones/emails and typed postal addresses")
    func labeledArrays() async throws {
        let fake = FakeContactsService()
        let tool = ContactsCreateTool(service: fake)
        _ = try result(await tool.execute(argumentsJSON: #"""
            {"given_name":"Ada","family_name":"Lovelace",
             "phones":["+15555550100",{"label":"work","value":"+15555550101"},{"label":"home","number":"+15555550102"}],
             "emails":[{"label":"work","email":"ada@example.com"}],
             "postal_addresses":[{"label":"home","street":"1 Analytical Way","city":"London","postal_code":"N1","country":"UK"}]}
            """#))
        let draft = try #require(fake.lastDraft)
        #expect(draft.phones?.map(\.value) == ["+15555550100", "+15555550101", "+15555550102"])
        #expect(draft.phones?.map(\.label) == [nil, "work", "home"])
        #expect(draft.emails == [LabeledValue(label: "work", value: "ada@example.com")])
        #expect(draft.postalAddresses?.first?.postalCode == "N1")
        #expect(draft.postalAddresses?.first?.formatted == "1 Analytical Way, London, N1, UK")
        // Intel: no pre-dispatch schema validator (upstream SchemaValidator is
        // not compiled), so the closed-schema rejection case is not ported.
    }
}
