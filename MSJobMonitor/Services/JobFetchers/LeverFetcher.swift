//
//  LeverFetcher.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation

actor LeverFetcher: JobFetcherProtocol {
    func fetchJobs(titleKeywords: [String], location: String, maxPages: Int) async throws -> [Job] {
        guard let url = URL(string: "https://jobs.lever.co/\(companySlug)?mode=json") else {
            throw FetchError.invalidURL
        }
        
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        
        let decoded = try JSONDecoder().decode([LeverJob].self, from: data)
        
        return decoded.compactMap { job in
            // Apply filters
            if !titleKeywords.isEmpty &&
                !titleKeywords.contains(where: { job.text.lowercased().contains($0.lowercased()) }) {
                return nil
            }
            if !location.isEmpty &&
                !(job.categories.location?.lowercased().contains(location.lowercased()) ?? false) {
                return nil
            }
            
            return Job(
                id: "lever-\(job.id)",
                title: job.text,
                location: job.categories.location ?? "Location not specified",
                postingDate: ISO8601DateFormatter().date(from: job.createdAt),
                url: job.hostedUrl,
                description: job.descriptionPlain,
                workSiteFlexibility: nil,
                source: .lever,
                companyName: job.categories.team,
                department: job.categories.team,
                category: job.categories.commitment,
                firstSeenDate: Date()
            )
        }
    }
}

// MARK: - Lever API Model
struct LeverJob: Codable {
    let id: String
    let text: String
    let createdAt: String
    let hostedUrl: String
    let descriptionPlain: String
    let categories: Categories
    
    struct Categories: Codable {
        let team: String?
        let commitment: String?
        let location: String?
    }
}
