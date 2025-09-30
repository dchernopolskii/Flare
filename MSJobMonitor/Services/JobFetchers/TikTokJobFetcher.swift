//
//  TikTokJobFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

// MARK: - TikTok Job Fetcher
actor TikTokJobFetcher: JobFetcherProtocol {
    private let apiURL = URL(string: "https://api.lifeattiktok.com/api/v1/public/supplier/search/job/posts")!
    private let pageSize = 12
    private let maxJobs = 3500
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        print("🎵 [TikTok] Starting TikTok job fetch...")
        
        var allJobs: [Job] = []
        var currentOffset = 0
        var pageNumber = 1
        let storedJobIds = await loadStoredTikTokJobIds()
        let currentDate = Date()
        
        while allJobs.count < maxJobs && pageNumber <= maxPages {
            print("🎵 [TikTok] Fetching page \(pageNumber) (offset \(currentOffset))...")
            
            do {
                let pageJobs = try await fetchJobsPage(
                    titleKeywords: titleKeywords,
                    location: location,
                    offset: currentOffset
                )
                
                if pageJobs.isEmpty {
                    print("🎵 [TikTok] No more jobs, stopping at page \(pageNumber)")
                    break
                }
                
                let converted = pageJobs.compactMap { tikTokJob -> Job? in
                    let locationString = buildLocationString(from: tikTokJob.city_info)
                    let isNewJob = !storedJobIds.contains("tiktok-\(tikTokJob.id)")
                    let firstSeenDate = isNewJob ? currentDate : Date().addingTimeInterval(-3600 * 25)
                    
                    return Job(
                        id: "tiktok-\(tikTokJob.id)",
                        title: tikTokJob.title,
                        location: locationString,
                        postingDate: nil,
                        url: "https://lifeattiktok.com/search/\(tikTokJob.id)",
                        description: combineDescriptionAndRequirements(tikTokJob),
                        workSiteFlexibility: extractWorkFlexibility(from: tikTokJob.description),
                        source: .tiktok,
                        companyName: "TikTok",
                        department: tikTokJob.job_category?.en_name,
                        category: tikTokJob.job_category?.i18n_name,
                        firstSeenDate: firstSeenDate
                    )
                }
                
                let titleKeywordsFiltered = titleKeywords.filter { !$0.isEmpty }
                let locationKeywords = parseFilterString(location)
                
                print("🎵 [TikTok] Applying filters - Title keywords: \(titleKeywordsFiltered), Location keywords: \(locationKeywords)")
                
                let filtered = converted.filter { job in
                    var matches = true
                    if !titleKeywordsFiltered.isEmpty {
                        matches = titleKeywordsFiltered.contains { keyword in
                            job.title.localizedCaseInsensitiveContains(keyword)
                        }
                        if !matches {
                            print("🎵 [TikTok] Filtered out by title: '\(job.title)' doesn't match any of \(titleKeywordsFiltered)")
                        }
                    }
                    
                    if matches && !locationKeywords.isEmpty {
                        matches = locationKeywords.contains { keyword in
                            job.location.localizedCaseInsensitiveContains(keyword)
                        }
                        if !matches {
                            print("🎵 [TikTok] Filtered out by location: '\(job.location)' doesn't match any of \(locationKeywords)")
                        }
                    }
                    
                    return matches
                }
                
                allJobs.append(contentsOf: filtered)
                                
                if pageJobs.count < pageSize {
                    print("🎵 [TikTok] Partial page (\(pageJobs.count)), stopping")
                    break
                }
                
                currentOffset += pageSize
                pageNumber += 1
                
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                print("❌ [TikTok] Error on page \(pageNumber): \(error)")
                break
            }
        }
        
        await saveNewTikTokJobIds(allJobs.map { $0.id })
        print("🎵 [TikTok] Completed fetch: \(allJobs.count) jobs")
        return allJobs
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
    
    // MARK: - Page Fetch
    private func fetchJobsPage(titleKeywords: [String], location: String, offset: Int) async throws -> [TikTokJob] {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US", forHTTPHeaderField: "accept-language")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("https://lifeattiktok.com", forHTTPHeaderField: "origin")
        request.setValue("https://lifeattiktok.com/", forHTTPHeaderField: "referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
        request.setValue("tiktok", forHTTPHeaderField: "website-path")
        request.timeoutInterval = 15
        
        let body = buildRequestBody(titleKeywords: titleKeywords, location: location, offset: offset)
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData
        
        if offset == 0, let debugBody = String(data: jsonData, encoding: .utf8) {
            print("🎵 [TikTok] Request JSON: \(debugBody)")
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            print("❌ [TikTok] HTTP Error: \(httpResponse.statusCode)")
            if let errStr = String(data: data, encoding: .utf8) {
                print("❌ [TikTok] Response: \(errStr.prefix(500))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(TikTokAPIResponse.self, from: data)
        guard decoded.code == 0 else {
            throw FetchError.apiError("TikTok returned code \(decoded.code)")
        }
        
        return decoded.data.job_post_list
    }
    
    private func buildRequestBody(titleKeywords: [String], location: String, offset: Int) -> [String: Any] {
        var body: [String: Any] = [
            "recruitment_id_list": ["1"],
            "job_category_id_list": [],
            "subject_id_list": [],
            "location_code_list": [],
            "keyword": "",
            "limit": pageSize,
            "offset": offset
        ]
        
        if !titleKeywords.isEmpty {
            body["keyword"] = titleKeywords.joined(separator: " ")
        }
        
        // map human-readable location -> TikTok codes (simplified)
        var locationCodes: [String] = []
        if !location.isEmpty {
            let loc = location.lowercased()
            if loc.contains("seattle") { locationCodes.append("CT_157") }
            if loc.contains("los angeles") { locationCodes.append("CT_94") }
            if loc.contains("new york") || loc.contains("nyc") { locationCodes.append("CT_163") }
        }
        
        if !locationCodes.isEmpty {
            body["location_code_list"] = locationCodes
        }
        
        return body
    }
    
    // MARK: - Helpers
    private func buildLocationString(from cityInfo: TikTokCityInfo?) -> String {
        guard let cityInfo = cityInfo else { return "Location not specified" }
        var parts: [String] = []
        if let city = cityInfo.en_name { parts.append(city) }
        var parent = cityInfo.parent
        while let p = parent {
            if let n = p.en_name { parts.append(n) }
            parent = p.parent
        }
        return parts.joined(separator: ", ")
    }
    
    private func combineDescriptionAndRequirements(_ job: TikTokJob) -> String {
        var combined = job.description
        if !job.requirement.isEmpty {
            combined += "\n\nRequirements:\n" + job.requirement
        }
        return combined
    }
    
    private func extractWorkFlexibility(from description: String) -> String? {
        let keywords = ["remote", "hybrid", "flexible", "onsite", "on-site", "in-office"]
        let lower = description.lowercased()
        for key in keywords where lower.contains(key) {
            return key.capitalized
        }
        return nil
    }
    
    // MARK: - Persistence
    private func loadStoredTikTokJobIds() async -> Set<String> {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("tiktokJobIds.json")
        
        do {
            let data = try Data(contentsOf: url)
            let ids = try JSONDecoder().decode([String].self, from: data)
            return Set(ids)
        } catch {
            print("🎵 [TikTok] No stored job IDs: \(error.localizedDescription)")
            return []
        }
    }
    
    private func saveNewTikTokJobIds(_ jobIds: [String]) async {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("tiktokJobIds.json")
        
        do {
            var existing = await loadStoredTikTokJobIds()
            jobIds.forEach { existing.insert($0) }
            let trimmed = Array(existing).suffix(10000)
            
            let data = try JSONEncoder().encode(Array(trimmed))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            print("🎵 [TikTok] Saved \(trimmed.count) job IDs")
        } catch {
            print("❌ [TikTok] Failed saving job IDs: \(error)")
        }
    }
}

// MARK: - TikTok API Models
struct TikTokAPIResponse: Codable {
    let code: Int
    let data: TikTokData
}

struct TikTokData: Codable {
    let job_post_list: [TikTokJob]
}

struct TikTokJob: Codable {
    let id: String
    let code: String?
    let title: String
    let description: String
    let requirement: String
    let job_category: TikTokJobCategory?
    let city_info: TikTokCityInfo?
}

final class TikTokJobCategory: Codable {
    let id: String
    let en_name: String?
    let i18n_name: String?
    var parent: TikTokJobCategory?
}

final class TikTokCityInfo: Codable {
    let code: String
    let en_name: String?
    var parent: TikTokCityInfo?
}

// MARK: - Job Fetcher Protocol
protocol JobFetcherProtocol {
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job]
}

// MARK: - Fetch Error
enum FetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case parsingFailed
    case httpError(Int)
    case apiError(String)
    case notImplemented(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Failed to fetch job listings"
        case .parsingFailed:
            return "Failed to parse job data"
        case .httpError(let code):
            return "HTTP Error: \(code)"
        case .apiError(let message):
            return "API Error: \(message)"
        case .notImplemented(let platform):
            return "\(platform) integration coming soon"
        }
    }
}
