//
//  MicrosoftJobFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//

import Foundation

actor MicrosoftJobFetcher: JobFetcherProtocol {
    private let baseURL = "https://gcsservices.careers.microsoft.com/search/api/v1/search"
    
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int = 5) async throws -> [Job] {
        print("🔵 [Microsoft] Starting fetch with location: '\(location)'")
        
        var allJobs: [Job] = []
        var globalSeenJobIds = Set<String>()
        
        let targetCountries = LocationService.getMicrosoftLocationParams(location)
        print("🔵 [Microsoft] Target countries from mapper: \(targetCountries)")
        
        let titles = titleKeywords.filter { !$0.isEmpty }
        
        var searchCombinations: [(title: String, country: String)] = []
        
        if titles.isEmpty && targetCountries.isEmpty {
            searchCombinations.append(("", "United States")) // Default
        } else if titles.isEmpty {
            for country in targetCountries {
                searchCombinations.append(("", country))
            }
        } else if targetCountries.isEmpty {
            for title in titles {
                searchCombinations.append((title, "United States"))
            }
        } else {
            for title in titles {
                for country in targetCountries {
                    searchCombinations.append((title, country))
                }
            }
        }
        
        for (index, combo) in searchCombinations.enumerated() {
            let description = [combo.title, combo.country].filter { !$0.isEmpty }.joined(separator: " in ")
            
            await MainActor.run {
                JobManager.shared.loadingProgress = "Microsoft search \(index + 1)/\(searchCombinations.count): \(description)"
            }
            
            let jobs = try await executeIndividualSearch(
                title: combo.title,
                country: combo.country,
                maxPages: max(1, maxPages / searchCombinations.count)
            )
            
            let newJobs = jobs.filter { job in
                if globalSeenJobIds.contains(job.id) {
                    return false
                }
                globalSeenJobIds.insert(job.id)
                return true
            }
            
            allJobs.append(contentsOf: newJobs)
            
            try await Task.sleep(nanoseconds: 700_000_000)
        }
        
        await MainActor.run {
            JobManager.shared.loadingProgress = ""
        }
        
        print("🔵 [Microsoft] Total jobs returned: \(allJobs.count)")
        return allJobs
    }
    
    private func executeIndividualSearch(title: String, country: String, maxPages: Int) async throws -> [Job] {
        var jobs: [Job] = []
        let pageLimit = min(maxPages, 3)
        
        for page in 1...pageLimit {
            var components = URLComponents(string: baseURL)!
            components.queryItems = [
                URLQueryItem(name: "lc", value: country),
                URLQueryItem(name: "l", value: "en_us"),
                URLQueryItem(name: "pg", value: String(page)),
                URLQueryItem(name: "pgSz", value: "20"),
                URLQueryItem(name: "o", value: "Recent"),
                URLQueryItem(name: "flt", value: "true")
            ]
            
            if !title.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "q", value: title))
            }
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            if page == 1 {
                print("🔵 [Microsoft] Query URL: \(components.url!)")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                break
            }
            
            let pageJobs = try parseResponse(data, targetCountry: country)
            jobs.append(contentsOf: pageJobs)
            
            if pageJobs.count < 20 {
                break
            }
            
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        
        return jobs
    }
    
    private func parseResponse(_ data: Data, targetCountry: String) throws -> [Job] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let response = try decoder.decode(MSResponse.self, from: data)
        
        var jobs: [Job] = []
        
        for msJob in response.operationResult.result.jobs {
            let jobLocations = msJob.properties?.locations ?? []
            let primaryLocation = msJob.properties?.primaryLocation ?? ""
            
            var allLocations = jobLocations
            if !primaryLocation.isEmpty && !allLocations.contains(primaryLocation) {
                allLocations.append(primaryLocation)
            }
            
            if allLocations.isEmpty {
                continue
            }
            
            let displayLocation = allLocations.first ?? "Location not specified"
            
            let workSiteFlexibility = msJob.properties?.workSiteFlexibility ?? ""
            let isHybrid = workSiteFlexibility.contains("days / week") ||
                           workSiteFlexibility.contains("days/week") ||
                           workSiteFlexibility.lowercased().contains("hybrid")
            let isRemote = workSiteFlexibility.lowercased().contains("100%") ||
                           workSiteFlexibility.lowercased().contains("remote")
            
            var finalLocation = displayLocation
            if isHybrid {
                finalLocation += " (Hybrid: \(workSiteFlexibility))"
            } else if isRemote {
                finalLocation += " (Remote)"
            }
            
            var cleanTitle = msJob.title
            if msJob.title.contains(" - ") {
                let parts = msJob.title.components(separatedBy: " - ")
                if parts.count > 1 {
                    cleanTitle = parts.dropLast().joined(separator: " - ")
                }
            }
            
            let job = Job(
                id: "microsoft-\(msJob.jobId)",
                title: cleanTitle,
                location: finalLocation,
                postingDate: parseDate(msJob.postingDate),
                url: "https://careers.microsoft.com/us/en/job/\(msJob.jobId)",
                description: msJob.properties?.description ?? "",
                workSiteFlexibility: workSiteFlexibility,
                source: .microsoft,
                companyName: "Microsoft",
                department: msJob.properties?.discipline,
                category: msJob.properties?.profession,
                firstSeenDate: Date()
            )
            
            jobs.append(job)
        }
        
        return jobs
    }
    
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}
