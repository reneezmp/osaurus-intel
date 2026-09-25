//
//  RecentFoldersStore.swift
//  osaurus
//
//  Process-wide list of the folders the user most recently picked as a
//  working folder, so the composer can offer them instead of sending the user
//  through the open panel for the same few folders again (upstream 3034800ef).
//  Intel adaptation: the app is not sandboxed and folder state is path-based,
//  so entries are plain paths (no security-scoped bookmarks). Only explicit
//  picks record here; defaults adopted by a fresh chat do not.
//

import Foundation

@MainActor
public final class RecentFoldersStore: ObservableObject {
    public static let shared = RecentFoldersStore()

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public let path: String
        public var id: String { path }
        public var name: String { (path as NSString).lastPathComponent }
    }

    @Published public private(set) var entries: [Entry] = []

    public static let limit = 5
    static let defaultsKey = "RecentWorkingFolders"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        {
            entries = Array(decoded.prefix(Self.limit))
        }
    }

    public func record(path: String) {
        var normalized = Substring(path)
        while normalized.count > 1, normalized.hasSuffix("/") { normalized = normalized.dropLast() }
        guard !normalized.isEmpty else { return }
        let entry = Entry(path: String(normalized))
        var next = entries.filter { $0.path != entry.path }
        next.insert(entry, at: 0)
        if next.count > Self.limit { next = Array(next.prefix(Self.limit)) }
        guard next != entries else { return }
        entries = next
        save()
    }

    public func remove(path: String) {
        let before = entries.count
        entries.removeAll { $0.path == path }
        guard entries.count != before else { return }
        save()
    }

    /// The entry's folder if it still exists; checked off the main actor.
    public nonisolated static func resolveURL(for entry: Entry) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return URL(fileURLWithPath: entry.path, isDirectory: true)
        }.value
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
