import Foundation

actor EightfoldFetcher: URLBasedJobFetcherProtocol {
    private let trackingService = JobTrackingService.shared
    private let session: URLSession
    private let pageSize = 10
    private let maximumPages = 100

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        let endpoint = try await endpoint(for: url)
        guard let domain = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "domain" })?
            .value else {
            throw FetchError.invalidURL
        }

        let trackingKey = "eightfold_\(domain)"
        let storedJobDates = await trackingService.loadTrackingData(for: trackingKey)
        let currentDate = Date()

        var allPositions: [EightfoldPosition] = []
        var seenIDs = Set<String>()
        var total = Int.max
        var start = 0

        for _ in 0..<maximumPages where start < total {
            let response = try await fetchPage(endpoint: endpoint, start: start)
            total = response.count
            guard !response.positions.isEmpty else { break }

            for position in response.positions where seenIDs.insert(position.id).inserted {
                allPositions.append(position)
            }

            start += response.positions.count
            if response.positions.count < pageSize { break }
        }

        let jobs = allPositions.map { position in
            let jobID = "eightfold-\(domain)-\(position.id)"
            let location = position.locations?.filter { !$0.isEmpty }.joined(separator: " / ")
                ?? position.location
                ?? "Not specified"
            let jobURL = position.canonicalPositionURL ?? careerURL(for: position.id, endpoint: endpoint)

            return Job(
                id: jobID,
                title: position.postingName ?? position.name,
                location: location,
                postingDate: position.updatedAt.map(Date.init(timeIntervalSince1970:)),
                url: jobURL,
                description: "",
                workSiteFlexibility: position.workLocationOption?.capitalized,
                source: .eightfold,
                companyName: domain.components(separatedBy: ".").first?.capitalized ?? domain,
                department: position.department,
                category: position.businessUnit,
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
        if let endpoint = normalizedEndpoint(from: url) {
            return endpoint
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8),
              let domain = Self.extractDomain(from: html) else {
            throw FetchError.invalidResponse
        }

        var components = URLComponents(url: httpResponse.url ?? url, resolvingAgainstBaseURL: false)
        components?.path = "/api/apply/v2/jobs"
        components?.queryItems = [URLQueryItem(name: "domain", value: domain)]
        guard let endpoint = components?.url else { throw FetchError.invalidURL }
        return endpoint
    }

    private func normalizedEndpoint(from url: URL) -> URL? {
        let isBoardEndpoint = url.path == "/api/apply/v2/jobs"
        let isJobScopedEndpoint = url.path.hasPrefix("/api/apply/v2/jobs/") && url.path.hasSuffix("/jobs")
        guard isBoardEndpoint || isJobScopedEndpoint,
              let domain = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "domain" })?
                .value,
              !domain.isEmpty else {
            return nil
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/api/apply/v2/jobs"
        components?.queryItems = [URLQueryItem(name: "domain", value: domain)]
        return components?.url
    }

    private func fetchPage(endpoint: URL, start: Int) async throws -> EightfoldResponse {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        let domain = components?.queryItems?.first(where: { $0.name == "domain" })?.value
        components?.queryItems = [
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "num", value: String(pageSize))
        ]
        guard let pageURL = components?.url else { throw FetchError.invalidURL }

        var request = URLRequest(url: pageURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FetchError.invalidResponse
        }
        return try JSONDecoder().decode(EightfoldResponse.self, from: data)
    }

    private static func extractDomain(from html: String) -> String? {
        guard html.range(of: "smartApplyData", options: .caseInsensitive) != nil else {
            return nil
        }
        let decoded = html
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let pattern = #"\"domain\"\s*:\s*\"([^\"]+)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)),
              let range = Range(match.range(at: 1), in: decoded) else {
            return nil
        }
        return String(decoded[range])
    }

    private func careerURL(for positionID: String, endpoint: URL) -> String {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/careers/job/\(positionID)"
        components?.query = nil
        return components?.url?.absoluteString ?? endpoint.absoluteString
    }
}

private struct EightfoldResponse: Decodable {
    let count: Int
    let positions: [EightfoldPosition]
}

private struct EightfoldPosition: Decodable {
    let id: String
    let name: String
    let postingName: String?
    let location: String?
    let locations: [String]?
    let department: String?
    let businessUnit: String?
    let updatedAt: TimeInterval?
    let canonicalPositionURL: String?
    let workLocationOption: String?

    enum CodingKeys: String, CodingKey {
        case id, name, location, locations, department
        case postingName = "posting_name"
        case businessUnit = "business_unit"
        case updatedAt = "t_update"
        case canonicalPositionURL = "canonicalPositionUrl"
        case workLocationOption = "work_location_option"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try Self.decodeString(forKey: .id, from: container)
        name = try container.decode(String.self, forKey: .name)
        postingName = try container.decodeIfPresent(String.self, forKey: .postingName)
        location = try container.decodeIfPresent(String.self, forKey: .location)
        locations = try container.decodeIfPresent([String].self, forKey: .locations)
        department = try container.decodeIfPresent(String.self, forKey: .department)
        businessUnit = try container.decodeIfPresent(String.self, forKey: .businessUnit)
        updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt)
        canonicalPositionURL = try container.decodeIfPresent(String.self, forKey: .canonicalPositionURL)
        workLocationOption = try container.decodeIfPresent(String.self, forKey: .workLocationOption)
    }

    private static func decodeString(forKey key: CodingKeys, from container: KeyedDecodingContainer<CodingKeys>) throws -> String {
        if let string = try? container.decode(String.self, forKey: key) { return string }
        return String(try container.decode(Int.self, forKey: key))
    }
}
