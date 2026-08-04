import Foundation

actor CapgeminiJobStreamFetcher: URLBasedJobFetcherProtocol {
    private let trackingService = JobTrackingService.shared
    private let session: URLSession
    private let pageSize = 100
    private let maximumPages = 100

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let endpoint = try await endpoint(for: url)
        let countryCode = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "country_code" })?
            .value
        let trackingKey = "capgemini_\(countryCode ?? "global")"
        let storedJobDates = await trackingService.loadTrackingData(for: trackingKey)
        let currentDate = Date()

        var listings: [CapgeminiListing] = []
        var seenIDs = Set<String>()
        var total = Int.max
        var page = 1

        for _ in 0..<maximumPages where listings.count < total {
            let response = try await fetchPage(endpoint: endpoint, countryCode: countryCode, page: page)
            total = response.count
            guard !response.data.isEmpty else { break }

            for listing in response.data where seenIDs.insert(listing.id).inserted {
                listings.append(listing)
            }

            if response.data.count < pageSize { break }
            page += 1
        }

        let jobs = listings.map { listing in
            let jobID = "capgemini-\(listing.id)"
            return Job(
                id: jobID,
                title: listing.title,
                location: listing.location ?? "Not specified",
                postingDate: listing.updatedAt,
                url: jobURL(for: listing, pageURL: url),
                description: listing.description ?? "",
                workSiteFlexibility: nil,
                source: .capgemini,
                companyName: "Capgemini",
                department: listing.department ?? listing.professionalCommunities,
                category: listing.sbu ?? listing.contractType,
                firstSeenDate: storedJobDates[jobID] ?? currentDate,
                originalPostingDate: nil,
                wasBumped: false
            )
        }

        let filteredJobs = jobs.applying(
            titleKeywords: titleFilter.parseAsFilterKeywords(),
            locationKeywords: locationFilter.parseAsFilterKeywords()
        )
        await trackingService.saveTrackingData(filteredJobs, for: trackingKey, currentDate: currentDate, retentionDays: 30)
        return filteredJobs
    }

    func endpoint(for url: URL) async throws -> URL {
        if url.host?.lowercased() == "cg-jobstream-api.azurewebsites.net" {
            return canonicalEndpoint(
                baseURL: URL(string: "https://cg-jobstream-api.azurewebsites.net/api/job-search")!,
                countryCode: countryCode(from: url)
            )
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8),
              let endpoint = Self.extractEndpoint(from: html) else {
            throw FetchError.invalidResponse
        }
        return canonicalEndpoint(baseURL: endpoint, countryCode: countryCode(from: url))
    }

    private func fetchPage(endpoint: URL, countryCode: String?, page: Int) async throws -> CapgeminiResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(pageSize))
        ]
        if let countryCode, !countryCode.isEmpty {
            queryItems.append(URLQueryItem(name: "country_code", value: countryCode))
        }
        components?.queryItems = queryItems
        guard let pageURL = components?.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: pageURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date: \(value)")
            }
            return date
        }
        return try decoder.decode(CapgeminiResponse.self, from: data)
    }

    private static func extractEndpoint(from html: String) -> URL? {
        let pattern = #"cg_jobs_jobstream_url\s*=\s*[\"']([^\"']+)[\"']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let baseURL = URL(string: String(html[range])) else {
            return nil
        }
        return baseURL.appendingPathComponent("job-search")
    }

    private func countryCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "country_code" })?
            .value
    }

    private func canonicalEndpoint(baseURL: URL, countryCode: String?) -> URL {
        guard let countryCode, !countryCode.isEmpty,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        components.queryItems = [URLQueryItem(name: "country_code", value: countryCode)]
        return components.url ?? baseURL
    }

    private func jobURL(for listing: CapgeminiListing, pageURL: URL) -> String {
        let path: String
        if let ref = listing.ref, let source = listing.source, !ref.isEmpty, !source.isEmpty {
            path = "/jobs/\(ref)+\(source.lowercased())"
        } else {
            path = "/jobs/\(listing.id)"
        }
        let careerSiteURL = pageURL.host?.lowercased() == "cg-jobstream-api.azurewebsites.net"
            ? URL(string: "https://www.capgemini.com")!
            : pageURL
        var components = URLComponents(url: careerSiteURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.query = nil
        components?.fragment = nil
        return components?.url?.absoluteString ?? pageURL.absoluteString
    }
}

private struct CapgeminiResponse: Decodable {
    let count: Int
    let data: [CapgeminiListing]
}

private struct CapgeminiListing: Decodable {
    let id: String
    let title: String
    let location: String?
    let ref: String?
    let source: String?
    let description: String?
    let department: String?
    let professionalCommunities: String?
    let sbu: String?
    let contractType: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, location, ref, source, description, department, sbu
        case professionalCommunities = "professional_communities"
        case contractType = "contract_type"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeString(forKey: .id, from: container)
        title = try container.decode(String.self, forKey: .title)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        ref = try container.decodeIfPresent(String.self, forKey: .ref)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        department = try container.decodeIfPresent(String.self, forKey: .department)
        professionalCommunities = try container.decodeIfPresent(String.self, forKey: .professionalCommunities)
        sbu = try container.decodeIfPresent(String.self, forKey: .sbu)
        contractType = try container.decodeIfPresent(String.self, forKey: .contractType)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    private static func decodeString(forKey key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        return String(try container.decode(Int.self, forKey: key))
    }
}
