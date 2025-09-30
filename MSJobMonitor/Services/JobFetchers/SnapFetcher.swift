//
//  SnapFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/30/25.
//

import Foundation

actor SnapFetcher: JobFetcherProtocol {
    private let apiURL = URL(string: "https://careers.snap.com/api/jobs")!
    
    private struct JobTrackingData: Codable {
        let id: String
        let firstSeenDate: Date
    }
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        print("👻 [Snap] Starting Snap job fetch...")
        
        let trackingData = await loadJobTrackingData()
        let currentDate = Date()
        
        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate)
        
        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: location)
        
        await saveJobTrackingData(filteredJobs, currentDate: currentDate)
        
        print("👻 [Snap] Fetched \(jobs.count) total jobs, \(filteredJobs.count) after filtering")
        return filteredJobs
    }
    
    private func fetchAllJobs(trackingData: [String: Date], currentDate: Date) async throws -> [Job] {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        
        components.queryItems = [
            URLQueryItem(name: "location", value: ""),
            URLQueryItem(name: "role", value: ""),
            URLQueryItem(name: "team", value: ""),
            URLQueryItem(name: "type", value: "")
        ]
        
        guard let url = components.url else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        
        print("👻 [Snap] Fetching from: \(url)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FetchError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            print("👻 [Snap] HTTP Error: \(httpResponse.statusCode)")
            if let errorString = String(data: data, encoding: .utf8) {
                print("👻 [Snap] Error response: \(errorString.prefix(500))")
            }
            throw FetchError.httpError(httpResponse.statusCode)
        }
        
        let decoded = try JSONDecoder().decode(SnapResponse.self, from: data)
        
        let jobs = decoded.body.compactMap { snapJob -> Job? in
            guard let source = snapJob._source else { return nil }
            
            let locationString = buildLocationString(from: source)
            
            let jobURL = source.absolute_url ?? "https://careers.snap.com/jobs/\(snapJob._id)"
            
            var workFlexibility: String? = nil
            if let offices = source.offices, offices.contains(where: { $0.name?.lowercased().contains("remote") ?? false }) {
                workFlexibility = "Remote"
            }
            
            let jobId = "snap-\(snapJob._id)"
            let firstSeenDate = trackingData[jobId] ?? currentDate
            
            return Job(
                id: jobId,
                title: source.title ?? "Untitled Position",
                location: locationString,
                postingDate: nil,
                url: jobURL,
                description: source.jobDescription ?? "",
                workSiteFlexibility: workFlexibility,
                source: .snap,
                companyName: "Snap Inc.",
                department: source.departments,
                category: source.role,
                firstSeenDate: firstSeenDate
            )
        }
        
        return jobs
    }
    
    private func buildLocationString(from source: SnapJobSource) -> String {
        if let primaryLocation = source.primary_location, !primaryLocation.isEmpty {
            return primaryLocation
        }
        
        if let offices = source.offices, !offices.isEmpty {
            let locations = offices.compactMap { office -> String? in
                if let name = office.name, !name.isEmpty {
                    return name
                } else if let location = office.location, !location.isEmpty {
                    return location
                }
                return nil
            }
            
            if !locations.isEmpty {
                return locations.joined(separator: " / ")
            }
        }
        
        return "Location not specified"
    }
    
    private func applyFilters(jobs: [Job], titleKeywords: [String], location: String) -> [Job] {
        var filteredJobs = jobs
        
        if !titleKeywords.isEmpty {
            let keywords = titleKeywords.filter { !$0.isEmpty }
            if !keywords.isEmpty {
                filteredJobs = filteredJobs.filter { job in
                    keywords.contains { keyword in
                        job.title.localizedCaseInsensitiveContains(keyword) ||
                        job.department?.localizedCaseInsensitiveContains(keyword) ?? false ||
                        job.category?.localizedCaseInsensitiveContains(keyword) ?? false
                    }
                }
            }
        }
        
        if !location.isEmpty {
            let locationKeywords = parseLocationString(location)
            if !locationKeywords.isEmpty {
                filteredJobs = filteredJobs.filter { job in
                    locationKeywords.contains { keyword in
                        job.location.localizedCaseInsensitiveContains(keyword)
                    }
                }
            }
        }
        
        return filteredJobs
    }
    
    private func parseLocationString(_ locationString: String) -> [String] {
        guard !locationString.isEmpty else { return [] }
        
        var keywords = locationString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if keywords.contains(where: { $0.localizedCaseInsensitiveContains("remote") }) {
            if !keywords.contains("remote") {
                keywords.append("remote")
            }
            if !keywords.contains("Remote") {
                keywords.append("Remote")
            }
        }
        
        return keywords
    }
    
    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let titleKeywords = parseFilterString(titleFilter)
        
        let trackingData = await loadJobTrackingData()
        let currentDate = Date()
        
        let jobs = try await fetchAllJobs(trackingData: trackingData, currentDate: currentDate)
        
        let filteredJobs = applyFilters(jobs: jobs, titleKeywords: titleKeywords, location: locationFilter)
        
        await saveJobTrackingData(filteredJobs, currentDate: currentDate)
        
        return filteredJobs
    }
    
    private func parseFilterString(_ filterString: String) -> [String] {
        guard !filterString.isEmpty else { return [] }
        
        return filterString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
    
    // MARK: - Persistence with proper date tracking
    private func loadJobTrackingData() async -> [String: Date] {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("snapJobTracking.json")
        
        do {
            let data = try Data(contentsOf: url)
            let trackingData = try JSONDecoder().decode([JobTrackingData].self, from: data)
            
            var dict: [String: Date] = [:]
            for item in trackingData {
                dict[item.id] = item.firstSeenDate
            }
            
            print("👻 [Snap] Loaded tracking data for \(dict.count) jobs")
            return dict
        } catch {
            print("👻 [Snap] No tracking data found: \(error.localizedDescription)")
            return [:]
        }
    }
    
    private func saveJobTrackingData(_ jobs: [Job], currentDate: Date) async {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MicrosoftJobMonitor")
            .appendingPathComponent("snapJobTracking.json")
        
        do {
            var existingData = await loadJobTrackingData()
            
            for job in jobs {
                if existingData[job.id] == nil {
                    existingData[job.id] = currentDate
                }
            }
            
            let trackingData = existingData.map { JobTrackingData(id: $0.key, firstSeenDate: $0.value) }
            
            let cutoffDate = Date().addingTimeInterval(-30 * 24 * 3600)
            let recentData = trackingData.filter { $0.firstSeenDate > cutoffDate }
            
            let data = try JSONEncoder().encode(recentData)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            
            print("👻 [Snap] Saved tracking data for \(recentData.count) jobs")
        } catch {
            print("❌ [Snap] Failed saving tracking data: \(error)")
        }
    }
}

// MARK: - Snap API Models

struct SnapResponse: Codable {
    let body: [SnapJob]
}

struct SnapJob: Codable {
    let _index: String?
    let _type: String?
    let _id: String
    let _score: Double?
    let _ignored: [String]?
    let _source: SnapJobSource?
}

struct SnapJobSource: Codable {
    let employment_type: String?
    let role: String?
    let offices: [SnapOffice]?
    let primary_location: String?
    let External_Posting: String?
    let absolute_url: String?
    let departments: String?
    let id: String?
    let title: String?
    let jobPostingSite: String?
    let jobDescription: String?
}

struct SnapOffice: Codable {
    let name: String?
    let location: String?
}
