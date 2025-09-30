//
//  AppleFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/29/25.
//

import Foundation

actor AppleFetcher: JobFetcherProtocol {
    private let searchURL = URL(string: "https://jobs.apple.com/api/v1/search")!
    private let locationURL = URL(string: "https://jobs.apple.com/api/v1/refData/postlocation")!
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        print("🍎 [Apple] Starting Apple job fetch...")
        
        var allJobs: [Job] = []
        let pageSize = 20
        
        let locationFilters = try await resolveMultipleLocations(location)
        print("🍎 [Apple] Resolved locations: \(locationFilters)")
        
        let titleKeywords = titleKeywords.filter { !$0.isEmpty }
        
        if locationFilters.isEmpty {
            let jobs = try await fetchJobsWithLocationFilters(
                locationFilters: [],
                titleKeywords: titleKeywords,
                maxPages: maxPages,
                pageSize: pageSize
            )
            allJobs.append(contentsOf: jobs)
        } else if locationFilters.count == 1 {
            let jobs = try await fetchJobsWithLocationFilters(
                locationFilters: locationFilters,
                titleKeywords: titleKeywords,
                maxPages: maxPages,
                pageSize: pageSize
            )
            allJobs.append(contentsOf: jobs)
        } else {
            print("🍎 [Apple] Multiple locations detected, using client-side filtering")
            let jobs = try await fetchJobsWithLocationFilters(
                locationFilters: [],
                titleKeywords: titleKeywords,
                maxPages: maxPages,
                pageSize: pageSize
            )
            
            let locationKeywords = parseLocationString(location)
            let filteredJobs = jobs.filter { job in
                locationKeywords.isEmpty || locationKeywords.contains { keyword in
                    job.location.localizedCaseInsensitiveContains(keyword)
                }
            }
            
            print("🍎 [Apple] Client-side filtered \(jobs.count) -> \(filteredJobs.count) jobs")
            allJobs.append(contentsOf: filteredJobs)
        }
        
        print("🍎 [Apple] Completed fetch: \(allJobs.count) jobs")
        return allJobs
    }
    
    private func resolveMultipleLocations(_ locationString: String) async throws -> [String] {
        guard !locationString.isEmpty else { return [] }
        
        let locations = parseLocationString(locationString)
        var resolvedIds: [String] = []
        
        for location in locations.prefix(3) {
            if location.localizedCaseInsensitiveContains("remote") ||
               location.localizedCaseInsensitiveContains("anywhere") {
                continue
            }
            
            if let locationId = try await resolveLocationId(location) {
                resolvedIds.append(locationId)
                print("🍎 [Apple] Resolved '\(location)' -> \(locationId)")
            } else {
                print("🍎 [Apple] Could not resolve location: '\(location)'")
            }
            
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        
        return resolvedIds
    }
    
    private func fetchJobsWithLocationFilters(locationFilters: [String], titleKeywords: [String], maxPages: Int, pageSize: Int) async throws -> [Job] {
        var allJobs: [Job] = []
        
        for page in 0..<maxPages {
            print("🍎 [Apple] Fetching page \(page + 1)...")
            
            let pageJobs = try await fetchJobsPage(
                offset: page * pageSize,
                limit: pageSize,
                locationFilters: locationFilters,
                titleKeywords: titleKeywords
            )
            
            if pageJobs.isEmpty {
                print("🍎 [Apple] No more jobs, stopping at page \(page + 1)")
                break
            }
            
            allJobs.append(contentsOf: pageJobs)
            
            if pageJobs.count < pageSize {
                print("🍎 [Apple] Last page (\(pageJobs.count) jobs)")
                break
            }
            
            // Rate limiting
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        return allJobs
    }
    
    private func fetchJobsPage(offset: Int, limit: Int, locationFilters: [String], titleKeywords: [String]) async throws -> [Job] {
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        var searchBody: [String: Any] = [
            "offset": offset,
            "limit": limit,
            "sortBy": "postingDate",
            "sortOrder": "desc"
        ]
        
        if locationFilters.count == 1 {
            searchBody["postLocation"] = locationFilters
        }

        if !titleKeywords.isEmpty {
            searchBody["search"] = titleKeywords.joined(separator: " ")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: searchBody)
        request.httpBody = jsonData
        
        if offset == 0 {
            if let debugBody = String(data: jsonData, encoding: .utf8) {
                print("🍎 [Apple] Request body: \(debugBody)")
            }
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            print("🍎 [Apple] HTTP Error: \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("🍎 [Apple] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(AppleSearchResponse.self, from: data)
        
        guard let searchResults = decoded.res?.searchResults else {
            return []
        }
        
        let jobs = searchResults.compactMap { convertAppleJob($0) }
        let filteredJobs = applyClientSideFiltering(jobs, titleKeywords: titleKeywords)
        
        print("🍎 [Apple] Page returned \(searchResults.count) jobs, \(filteredJobs.count) after filtering")
        return filteredJobs
    }
    
    private func parseLocationString(_ locationString: String) -> [String] {
        guard !locationString.isEmpty else { return [] }
        
        return locationString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    
    func fetchJobs(from url: URL, titleFilter: String, locationFilter: String) async throws -> [Job] {
        let titleKeywords = parseFilterString(titleFilter)
        let locationKeywords = parseFilterString(locationFilter)
        
        return try await fetchJobs(
            titleKeywords: titleKeywords, 
            location: locationKeywords.joined(separator: ","), 
            maxPages: 5
        )
    }
    
    // MARK: -
    
    private func fetchJobsPage(offset: Int, limit: Int, locationFilter: String?, titleKeywords: [String]) async throws -> [Job] {
        var request = URLRequest(url: searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        var searchBody: [String: Any] = [
            "offset": offset,
            "limit": limit,
            "sortBy": "postingDate",
            "sortOrder": "desc"
        ]
        
        if let locationFilter = locationFilter {
            searchBody["postLocation"] = [locationFilter]
        }
        
        if !titleKeywords.isEmpty {
            searchBody["search"] = titleKeywords.joined(separator: " ")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: searchBody)
        request.httpBody = jsonData
        
        if offset == 0 {
            if let debugBody = String(data: jsonData, encoding: .utf8) {
                print("🍎 [Apple] Request body: \(debugBody)")
            }
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            print("🍎 [Apple] HTTP Error: \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("🍎 [Apple] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(AppleSearchResponse.self, from: data)
        
        guard let searchResults = decoded.res?.searchResults else {
            return []
        }
        
        let jobs = searchResults.compactMap { convertAppleJob($0) }
        let filteredJobs = applyClientSideFiltering(jobs, titleKeywords: titleKeywords)
        
        print("🍎 [Apple] Page returned \(searchResults.count) jobs, \(filteredJobs.count) after filtering")
        return filteredJobs
    }
    
    private func resolveLocationId(_ locationQuery: String) async throws -> String? {
        var components = URLComponents(url: locationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "input", value: locationQuery)]
        
        guard let url = components.url else {
            throw FetchError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("🍎 [Apple] Location resolution failed for: \(locationQuery)")
            return nil
        }
        
        let decoded = try JSONDecoder().decode(AppleLocationResponse.self, from: data)
        
        return decoded.res?.first?.id
    }
    
    private func convertAppleJob(_ appleJob: AppleSearchResult) -> Job? {
        let locationString = buildLocationString(from: appleJob.locations)
        
        let postingDate = parseAppleDate(appleJob.postDateInGMT ?? appleJob.postingDate)
        
        let jobURL = "https://jobs.apple.com/\(appleJob.transformedPostingTitle ?? "job")/\(appleJob.positionId)"
        
        return Job(
            id: "apple-\(appleJob.positionId)",
            title: appleJob.postingTitle,
            location: locationString,
            postingDate: postingDate,
            url: jobURL,
            description: appleJob.jobSummary,
            workSiteFlexibility: appleJob.homeOffice! ? "Remote" : nil,
            source: .apple,
            companyName: "Apple",
            department: appleJob.team?.teamName,
            category: appleJob.type,
            firstSeenDate: Date()
        )
    }
    
    private func buildLocationString(from locations: [AppleLocation]?) -> String {
        guard let locations = locations, !locations.isEmpty else {
            return "Location not specified"
        }
        
        let location = locations[0]
        
        if !location.city.isEmpty && !location.stateProvince.isEmpty {
            return "\(location.city), \(location.stateProvince)"
        } else if !location.name.isEmpty {
            return location.name
        } else if !location.countryName.isEmpty {
            return location.countryName
        }
        
        return "Location not specified"
    }
    
    private func parseAppleDate(_ dateString: String?) -> Date? {
        guard let dateString = dateString else { return nil }
        
        if dateString.contains("T") && dateString.contains("Z") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: dateString)
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.locale = Locale(identifier: "en_US")
        return formatter.date(from: dateString)
    }
    
    private func applyClientSideFiltering(_ jobs: [Job], titleKeywords: [String]) -> [Job] {
        guard !titleKeywords.isEmpty else { return jobs }
        
        return jobs.filter { job in
            titleKeywords.contains { keyword in
                job.title.localizedCaseInsensitiveContains(keyword)
            }
        }
    }
    
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
}

// MARK: - Apple API Models

struct AppleSearchResponse: Codable {
    let res: AppleSearchResults?
}

struct AppleSearchResults: Codable {
    let searchResults: [AppleSearchResult]
    let totalRecords: Int
}

struct AppleSearchResult: Codable {
    let id: String
    let positionId: String
    let postingTitle: String
    let jobSummary: String
    let postingDate: String?
    let postDateInGMT: String?
    let transformedPostingTitle: String?
    let locations: [AppleLocation]?
    let team: AppleTeam?
    let type: String?
    let homeOffice: Bool?
    let standardWeeklyHours: Int?
}

struct AppleLocation: Codable {
    let id: String?
    let name: String
    let city: String
    let stateProvince: String
    let countryName: String
    let displayName: String?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        city = try container.decodeIfPresent(String.self, forKey: .city) ?? ""
        stateProvince = try container.decodeIfPresent(String.self, forKey: .stateProvince) ?? ""
        countryName = try container.decodeIfPresent(String.self, forKey: .countryName) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    }
}

struct AppleTeam: Codable {
    let teamName: String
    let teamID: String
    let teamCode: String
}

struct AppleLocationResponse: Codable {
    let res: [AppleLocationResult]?
}

struct AppleLocationResult: Codable {
    let id: String
    let name: String
    let displayName: String
    let city: String?
}

