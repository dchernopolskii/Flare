//
//  AshbyFetcher.swift
//  MSJobMonitor
//
//
//

import Foundation

actor AshbyFetcher: JobFetcherProtocol {
    
    // Add tracking data structure
    private struct JobTrackingData: Codable {
        let id: String
        let firstSeenDate: Date
    }
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let slug = extractAshbySlug(from: url)
        
        let storedJobDates = await loadJobTrackingData(company: slug)
        let currentDate = Date()
        
        let jobs = try await fetchJobsViaGraphQL(slug: slug)
        
        let titleKeywords = parseFilterString(titleFilter, includeRemote: false)
        let locationKeywords = parseFilterString(locationFilter, includeRemote: false)
        
        let filteredJobs = jobs.compactMap { job -> Job? in
            let location = job.locationName ?? "Location not specified"
            let title = job.title
            
            if !titleKeywords.isEmpty {
                let titleMatches = titleKeywords.contains { keyword in
                    title.localizedCaseInsensitiveContains(keyword)
                }
                if !titleMatches {
                    return nil
                }
            }
            
            if !locationKeywords.isEmpty {
                let locationMatches = locationKeywords.contains { keyword in
                    location.localizedCaseInsensitiveContains(keyword)
                }
                if !locationMatches {
                    return nil
                }
            }
            
            var fullLocation = location
            if !job.secondaryLocations.isEmpty {
                let secondaryLocs = job.secondaryLocations.map { $0.locationName }.joined(separator: ", ")
                fullLocation += " (+ \(secondaryLocs))"
            }
            
            // Use stored date if job was seen before, otherwise use current date
            let jobId = "ashby-\(job.id)"
            let firstSeenDate = storedJobDates[jobId] ?? currentDate
            
            return Job(
                id: jobId,
                title: title,
                location: fullLocation,
                postingDate: nil,
                url: "https://jobs.ashbyhq.com/\(slug)/\(job.id)",
                description: job.compensationTierSummary ?? "",
                workSiteFlexibility: job.workplaceType,
                source: .ashby,
                companyName: slug.capitalized,
                department: nil,
                category: nil,
                firstSeenDate: firstSeenDate  // ✅ Use persisted date
            )
        }
        
        await saveJobTrackingData(filteredJobs, company: slug, currentDate: currentDate)
        return filteredJobs
    }
    
    // MARK: - Persistence Methods
    
    private func loadJobTrackingData(company: String) async -> [String: Date] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("ashby_\(company)_tracking.json")
        
        do {
            let data = try Data(contentsOf: url)
            let trackingData = try JSONDecoder().decode([JobTrackingData].self, from: data)
            
            var dict: [String: Date] = [:]
            for item in trackingData {
                dict[item.id] = item.firstSeenDate
            }
            
            return dict
        } catch {
            return [:]
        }
    }
    
    private func saveJobTrackingData(_ jobs: [Job], company: String, currentDate: Date) async {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("ashby_\(company)_tracking.json")
        
        do {
            var existingData = await loadJobTrackingData(company: company)
            
            for job in jobs {
                if existingData[job.id] == nil {
                    existingData[job.id] = currentDate
                }
            }
            
            let trackingData = existingData.map { JobTrackingData(id: $0.key, firstSeenDate: $0.value) }
            
            let cutoffDate = Date().addingTimeInterval(-60 * 24 * 3600)
            let recentData = trackingData.filter { $0.firstSeenDate > cutoffDate }
            
            let data = try JSONEncoder().encode(recentData)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            print("🔶 [Ashby] Failed to save job tracking data: \(error)")
        }
    }
    
    // MARK: - GraphQL API Call
    
    private func fetchJobsViaGraphQL(slug: String) async throws -> [AshbyJobPosting] {
        let apiURL = URL(string: "https://jobs.ashbyhq.com/api/non-user-graphql?op=ApiJobBoardWithTeams")!
        
        let query = """
        query ApiJobBoardWithTeams($organizationHostedJobsPageName: String!) {
          jobBoard: jobBoardWithTeams(
            organizationHostedJobsPageName: $organizationHostedJobsPageName
          ) {
            teams {
              id
              name
              parentTeamId
            }
            jobPostings {
              id
              title
              teamId
              locationId
              locationName
              workplaceType
              employmentType
              secondaryLocations {
                locationId
                locationName
              }
              compensationTierSummary
            }
          }
        }
        """
        
        let variables: [String: Any] = [
            "organizationHostedJobsPageName": slug
        ]
        
        let requestBody: [String: Any] = [
            "operationName": "ApiJobBoardWithTeams",
            "query": query,
            "variables": variables
        ]
        
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode(AshbyGraphQLResponse.self, from: data)
        
        guard let jobPostings = decoded.data.jobBoard?.jobPostings else {
            throw FetchError.decodingError(details: "Failed to decode Ashby response")
        }
        
        return jobPostings
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
    
    private func extractAshbySlug(from url: URL) -> String {
        if let host = url.host, host.contains("ashbyhq.com") {
            return url.lastPathComponent
        }
        return url.lastPathComponent
    }
}

// MARK: - Ashby GraphQL Models

struct AshbyGraphQLResponse: Codable {
    let data: AshbyData
}

struct AshbyData: Codable {
    let jobBoard: AshbyJobBoard?
}

struct AshbyJobBoard: Codable {
    let teams: [AshbyTeam]
    let jobPostings: [AshbyJobPosting]
}

struct AshbyTeam: Codable {
    let id: String
    let name: String
    let parentTeamId: String?
}

struct AshbyJobPosting: Codable {
    let id: String
    let title: String
    let teamId: String
    let locationId: String?
    let locationName: String?
    let workplaceType: String?
    let employmentType: String?
    let secondaryLocations: [AshbySecondaryLocation]
    let compensationTierSummary: String?
}

struct AshbySecondaryLocation: Codable {
    let locationId: String
    let locationName: String
}
