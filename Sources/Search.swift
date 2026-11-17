import Foundation

// MARK: - Natural-language query -> Spotlight predicate (fully on-device)

/// Understands things like "pdf about taxes last week", "images bigger than 5 mb", "invoice yesterday".
struct SmartQuery {
    var words: [String] = []          // plain words (used for the instant local name match)
    var groups: [[String]] = []       // every group must match; words inside a group are alternatives
    var types: [String] = []          // UTIs, OR-ed together
    var typeLabels: [String] = []
    var since: Date?
    var until: Date?
    var minSize: Int64?
    var maxSize: Int64?
    var dateLabel: String?
    var sizeLabels: [String] = []

    private static let docs = ["com.adobe.pdf", "public.plain-text", "public.rtf", "com.microsoft.word.doc",
                               "org.openxmlformats.wordprocessingml.document", "com.apple.iwork.pages.sffpages",
                               "org.oasis-open.opendocument.text"]
    private static let sheets = ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls",
                                 "public.comma-separated-values-text", "com.apple.iwork.numbers.sffnumbers"]
    private static let slides = ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt",
                                 "com.apple.iwork.keynote.sffkey"]

    static let typeMap: [(names: [String], label: String, utis: [String])] = [
        (["pdf", "pdfs"], "PDF", ["com.adobe.pdf"]),
        (["image", "images", "photo", "photos", "picture", "pictures", "png", "jpg", "jpeg"], "images", ["public.image"]),
        (["video", "videos", "movie", "movies"], "videos", ["public.movie"]),
        (["audio", "music", "song", "songs", "sound", "sounds"], "audio", ["public.audio"]),
        (["document", "documents", "doc", "docs", "word", "text"], "documents", docs),
        (["spreadsheet", "spreadsheets", "excel", "csv"], "spreadsheets", sheets),
        (["presentation", "presentations", "slides", "slide", "deck", "decks", "powerpoint", "keynote"], "presentations", slides),
        (["archive", "archives", "zip", "zips"], "archives", ["public.archive"]),
        (["folder", "folders", "directory", "directories"], "folders", ["public.folder"]),
        (["code", "script", "scripts", "source"], "code", ["public.source-code"]),
    ]

    private static let stop: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "to", "for", "from", "with", "about", "my", "me", "and", "or",
        "file", "files", "named", "called", "name", "containing", "contains", "contain", "that", "which", "is",
        "are", "was", "were", "has", "have", "mentioning", "mention", "regarding", "related", "find", "show",
        "search", "all", "any", "some", "those", "these", "it", "i", "by", "modified", "changed", "created", "than",
    ]

    /// Removes the first regex match from `t` and returns its capture groups.
    private static func take(_ pattern: String, _ t: inout String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        let groups = (1..<m.numberOfRanges).map { i -> String in
            Range(m.range(at: i), in: t).map { String(t[$0]) } ?? ""
        }
        t.replaceSubrange(Range(m.range, in: t)!, with: " ")
        return groups
    }

    private static func bytes(_ n: String, _ unit: String) -> Int64 {
        let v = Double(n) ?? 0
        switch unit.first {
        case "k": return Int64(v * 1_000)
        case "g": return Int64(v * 1_000_000_000)
        default: return Int64(v * 1_000_000)
        }
    }

    static func parse(_ raw: String, now: Date = Date()) -> SmartQuery {
        var q = SmartQuery()
        var t = " " + raw.lowercased() + " "
        let cal = Calendar.current
        let num = #"(\d+(?:\.\d+)?)\s*(kb|mb|gb|k|m|g)\b"#

        // sizes
        if let g = take(#"(?:bigger|larger|greater|heavier|over|above|more|>)\s*(?:than)?\s*"# + num, &t) {
            q.minSize = bytes(g[0], g[1]); q.sizeLabels.append("bigger than \(g[0]) \(g[1].uppercased())")
        }
        if let g = take(#"(?:smaller|lighter|less|under|below|<)\s*(?:than)?\s*"# + num, &t) {
            q.maxSize = bytes(g[0], g[1]); q.sizeLabels.append("smaller than \(g[0]) \(g[1].uppercased())")
        }

        // dates
        func ago(_ n: Int, _ unit: String) -> Date? {
            let comp: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : unit.hasPrefix("month") ? .month : .year
            return cal.date(byAdding: comp, value: -n, to: now)
        }
        if let g = take(#"\b(?:last|past)\s+(\d+)\s+(days?|weeks?|months?|years?)\b"#, &t), let d = ago(Int(g[0]) ?? 1, g[1]) {
            q.since = d; q.dateLabel = "in the last \(g[0]) \(g[1])"
        } else if let g = take(#"\b(?:last|past)\s+(week|month|year)\b"#, &t), let d = ago(1, g[0]) {
            q.since = d; q.dateLabel = "in the last \(g[0])"
        } else if let g = take(#"\bthis\s+(week|month|year)\b"#, &t) {
            let comp: Calendar.Component = g[0] == "week" ? .weekOfYear : g[0] == "month" ? .month : .year
            q.since = cal.dateInterval(of: comp, for: now)?.start; q.dateLabel = "this \(g[0])"
        } else if take(#"\byesterday\b"#, &t) != nil {
            let today = cal.startOfDay(for: now)
            q.since = cal.date(byAdding: .day, value: -1, to: today); q.until = today; q.dateLabel = "yesterday"
        } else if take(#"\btoday\b"#, &t) != nil {
            q.since = cal.startOfDay(for: now); q.dateLabel = "today"
        } else if take(#"\brecent(?:ly)?\b"#, &t) != nil {
            q.since = cal.date(byAdding: .day, value: -7, to: now); q.dateLabel = "recent (7 days)"
        }

        // words and types
        let sep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted
        for tok in t.components(separatedBy: sep) where !tok.isEmpty {
            if let kind = typeMap.first(where: { $0.names.contains(tok) }) {
                // png/jpg/csv/text style tokens also stay searchable as words when they look like extensions
                if !q.typeLabels.contains(kind.label) { q.typeLabels.append(kind.label); q.types += kind.utis }
                continue
            }
            if stop.contains(tok) || tok.count < 2 { continue }
            q.words.append(tok)
        }
        q.groups = q.words.map { [$0] }
        return q
    }

    var isEmpty: Bool { groups.isEmpty && words.isEmpty && types.isEmpty && since == nil && minSize == nil && maxSize == nil }

    var summary: String {
        var parts: [String] = []
        if !typeLabels.isEmpty { parts.append(typeLabels.joined(separator: " + ")) }
        if let d = dateLabel { parts.append(d) }
        parts += sizeLabels
        if !groups.isEmpty { parts.append("name or content has " + groups.map { "“" + $0.joined(separator: " | ") + "”" }.joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }

    var predicate: NSPredicate? {
        var parts: [NSPredicate] = []
        for g in groups {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: g.flatMap { w in [
                NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemDisplayName", w),
                NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", w),
            ] }))
        }
        if !types.isEmpty {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates:
                types.map { NSPredicate(format: "%K == %@", "kMDItemContentTypeTree", $0) }))
        }
        if let s = since { parts.append(NSPredicate(format: "%K >= %@", "kMDItemFSContentChangeDate", s as NSDate)) }
        if let u = until { parts.append(NSPredicate(format: "%K < %@", "kMDItemFSContentChangeDate", u as NSDate)) }
        if let n = minSize { parts.append(NSPredicate(format: "%K >= %@", "kMDItemFSSize", NSNumber(value: n))) }
        if let n = maxSize { parts.append(NSPredicate(format: "%K <= %@", "kMDItemFSSize", NSNumber(value: n))) }
        return parts.isEmpty ? nil : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }
}

// MARK: - Spotlight runner

final class SpotlightSearch {
    private var query: NSMetadataQuery?
    private var tokens: [NSObjectProtocol] = []

    func stop() {
        query?.stop()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        query = nil
    }

    /// Calls `done` on the main queue with matching paths (newest first); may be called again as the index updates.
    func start(_ predicate: NSPredicate, scope: String, limit: Int = 500, done: @escaping ([String]) -> Void) {
        stop()
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = [scope]
        q.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)]
        let grab: (Notification) -> Void = { [weak q] _ in
            guard let q else { return }
            q.disableUpdates()
            let n = min(q.resultCount, limit)
            let paths = (0..<n).compactMap { (q.result(at: $0) as? NSMetadataItem)?.value(forAttribute: "kMDItemPath") as? String }
            q.enableUpdates()
            done(paths)
        }
        tokens = [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate].map {
            NotificationCenter.default.addObserver(forName: $0, object: q, queue: .main, using: grab)
        }
        query = q
        q.start()
    }
}
