import Foundation
import Security

// MARK: - Keychain (the OpenAI key never touches disk in plain text or the repo)

enum Keychain {
    static let service = "dev.nook.app"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = base(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - OpenAI query understanding

/// Sends ONLY the text typed in the search box to OpenAI and gets back structured filters.
/// Searching itself (names and contents) always runs locally through Spotlight.
enum AISearch {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "aiSearch") }
    static var model: String {
        let m = UserDefaults.standard.string(forKey: "aiModel") ?? ""
        return m.isEmpty ? "gpt-4o-mini" : m
    }
    /// Remembered in UserDefaults so the UI never has to open the Keychain just to draw itself.
    static var hasKey: Bool {
        get { UserDefaults.standard.object(forKey: "aiHasKey") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "aiHasKey"); cachedKey = nil }
    }
    private static var cachedKey: String?

    /// Reads the Keychain (once per run). Only called when an AI search actually happens.
    static var key: String? {
        if let c = cachedKey { return c }
        let k = (Keychain.get("openai") ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        cachedKey = k.isEmpty ? nil : k
        return cachedKey
    }
    static var ready: Bool { enabled && hasKey }   // no Keychain access here

    private static let labels = SmartQuery.typeMap.map(\.label).joined(separator: "\" | \"")

    private static func system(now: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return """
        You turn a natural-language file-search request into filters for macOS Spotlight. Reply with JSON only:
        {"keywords": [["word", "synonym", "translation"], ["other", "synonym"]],
         "types": ["\(labels)"],
         "since": "YYYY-MM-DD" or null, "until": "YYYY-MM-DD" or null,
         "min_mb": number or null, "max_mb": number or null,
         "sort": "newest" or "oldest" or null}
        Rules: "keywords" is a list of groups. Every group must match (AND). Words inside a group are alternatives (OR): \
        synonyms, translations (e.g. invoice, rechnung, faktura), singular/plural and spelling variants. \
        Every distinct thing the user names (a person, a company, a kind of document) is its OWN group, never merge different things into one group. \
        Example: "nyra cv" -> [["nyra"], ["cv", "resume", "lebenslauf"]]. Ignore filler words like find, me, please, file. \
        Set "sort" to "newest" if the user wants the latest / last / most recent version or revision, "oldest" for the earliest, otherwise null. \
        A file type word (pdf, image, ...) goes into "types", not into "keywords". \
        Words like last, latest, newest, newer, recent, final, oldest are NEVER keywords: they only set "sort". \
        Use short lowercase words and no stop words. Use "types" only from the allowed list, only if the user named a kind of file. \
        Leave out anything the user did not ask for. Today is \(f.string(from: now)).
        """
    }

    static func interpret(_ text: String, completion: @escaping (SmartQuery?, String?) -> Void) {
        guard let key else { return completion(nil, "no API key") }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [["role": "system", "content": system(now: Date())], ["role": "user", "content": text]],
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            func done(_ q: SmartQuery?, _ e: String?) { DispatchQueue.main.async { completion(q, e) } }
            if let err { return done(nil, err.localizedDescription) }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                return done(nil, code == 401 ? "invalid API key" : code == 429 ? "rate limit or no credit" : "OpenAI error \(code)")
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = ((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
                  let json = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                  let q = SmartQuery.from(ai: json) else { return done(nil, "unreadable answer") }
            done(q, nil)
        }.resume()
    }
}

extension SmartQuery {
    /// Maps the model's JSON answer onto a query. Returns nil if it asked for nothing.
    static func from(ai json: [String: Any]) -> SmartQuery? {
        var q = SmartQuery()
        for g in (json["keywords"] as? [Any]) ?? [] {
            let group = ((g as? [String]) ?? (g as? String).map { [$0] } ?? [])
                .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }
            if !group.isEmpty { q.groups.append(group) }
        }
        // Safety net: "last/latest/..." must never act as a search word.
        let newestWords: Set<String> = ["last", "latest", "newest", "newer", "recent", "final", "new"]
        var sawNewest = false, sawOldest = false
        q.groups = q.groups.compactMap { g in
            let kept = g.filter { w in
                if newestWords.contains(w) { sawNewest = true; return false }
                if w == "oldest" || w == "earliest" { sawOldest = true; return false }
                return true
            }
            return kept.isEmpty ? nil : kept
        }
        q.words = q.groups.compactMap(\.first)
        for t in (json["types"] as? [String]) ?? [] {
            if let k = typeMap.first(where: { $0.label.lowercased() == t.lowercased() }), !q.typeLabels.contains(k.label) {
                q.typeLabels.append(k.label); q.types += k.utis
            }
        }
        if let s = (json["sort"] as? String)?.lowercased(), s == "newest" || s == "oldest" { q.sort = s }
        else if sawNewest { q.sort = "newest" } else if sawOldest { q.sort = "oldest" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        if let s = (json["since"] as? String).flatMap(f.date(from:)) { q.since = s }
        if let u = (json["until"] as? String).flatMap(f.date(from:)) { q.until = Calendar.current.date(byAdding: .day, value: 1, to: u) }
        if q.since != nil || q.until != nil {
            q.dateLabel = [q.since.map { "from " + f.string(from: $0) }, (json["until"] as? String).map { "until " + $0 }].compactMap { $0 }.joined(separator: " ")
        }
        if let mb = (json["min_mb"] as? NSNumber)?.doubleValue { q.minSize = Int64(mb * 1_000_000); q.sizeLabels.append("bigger than \(mb) MB") }
        if let mb = (json["max_mb"] as? NSNumber)?.doubleValue { q.maxSize = Int64(mb * 1_000_000); q.sizeLabels.append("smaller than \(mb) MB") }
        return q.isEmpty ? nil : q
    }
}
