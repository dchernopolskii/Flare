//
//  WorkdayFetcher.swift
//  MSJobMonitor
//
//  Created by Dan on 10/9/25.
//

import Foundation

actor WorkdayFetcher: JobFetcherProtocol {
    
    private var locationCache: [String: [WorkdayLocation]] = [:]
    private var sessionCache: [String: WorkdaySession] = [:]
    
    private struct JobTrackingData: Codable {
        let id: String
        let firstSeenDate: Date
    }
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        return []
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let config = try extractWorkdayConfig(from: url)
        do {
            let storedJobDates = await loadJobTrackingData(company: config.company)
            let currentDate = Date()
            let session = try await establishSession(config: config, originalURL: url)
            let initialResponse = try await fetchJobsPage(
                config: config,
                session: session,
                offset: 0,
                searchText: "",
                locationIds: [],
                remoteType: nil
            )
        
        if let facets = initialResponse.facets, !facets.isEmpty {
            var allLocationValues: [WorkdayFacetValue] = []
            
            for facet in facets {
                if facet.facetParameter == "locations" {
                    allLocationValues = facet.extractLocationValues()
                    break
                } else if facet.facetParameter == "locationMainGroup" {
                    allLocationValues = facet.extractLocationValues()
                    break
                }
            }
            
            if !allLocationValues.isEmpty {
                locationCache[config.cacheKey] = allLocationValues.map { facetValue in
                    WorkdayLocation(
                        id: facetValue.id,
                        descriptor: facetValue.descriptor,
                        count: facetValue.count
                    )
                }
                print("🔵 [Workday] ✅ Cached \(locationCache[config.cacheKey]?.count ?? 0) locations for \(config.company)")
            } else {
                print("🔵 [Workday] ℹ️ No location facets found for \(config.company)")
            }
        } else {
            print("🔵 [Workday] ℹ️ \(config.company) doesn't return facets - will use client-side filtering")
        }
        
        let locationIds = extractLocationIds(
            from: locationFilter,
            company: config.cacheKey
        )
        
        let titleKeywords = parseFilterString(titleFilter, includeRemote: false)
        let searchText = titleKeywords.joined(separator: " ")
        var allJobs: [Job] = []
        var offset = 0
        let limit = 20
        
        for page in 0..<5 {
            
            let response = try await fetchJobsPage(
                config: config,
                session: session,
                offset: offset,
                searchText: searchText,
                locationIds: locationIds,
                remoteType: nil
            )
            
            if response.jobPostings.isEmpty {
                break
            }
            
            let pageJobs = response.jobPostings.compactMap { workdayJob -> Job? in
                convertWorkdayJob(workdayJob, config: config, storedJobDates: storedJobDates, currentDate: currentDate)
            }
            
            allJobs.append(contentsOf: pageJobs)
            
            if response.jobPostings.count < limit {
                break
            }
            
            offset += limit
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        
        let shouldApplyLocationFilter = locationIds.isEmpty && !locationFilter.isEmpty
        
        let filteredJobs: [Job]
        if shouldApplyLocationFilter {
            let locationKeywords = parseFilterString(locationFilter, includeRemote: false)
            filteredJobs = applyClientSideFilters(
                jobs: allJobs,
                titleKeywords: [],
                locationKeywords: locationKeywords
            )
        } else {
            filteredJobs = allJobs
        }
        
            await saveJobTrackingData(filteredJobs, company: config.company, currentDate: currentDate)
            return filteredJobs
        } catch {
            print("🔵 [Workday] ❌ Error in fetchJobs: \(error)")
            print("🔵 [Workday] ❌ Error type: \(type(of: error))")
            if let localizedError = error as? LocalizedError {
                print("🔵 [Workday] ❌ Description: \(localizedError.errorDescription ?? "none")")
            }
            throw error
        }
    }
    
    // MARK: - Private Methods
    
    private func establishSession(config: WorkdayConfig, originalURL: URL) async throws -> WorkdaySession {
        if let cached = sessionCache[config.cacheKey] {
            return cached
        }
        
        let pageURL = "https://\(config.company).\(config.instance).myworkdayjobs.com/\(config.siteName)"
        guard let url = URL(string: pageURL) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔵 [Workday] ❌ Invalid session response")
            throw FetchError.invalidResponse
        }
        
        var cookies: [String] = []
        var csrfToken: String?
        
        if let headerFields = httpResponse.allHeaderFields as? [String: String] {
            let url = httpResponse.url ?? originalURL
            let cookieArray = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            
            for cookie in cookieArray {
                cookies.append("\(cookie.name)=\(cookie.value)")
                
                if cookie.name == "CALYPSO_CSRF_TOKEN" {
                    csrfToken = cookie.value
                }
            }
        }
        
        let session = WorkdaySession(
            cookies: cookies.joined(separator: "; "),
            csrfToken: csrfToken ?? ""
        )
        
        sessionCache[config.cacheKey] = session
        return session
    }
    
    private func fetchJobsPage(
        config: WorkdayConfig,
        session: WorkdaySession,
        offset: Int,
        searchText: String,
        locationIds: [String],
        remoteType: String?
    ) async throws -> WorkdayResponse {
        
        let apiPath = "/wday/cxs/\(config.company)/\(config.siteName)/jobs"
        let baseURL = "https://\(config.company).\(config.instance).myworkdayjobs.com"
        
        guard let url = URL(string: baseURL + apiPath) else {
            throw FetchError.invalidURL
        }
        
        var body: [String: Any] = [
            "appliedFacets": [:],
            "limit": 20,
            "offset": offset,
            "searchText": searchText
        ]
        
        if !locationIds.isEmpty {
            var appliedFacets: [String: Any] = [:]
            appliedFacets["locations"] = locationIds
            body["appliedFacets"] = appliedFacets
        }
        
        if let remoteType = remoteType {
            var appliedFacets = body["appliedFacets"] as? [String: Any] ?? [:]
            appliedFacets["remoteType"] = [remoteType]
            body["appliedFacets"] = appliedFacets
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://\(config.company).\(config.instance).myworkdayjobs.com", forHTTPHeaderField: "Origin")
        request.setValue("https://\(config.company).\(config.instance).myworkdayjobs.com/\(config.siteName)", forHTTPHeaderField: "Referer")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.timeoutInterval = 15
        
        if !session.cookies.isEmpty {
            request.setValue(session.cookies, forHTTPHeaderField: "Cookie")
        }
        
        if !session.csrfToken.isEmpty {
            request.setValue(session.csrfToken, forHTTPHeaderField: "X-CALYPSO-CSRF-TOKEN")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            print("🔵 [Workday] ❌ Invalid response object")
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            if let errorString = String(data: data, encoding: .utf8) {
                print("🔵 [Workday] ❌ Error response body: \(errorString.prefix(200))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        do {
            let decoded = try JSONDecoder().decode(WorkdayResponse.self, from: data)
            return decoded
        } catch {
            print("🔵 [Workday] ❌ JSON decode error: \(error)")
            if let responseString = String(data: data, encoding: .utf8) {
                print("🔵 [Workday] Response preview: \(responseString.prefix(500))")
            }
            throw FetchError.parsingFailed
        }
    }
    
    private func convertWorkdayJob(_ workdayJob: WorkdayJobPosting, config: WorkdayConfig, storedJobDates: [String: Date], currentDate: Date) -> Job? {
        let jobId = workdayJob.bulletFields.first ?? UUID().uuidString
        
        let pathComponents = workdayJob.externalPath.components(separatedBy: "/")
        let titleSlug = pathComponents.last?.components(separatedBy: "_").first ?? workdayJob.title
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ",", with: "")
        
        let jobURL = "https://\(config.company).\(config.instance).myworkdayjobs.com/en-US/\(config.siteName)/details/\(titleSlug)_\(jobId)"
        
        let postingDate = parsePostedDate(workdayJob.postedOn)
        
        let fullJobId = "workday-\(jobId)"
        let firstSeenDate = storedJobDates[fullJobId] ?? currentDate
        
        return Job(
            id: fullJobId,
            title: workdayJob.title,
            location: workdayJob.locationsText,
            postingDate: postingDate,
            url: jobURL,
            description: "",
            workSiteFlexibility: workdayJob.remoteType,
            source: .workday,
            companyName: config.company.replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " "),
            department: nil,
            category: workdayJob.bulletFields.count > 1 ? workdayJob.bulletFields[1] : nil,
            firstSeenDate: firstSeenDate
        )
    }
    
    private func parsePostedDate(_ postedText: String) -> Date? {
        let lowercased = postedText.lowercased()
        
        if lowercased.contains("today") {
            return Date()
        }
        
        if lowercased.contains("yesterday") {
            return Calendar.current.date(byAdding: .day, value: -1, to: Date())
        }
        
        let components = postedText.components(separatedBy: " ")
        if let index = components.firstIndex(where: { $0.lowercased() == "posted" }),
           index + 1 < components.count,
           let days = Int(components[index + 1]) {
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
        
        return nil
    }
    
    private func extractLocationIds(from locationFilter: String, company: String) -> [String] {
        guard !locationFilter.isEmpty,
              let cachedLocations = locationCache[company] else {
            return []
        }
        
        let keywords = parseFilterString(locationFilter, includeRemote: false)
        var locationIds: [String] = []
        
        for keyword in keywords {
            let matches = cachedLocations.filter { location in
                location.descriptor.localizedCaseInsensitiveContains(keyword)
            }
            
            locationIds.append(contentsOf: matches.map { $0.id })
        }
        
        return locationIds
    }
    
    private func applyClientSideFilters(jobs: [Job], titleKeywords: [String], locationKeywords: [String]) -> [Job] {
        var filtered = jobs
        
        if !titleKeywords.isEmpty {
            filtered = filtered.filter { job in
                titleKeywords.contains { keyword in
                    job.title.localizedCaseInsensitiveContains(keyword)
                }
            }
        }
        
        if !locationKeywords.isEmpty {
            filtered = filtered.filter { job in
                locationKeywords.contains { keyword in
                    job.location.localizedCaseInsensitiveContains(keyword)
                }
            }
        }
        
        return filtered
    }
    
    private func extractWorkdayConfig(from url: URL) throws -> WorkdayConfig {
        guard let host = url.host else {
            throw FetchError.invalidURL
        }
        
        let hostComponents = host.components(separatedBy: ".")
        guard hostComponents.count >= 3,
              hostComponents[1].hasPrefix("wd"),
              let instance = hostComponents.first(where: { $0.hasPrefix("wd") }) else {
            throw FetchError.invalidURL
        }
        
        let company = hostComponents[0]
        let pathComponents = url.pathComponents.filter { $0 != "/" }
        if let cxsIndex = pathComponents.firstIndex(of: "cxs"),
           cxsIndex + 2 < pathComponents.count {
            let siteName = pathComponents[cxsIndex + 2]
            return WorkdayConfig(company: company, instance: instance, siteName: siteName)
        }
        
        guard let siteName = pathComponents.first else {
            throw FetchError.invalidURL
        }
        
        return WorkdayConfig(company: company, instance: instance, siteName: siteName)
    }
    
    private func parseFilterString(_ filterString: String, includeRemote: Bool = true) -> [String] {
        guard !filterString.isEmpty else { return [] }
        
        return filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    // MARK: - Persistence with proper date tracking
    
    private func loadJobTrackingData(company: String) async -> [String: Date] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("workday_\(company)_tracking.json")
        
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
            .appendingPathComponent("workday_\(company)_tracking.json")
        
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
            print("🔵 [Workday] Failed to save job tracking data: \(error)")
        }
    }
}

// MARK: - Workday Config

struct WorkdayConfig {
    let company: String
    let instance: String
    let siteName: String
    
    var cacheKey: String {
        return "\(company).\(instance)"
    }
}

// MARK: - Workday Session

struct WorkdaySession {
    let cookies: String
    let csrfToken: String
}

// MARK: - Workday Location

struct WorkdayLocation: Codable {
    let id: String
    let descriptor: String
    let count: Int
}

// MARK: - Workday API Models

struct WorkdayResponse: Codable {
    let total: Int
    let jobPostings: [WorkdayJobPosting]
    let facets: [WorkdayFacet]?
}

struct WorkdayJobPosting: Codable {
    let title: String
    let externalPath: String
    let locationsText: String
    let postedOn: String
    let remoteType: String?
    let bulletFields: [String]
}

struct WorkdayFacet: Codable {
    let facetParameter: String
    let descriptor: String?
    let values: [WorkdayFacetValueWrapper]
    
    func extractLocationValues() -> [WorkdayFacetValue] {
        var results: [WorkdayFacetValue] = []
        
        for wrapper in values {
            if let simpleValue = wrapper.simpleValue {
                results.append(simpleValue)
            } else if let nestedFacet = wrapper.nestedFacet {
                results.append(contentsOf: nestedFacet.extractLocationValues())
            }
        }
        
        return results
    }
}

struct WorkdayFacetValueWrapper: Codable {
    var simpleValue: WorkdayFacetValue?
    var nestedFacet: WorkdayFacet?
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let facet = try? container.decode(WorkdayFacet.self) {
            self.nestedFacet = facet
            self.simpleValue = nil
        } else {
            self.simpleValue = try container.decode(WorkdayFacetValue.self)
            self.nestedFacet = nil
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let simpleValue = simpleValue {
            try container.encode(simpleValue)
        } else if let nestedFacet = nestedFacet {
            try container.encode(nestedFacet)
        }
    }
}

struct WorkdayFacetValue: Codable {
    let descriptor: String
    let id: String
    let count: Int
}
