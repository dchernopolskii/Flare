//
//  GreenhouseFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

// MARK: - Greenhouse API Models
struct GreenhouseResponse: Codable {
    let jobs: [GreenhouseJob]
}

struct GreenhouseJob: Codable {
    let id: Int
    let title: String
    let absolute_url: String
    let location: GreenhouseLocation?
    let updated_at: String?
    let content: String?
    let departments: [GreenhouseDepartment]?
    
    struct GreenhouseLocation: Codable {
        let name: String
    }
    
    struct GreenhouseDepartment: Codable {
        let name: String
    }
}

// MARK: - Greenhouse Fetcher
actor GreenhouseFetcher: JobFetcherProtocol {
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchGreenhouseJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let boardSlug = extractGreenhouseBoardSlug(from: url)
        
        let apiURL = URL(string: "https://boards-api.greenhouse.io/v1/boards/\(boardSlug)/jobs?content=true")!
        print("🌱 [Greenhouse] Fetching API: \(apiURL)")
        
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            print("🌱 [Greenhouse] HTTP Error: Status code \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("🌱 [Greenhouse] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        do {
            let decoded = try JSONDecoder().decode(GreenhouseResponse.self, from: data)
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            
            let fallbackFormatter = ISO8601DateFormatter()
            fallbackFormatter.formatOptions = [.withInternetDateTime]
            
            // Parse comma-separated filters
            let titleKeywords = parseFilterString(titleFilter)
            let locationKeywords = parseFilterString(locationFilter)
            
            print("🌱 [Greenhouse] Applying filters - Title keywords: \(titleKeywords), Location keywords: \(locationKeywords)")
            
            let jobs = decoded.jobs.compactMap { ghJob -> Job? in
                var postingDate = Date()
                if let dateString = ghJob.updated_at {
                    postingDate = formatter.date(from: dateString)
                               ?? fallbackFormatter.date(from: dateString)
                               ?? Date()
                }
                
                let location = ghJob.location?.name ?? "Location not specified"
                let title = ghJob.title
                
                // Apply title filter (OR logic - match any keyword)
                if !titleKeywords.isEmpty {
                    let titleMatches = titleKeywords.contains { keyword in
                        title.localizedCaseInsensitiveContains(keyword)
                    }
                    if !titleMatches {
                        print("🌱 [Greenhouse] Filtered out by title: '\(title)' doesn't match any of \(titleKeywords)")
                        return nil
                    }
                }
                
                // Apply location filter (OR logic - match any keyword)
                if !locationKeywords.isEmpty {
                    let locationMatches = locationKeywords.contains { keyword in
                        location.localizedCaseInsensitiveContains(keyword)
                    }
                    if !locationMatches {
                        print("🌱 [Greenhouse] Filtered out by location: '\(location)' doesn't match any of \(locationKeywords)")
                        return nil
                    }
                }
                
                let cleanDescription = HTMLCleaner.cleanHTML(ghJob.content ?? "")
                
                return Job(
                    id: "gh-\(ghJob.id)",
                    title: title,
                    location: location,
                    postingDate: postingDate,
                    url: ghJob.absolute_url,
                    description: cleanDescription,
                    workSiteFlexibility: extractWorkFlexibility(from: cleanDescription),
                    source: .greenhouse,
                    companyName: extractCompanyName(from: url),
                    department: ghJob.departments?.first?.name,
                    category: nil,
                    firstSeenDate: Date()
                )
            }
            
            print("🌱 [Greenhouse] Parsed \(jobs.count) jobs from API (after filtering)")
            return jobs
            
        } catch {
            print("🌱 [Greenhouse] JSON Parsing Error: \(error)")
            throw FetchError.parsingFailed
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
    
    private func extractGreenhouseBoardSlug(from url: URL) -> String {
        let pathComponents = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        
        if url.host?.contains("boards.greenhouse.io") == true ||
           url.host?.contains("job-boards.greenhouse.io") == true {
            return pathComponents.first ?? "unknown"
        } else if url.host?.hasSuffix("greenhouse.io") == true {
            if let host = url.host,
               let companyName = host.components(separatedBy: ".").first {
                return companyName
            }
        }
        
        return pathComponents.first ?? "unknown"
    }
    
    private func extractCompanyName(from url: URL) -> String {
        let slug = extractGreenhouseBoardSlug(from: url)
        // Capitalize first letter of each word
        return slug.split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
    
    private func extractWorkFlexibility(from description: String) -> String? {
        let flexibilityKeywords = ["remote", "hybrid", "flexible", "work from home", "onsite", "on-site"]
        let lowercased = description.lowercased()
        
        for keyword in flexibilityKeywords {
            if lowercased.contains(keyword) {
                return keyword.capitalized
            }
        }
        
        return nil
    }
}
