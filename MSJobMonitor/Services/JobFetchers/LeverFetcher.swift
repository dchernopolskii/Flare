//
//  LeverFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor LeverFetcher: JobFetcherProtocol {
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractLeverSlug(from: url)
        guard let apiURL = URL(string: "https://jobs.lever.co/\(slug)?mode=json") else {
            throw FetchError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode([LeverJob].self, from: data)
        
        // Parse comma-separated filters
        let titleKeywords = parseFilterString(titleFilter)
        let locationKeywords = parseFilterString(locationFilter)
        
        print("🎚️ [Lever] Applying filters - Title keywords: \(titleKeywords), Location keywords: \(locationKeywords)")
        
        return decoded.compactMap { job -> Job? in
            let location = job.categories.location ?? "Location not specified"
            let title = job.text
            
            // Apply title filter (OR logic - match any keyword)
            if !titleKeywords.isEmpty {
                let titleMatches = titleKeywords.contains { keyword in
                    title.localizedCaseInsensitiveContains(keyword)
                }
                if !titleMatches {
                    print("🎚️ [Lever] Filtered out by title: '\(title)' doesn't match any of \(titleKeywords)")
                    return nil
                }
            }
            
            // Apply location filter (OR logic - match any keyword)
            if !locationKeywords.isEmpty {
                let locationMatches = locationKeywords.contains { keyword in
                    location.localizedCaseInsensitiveContains(keyword)
                }
                if !locationMatches {
                    print("🎚️ [Lever] Filtered out by location: '\(location)' doesn't match any of \(locationKeywords)")
                    return nil
                }
            }
            
            return Job(
                id: "lever-\(job.id)",
                title: title,
                location: location,
                postingDate: ISO8601DateFormatter().date(from: job.createdAt),
                url: job.hostedUrl,
                description: job.descriptionPlain,
                workSiteFlexibility: nil,
                source: .lever,
                companyName: slug.capitalized,
                department: job.categories.team,
                category: job.categories.commitment,
                firstSeenDate: Date()
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func parseFilterString(_ filterString: String, includeRemote: Bool = true) -> [String] {
        guard !filterString.isEmpty else { return [] }
        
        var keywords = filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if includeRemote {
            let remoteKeywords = ["remote", "work from home", "distributed", "anywhere"]
            let hasRemoteKeyword = keywords.contains { keyword in
                remoteKeywords.contains { remote in
                    keyword.localizedCaseInsensitiveContains(remote)
                }
            }
            
            if !hasRemoteKeyword {
                keywords.append("remote")
            }
        }
        
        return keywords
    }
    
    private func extractLeverSlug(from url: URL) -> String {
        if let host = url.host, host.contains("lever.co") {
            let parts = url.pathComponents.filter { !$0.isEmpty }
            return parts.first ?? host.replacingOccurrences(of: ".lever.co", with: "")
        }
        return url.lastPathComponent
    }
}

// MARK: - Lever API Model
struct LeverJob: Codable {
    let id: String
    let text: String
    let createdAt: String
    let hostedUrl: String
    let descriptionPlain: String
    let categories: Categories
    
    struct Categories: Codable {
        let team: String?
        let commitment: String?
        let location: String?
    }
}
