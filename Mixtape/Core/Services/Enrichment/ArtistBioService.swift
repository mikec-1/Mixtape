// ArtistBioService.swift
// Mixtape — Core/Services/Enrichment
//
// A paragraph about the artist for the About block. Deezer's catalogue has no
// biography, so this asks Wikipedia's REST summary endpoint — no key, no
// scraping, one small JSON per artist — and caches what comes back for the
// session.

import Foundation

actor ArtistBioService {

    static let shared = ArtistBioService()

    private var cache: [String: String?] = [:]

    /// The opening paragraph of the artist's Wikipedia article, or nil when
    /// there isn't one we can trust. Disambiguation pages are dropped: a page
    /// listing seven people with this name is not a biography of any of them.
    func bio(for artistName: String) async -> String? {
        let key = artistName.lowercased()
        if let hit = cache[key] { return hit }

        // Bare name first, then the disambiguated titles a musician actually
        // lives under, then Wikipedia's own search — which is what finds the
        // ones whose article is titled something else entirely.
        var text = await fetch(artistName)
        for suffix in ["(rapper)", "(musician)", "(band)", "(singer)"] where text == nil {
            text = await fetch("\(artistName) \(suffix)")
        }
        if text == nil, let title = await searchTitle(artistName) {
            text = await fetch(title)
        }
        cache[key] = text
        return text
    }

    private func fetch(_ title: String) async -> String? {
        var path = title.replacingOccurrences(of: " ", with: "_")
        path = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(path)") else { return nil }

        var request = URLRequest(url: url)
        // Wikimedia asks for a contact-bearing agent and throttles anonymous ones.
        request.setValue("Mixtape/1.0 (https://mixtaped.tech)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String != "disambiguation",
              let extract = (json["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty
        else { return nil }
        return extract
    }

    /// Wikipedia's own search, restricted to musician-ish articles. Used only
    /// when guessing the title failed.
    private func searchTitle(_ artistName: String) async -> String? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            .init(name: "action", value: "query"),
            .init(name: "list", value: "search"),
            .init(name: "srsearch", value: "\(artistName) musician"),
            .init(name: "srlimit", value: "1"),
            .init(name: "format", value: "json")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mixtape/1.0 (https://mixtaped.tech)", forHTTPHeaderField: "User-Agent")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let hits = query["search"] as? [[String: Any]],
              let title = hits.first?["title"] as? String
        else { return nil }
        return title
    }
}
