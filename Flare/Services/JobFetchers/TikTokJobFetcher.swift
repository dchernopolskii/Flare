//
//  TikTokJobFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor TikTokJobFetcher: JobFetcherProtocol {
    private let apiURL = URL(string: "https://api.lifeattiktok.com/api/v1/public/supplier/search/job/posts")!
    private let pageSize = 12
    
    private struct JobTrackingData: Codable {
        let id: String
        let firstSeenDate: Date
    }
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        let locationCodes = LocationService.getTikTokLocationCodes(location)
        var allJobs: [Job] = []
        var currentOffset = 0
        var pageNumber = 1
        let trackingData = await loadJobTrackingData()
        let currentDate = Date()
        
        while allJobs.count < 5000 && pageNumber <= maxPages {
            do {
                let pageJobs = try await fetchJobsPage(
                    titleKeywords: titleKeywords,
                    locationCodes: locationCodes,
                    offset: currentOffset
                )
                
                if pageJobs.isEmpty {
                    break
                }
                
                let converted = pageJobs.enumerated().compactMap { (index, tikTokJob) -> Job? in
                    // Validate required fields
                    guard !tikTokJob.title.isEmpty else {
                        print("[TikTok]¸ Skipping job at index \(index): empty title")
                        return nil
                    }
                    
                    guard !tikTokJob.id.isEmpty else {
                        print("[TikTok]¸ Skipping job at index \(index): empty ID")
                        return nil
                    }
                    
                    let locationString = buildLocationString(from: tikTokJob.city_info)
                    let jobId = "tiktok-\(tikTokJob.id)"
                    let firstSeenDate = trackingData[jobId] ?? currentDate
                    
                    return Job(
                        id: jobId,
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
                
                allJobs.append(contentsOf: converted)
                
                if pageJobs.count < pageSize {
                    break
                }
                
                currentOffset += pageSize
                pageNumber += 1
                
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch let error as FetchError {
                print("[TikTok] Fetch error on page \(pageNumber): \(error.errorDescription ?? "Unknown")")
                throw error
            } catch {
                print("[TikTok] Unexpected error on page \(pageNumber): \(error)")
                throw FetchError.networkError(error)
            }
        }
        
        guard !allJobs.isEmpty else {
            throw FetchError.noJobs
        }
        
        await saveJobTrackingData(allJobs, currentDate: currentDate)
        return allJobs
    }
    
    private func fetchJobsPage(titleKeywords: [String], locationCodes: [String], offset: Int) async throws -> [TikTokJob] {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US", forHTTPHeaderField: "accept-language")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("https://lifeattiktok.com", forHTTPHeaderField: "origin")
        request.setValue("https://lifeattiktok.com/", forHTTPHeaderField: "referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "user-agent")
        request.setValue("tiktok", forHTTPHeaderField: "website-path")
        request.timeoutInterval = 15
        
        let body = buildRequestBody(
            titleKeywords: titleKeywords,
            locationCodes: locationCodes,
            offset: offset
        )
        
        let jsonData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = jsonData
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            throw FetchError.httpError(statusCode: httpResponse.statusCode)
        }
        
        // Try to decode with better error reporting
        let decoded: TikTokAPIResponse
        do {
            decoded = try JSONDecoder().decode(TikTokAPIResponse.self, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? "Unable to preview"
            print("[TikTok] Decoding error: \(error)")
            print("[TikTok] Response preview: \(preview)")
            throw FetchError.decodingError(details: "Failed to decode TikTok response: \(error.localizedDescription)")
        }
        
        guard decoded.code == 0 else {
            throw FetchError.apiError("TikTok API returned error code \(decoded.code)")
        }
        
        return decoded.data.job_post_list
    }
    
    private func buildRequestBody(titleKeywords: [String], locationCodes: [String], offset: Int) -> [String: Any] {
        return [
            "recruitment_id_list": ["1"],
            "job_category_id_list": [],
            "subject_id_list": [],
            "location_code_list": locationCodes,
            "keyword": titleKeywords.joined(separator: " "),
            "limit": pageSize,
            "offset": offset
        ]
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
    
    // MARK: - Persistence with proper date tracking
    
    private func loadJobTrackingData() async -> [String: Date] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("tiktokJobTracking.json")
        
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
    
    private func saveJobTrackingData(_ jobs: [Job], currentDate: Date) async {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("tiktokJobTracking.json")
        
        do {
            var existingData = await loadJobTrackingData()
            
            for job in jobs {
                if existingData[job.id] == nil {
                    existingData[job.id] = currentDate
                }
            }
            
            let trackingData = existingData.map { JobTrackingData(id: $0.key, firstSeenDate: $0.value) }
            
            // Keep only recent data (last 60 days)
            let cutoffDate = Date().addingTimeInterval(-60 * 24 * 3600)
            let recentData = trackingData.filter { $0.firstSeenDate > cutoffDate }
            
            let data = try JSONEncoder().encode(recentData)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            print("🎵 [TikTok] Failed to save job tracking data: \(error)")
        }
    }
}

// MARK: - Models (keep existing)
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
