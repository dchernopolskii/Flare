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
        print("ðŸ”· [Microsoft] Starting with titles: \(titleKeywords), location: '\(location)'")
        
        var allJobs: [Job] = []
        var globalSeenJobIds = Set<String>()
        
        let locations = location.isEmpty ? [""] : location.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        
        let titles = titleKeywords.filter { !$0.isEmpty }
        
        print("ðŸ”· [Microsoft] Parsed titles: \(titles)")
        print("ðŸ”· [Microsoft] Parsed locations: \(locations)")
        
        var searchCombinations: [(title: String, location: String)] = []
        
        if titles.isEmpty && locations.isEmpty {
            searchCombinations.append(("", ""))
        } else if titles.isEmpty {
            for loc in locations {
                searchCombinations.append(("", loc))
            }
        } else if locations.isEmpty {
            for title in titles {
                searchCombinations.append((title, ""))
            }
        } else {
            for title in titles {
                for loc in locations {
                    searchCombinations.append((title, loc))
                }
            }
        }
        
        print("ðŸ”· [Microsoft] Will make \(searchCombinations.count) separate API calls")
        
        for (index, combo) in searchCombinations.enumerated() {
            let description = [combo.title, combo.location].filter { !$0.isEmpty }.joined(separator: " in ")
            
            await MainActor.run {
                JobManager.shared.loadingProgress = "Microsoft search \(index + 1)/\(searchCombinations.count): \(description.isEmpty ? "recent jobs" : description)"
            }
            
            let jobs = try await executeIndividualSearch(
                title: combo.title,
                location: combo.location,
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
            print("ðŸ”· [Microsoft] Search \(index + 1) returned \(newJobs.count) new unique jobs")
            
            try await Task.sleep(nanoseconds: 700_000_000) // 0.7 seconds
        }
        
        await MainActor.run {
            JobManager.shared.loadingProgress = ""
        }
        
        print("ðŸ”· [Microsoft] TOTAL RESULT: \(allJobs.count) unique jobs from \(searchCombinations.count) searches")
        return allJobs
    }
    
    private func executeIndividualSearch(title: String, location: String, maxPages: Int) async throws -> [Job] {
        var jobs: [Job] = []
        let pageLimit = min(maxPages, 3)
        
        for page in 1...pageLimit {
            let queryParts = [title, location].filter { !$0.isEmpty }
            let queryString = queryParts.joined(separator: " ")
            
            var components = URLComponents(string: baseURL)!
            components.queryItems = [
                URLQueryItem(name: "l", value: "en_us"),
                URLQueryItem(name: "pg", value: String(page)),
                URLQueryItem(name: "pgSz", value: "20"),
                URLQueryItem(name: "o", value: "Recent"),
                URLQueryItem(name: "flt", value: "true")
            ]
            
            if !queryString.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "q", value: queryString))
            }
            
            print("ðŸ”· [Microsoft] API call with query: '\(queryString)' (page \(page))")
            
            var request = URLRequest(url: components.url!)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                print("ðŸ”· [Microsoft] API error for query: '\(queryString)'")
                break
            }
            
            let pageJobs = try parseResponse(data)
            jobs.append(contentsOf: pageJobs)
            
            if pageJobs.count < 20 {
                break
            }
            
            try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
        }
        
        return jobs
    }
    
    private func parseResponse(_ data: Data) throws -> [Job] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let response = try decoder.decode(MSResponse.self, from: data)
        
        return response.operationResult.result.jobs.map { msJob in
            let knownLocations = [
                "Redmond", "Seattle", "Bellevue", "Mountain View", "Sunnyvale",
                "San Francisco", "New York", "NYC", "Austin", "Atlanta",
                "Boston", "Chicago", "Denver", "Los Angeles", "Phoenix",
                "San Diego", "Washington DC", "DC", "Toronto", "Vancouver",
                "London", "Dublin", "Paris", "Berlin", "Munich", "Amsterdam",
                "Stockholm", "Tokyo", "Beijing", "Shanghai", "Singapore",
                "Sydney", "Melbourne", "Bangalore", "Hyderabad", "Delhi",
                "Tel Aviv", "Dubai", "Cairo", "Lagos", "Nairobi", "Johannesburg"
            ]
            
            var cleanTitle = msJob.title
            var extractedLocation: String? = nil
            
            // Extract location from title
            if msJob.title.contains(" - ") {
                let parts = msJob.title.components(separatedBy: " - ")
                if parts.count > 1 {
                    let lastPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if knownLocations.contains(where: { lastPart.contains($0) }) || lastPart.count < 30 {
                        cleanTitle = parts.dropLast().joined(separator: " - ")
                        extractedLocation = lastPart
                    }
                }
            }
            
            // Check for location in parentheses
            if extractedLocation == nil,
               let range = msJob.title.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
                let location = String(msJob.title[range])
                    .replacingOccurrences(of: "(", with: "")
                    .replacingOccurrences(of: ")", with: "")
                if knownLocations.contains(where: { location.contains($0) }) {
                    extractedLocation = location
                    cleanTitle = msJob.title.replacingOccurrences(of: #"\s*\([^)]+\)"#,
                                                                  with: "",
                                                                  options: .regularExpression)
                }
            }
            
            var location: String = "Location not specified"
            
            if let primaryLoc = msJob.properties?.primaryLocation, !primaryLoc.isEmpty {
                location = primaryLoc
            } else if let locations = msJob.properties?.locations, !locations.isEmpty {
                location = locations[0]
            } else if let extracted = extractedLocation {
                location = extracted
            }
            
            let workSiteFlexibility = msJob.properties?.workSiteFlexibility ?? ""
            let isHybrid = workSiteFlexibility.contains("days / week") ||
                           workSiteFlexibility.contains("days/week") ||
                           workSiteFlexibility.lowercased().contains("hybrid")
            let isRemote = workSiteFlexibility.lowercased().contains("100%") ||
                           workSiteFlexibility.lowercased().contains("remote") ||
                           workSiteFlexibility.lowercased().contains("work from home")
            
            if location != "Location not specified" {
                if isHybrid {
                    location += " (Hybrid: \(workSiteFlexibility))"
                } else if isRemote {
                    location += " (Remote)"
                }
            }
            
            return Job(
                id: "microsoft-\(msJob.jobId)",
                title: cleanTitle,
                location: location,
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
        }
    }
    
    private func parseDate(_ dateString: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: dateString)
    }
}
