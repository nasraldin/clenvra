import Foundation

/// One thing the Overview search can find: a page, an app, a startup item, a scanned file and so on.
public struct SearchEntry: Sendable, Hashable {
    public var title: String
    public var subtitle: String?
    public var keywords: [String]
    /// The raw value of the page the result opens.
    public var destination: String
    /// The text to put in that page's search field, or nil to open the page as it is.
    public var query: String?

    public init(title: String, subtitle: String?, keywords: [String], destination: String, query: String?) {
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.destination = destination
        self.query = query
    }
}

/// Plain text matching shared by every page's search and the Overview index. It only reads: nothing here selects,
/// scans or deletes anything.
public enum AppSearch {
    /// The search text without leading and trailing spaces and new lines.
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `candidate` contains the search text, ignoring case and diacritics as Finder does. An empty search
    /// matches everything, so a page filters nothing until the user types.
    public static func matches(_ text: String, _ candidate: String) -> Bool {
        let query = normalized(text)
        return query.isEmpty || candidate.localizedStandardContains(query)
    }

    /// Entries matching the text: title prefix matches first, then other title matches, then subtitle or keyword
    /// matches. The input order is kept within each rank. An empty text gives no results.
    public static func results(for text: String, in entries: [SearchEntry], limit: Int = 50) -> [SearchEntry] {
        let query = normalized(text)
        guard !query.isEmpty, limit > 0 else { return [] }
        var ranks: [[SearchEntry]] = [[], [], []]
        for entry in entries {
            if let rank = rank(of: entry, query: query) { ranks[rank].append(entry) }
        }
        return Array(ranks.joined().prefix(limit))
    }

    private static func rank(of entry: SearchEntry, query: String) -> Int? {
        if entry.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
            return 0
        }
        if entry.title.localizedStandardContains(query) { return 1 }
        if entry.subtitle?.localizedStandardContains(query) == true
            || entry.keywords.contains(where: { $0.localizedStandardContains(query) })
        {
            return 2
        }
        return nil
    }
}

/// Hands a search from the Overview to the page a result opens. The page takes the query once when it appears;
/// a second take (or a take by another page) gets nothing, so an old query is never applied again.
public struct SearchHandoff: Sendable {
    private var pending: (destination: String, query: String)?

    public init() {}

    /// Records the query for `destination`, replacing any query not taken yet. A nil query clears it.
    public mutating func open(destination: String, query: String?) {
        pending = query.map { (destination, $0) }
    }

    /// The pending query for `destination`, once.
    public mutating func take(for destination: String) -> String? {
        guard let pending, pending.destination == destination else { return nil }
        self.pending = nil
        return pending.query
    }
}
