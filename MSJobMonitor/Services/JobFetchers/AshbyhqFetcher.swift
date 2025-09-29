//
//  AshbyFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/29/25.
//

import Foundation

actor AshbyFetcher: JobFetcherProtocol {
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractAshbySlug(from: url)
        guard let apiURL = URL(string: "https://jobs.ashbyhq.com/api/non-user-boards/\(slug)/jobs") else {
            throw FetchError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: apiURL)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode(AshbyResponse.self, from: data)
        
        // Parse comma-separated filters
        let titleKeywords = parseFilterString(titleFilter)
        let locationKeywords = parseFilterString(locationFilter)
        
        print("🔶 [Ashby] Applying filters - Title keywords: \(titleKeywords), Location keywords: \(locationKeywords)")
        
        return decoded.jobs.compactMap { job -> Job? in
            let location = job.location ?? "Location not specified"
            let title = job.title
            
            // Apply title filter (OR logic - match any keyword)
            if !titleKeywords.isEmpty {
                let titleMatches = titleKeywords.contains { keyword in
                    title.localizedCaseInsensitiveContains(keyword)
                }
                if !titleMatches {
                    print("🔶 [Ashby] Filtered out by title: '\(title)' doesn't match any of \(titleKeywords)")
                    return nil
                }
            }
            
            // Apply location filter (OR logic - match any keyword)
            if !locationKeywords.isEmpty {
                let locationMatches = locationKeywords.contains { keyword in
                    location.localizedCaseInsensitiveContains(keyword)
                }
                if !locationMatches {
                    print("🔶 [Ashby] Filtered out by location: '\(location)' doesn't match any of \(locationKeywords)")
                    return nil
                }
            }
            
            return Job(
                id: "ashby-\(job.id)",
                title: title,
                location: location,
                postingDate: ISO8601DateFormatter().date(from: job.updatedAt ?? ""),
                url: "https://jobs.ashbyhq.com/\(slug)/\(job.id)",
                description: HTMLCleaner.cleanHTML(job.description ?? ""),
                workSiteFlexibility: nil,
                source: .ashby,
                companyName: slug.capitalized,
                department: job.department,
                category: job.team,
                firstSeenDate: Date()
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private func parseFilterString(_ filterString: String) -> [String] {
        guard !filterString.isEmpty else { return [] }
        
        return filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    private func extractAshbySlug(from url: URL) -> String {
        if let host = url.host, host.contains("ashbyhq.com") {
            return url.lastPathComponent
        }
        return url.lastPathComponent
    }
}

// MARK: - Ashby API Models
struct AshbyResponse: Codable {
    let jobs: [AshbyJob]
}

struct AshbyJob: Codable {
    let id: String
    let title: String
    let location: String?
    let description: String?
    let department: String?
    let team: String?
    let updatedAt: String?
}
