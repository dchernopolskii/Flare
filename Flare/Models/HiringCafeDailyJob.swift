import Foundation

struct HiringCafeDailyJob: Identifiable, Codable, Equatable {
    let path: String
    let title: String
    let company: String
    let location: String
    let category: String
    let postedAt: Date

    var id: String {
        let slug = path.split(separator: "/").last.map(String.init) ?? path
        return slug.split(separator: "-").last.map(String.init) ?? slug
    }

    var url: URL? {
        URL(string: path, relativeTo: URL(string: "https://hiringcafe.com"))?.absoluteURL
    }

    func matches(query: String, locationQuery: String = "", includeRemote: Bool = false) -> Bool {
        let roleTerms = Self.words(in: query)
        let searchableWords = Set(Self.words(in: [title, company, category]
            .joined(separator: " ")
        ))
        let roleMatches = roleTerms.allSatisfy(searchableWords.contains)
        var locationKeywords = locationQuery.parseAsFilterKeywords()
        if includeRemote && !locationKeywords.isEmpty {
            locationKeywords.append("remote")
        }
        let locationMatches = LocationMatcher.matches(
            location: location,
            locationKeywords: locationKeywords
        )
        return roleMatches && locationMatches
    }

    private static func words(in value: String) -> [String] {
        value.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

struct HiringCafeDailySnapshot: Codable, Equatable {
    let batchDate: Date
    let fetchedAt: Date
    let jobs: [HiringCafeDailyJob]
}
