import Foundation

actor BambooHRFetcher: URLBasedJobFetcherProtocol {
    private let trackingService = JobTrackingService.shared
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchJobs(from url: URL, titleFilter: String = "", locationFilter: String = "") async throws -> [Job] {
        guard let careersURL = careersListURL(from: url), let company = careersURL.host?.components(separatedBy: ".").first else {
            throw FetchError.invalidURL
        }

        var request = URLRequest(url: careersURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        guard httpResponse.statusCode == 200 else { throw FetchError.httpError(statusCode: httpResponse.statusCode) }

        let payload: BambooHRCareersResponse
        do {
            payload = try JSONDecoder().decode(BambooHRCareersResponse.self, from: data)
        } catch {
            throw FetchError.decodingError(details: "Failed to decode BambooHR careers response: \(error.localizedDescription)")
        }

        let currentDate = Date()
        let trackingKey = "bamboohr_\(company)"
        let storedJobDates = await trackingService.loadTrackingData(for: trackingKey)
        let boardURL = careersURL.deletingLastPathComponent()
        let jobs = payload.result.compactMap { opening -> Job? in
            guard !opening.jobOpeningName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let locationParts = [opening.location?.city, opening.location?.state, opening.atsLocation?.city, opening.atsLocation?.state, opening.atsLocation?.province, opening.atsLocation?.country]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let location = Array(NSOrderedSet(array: locationParts)).compactMap { $0 as? String }.joined(separator: ", ")
            let jobID = "bamboohr-\(company)-\(opening.id)"
            let firstSeenDate = storedJobDates[jobID] ?? currentDate
            let jobURL = boardURL.appendingPathComponent(opening.id).absoluteString

            return Job(
                id: jobID,
                title: opening.jobOpeningName,
                location: location.isEmpty ? "Not specified" : location,
                postingDate: nil,
                url: jobURL,
                description: "",
                workSiteFlexibility: opening.isRemote == true ? "Remote" : nil,
                source: .bamboohr,
                companyName: company.replacingOccurrences(of: "-", with: " ").capitalized,
                department: opening.departmentLabel,
                category: opening.employmentStatusLabel,
                firstSeenDate: firstSeenDate,
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

    private func careersListURL(from url: URL) -> URL? {
        guard url.host?.lowercased().hasSuffix(".bamboohr.com") == true else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = "/careers/list"
        components?.query = nil
        return components?.url
    }
}

private struct BambooHRCareersResponse: Decodable {
    let result: [BambooHROpening]
}

private struct BambooHROpening: Decodable {
    let id: String
    let jobOpeningName: String
    let departmentLabel: String?
    let employmentStatusLabel: String?
    let location: BambooHRLocation?
    let atsLocation: BambooHRLocation?
    let isRemote: Bool?
}

private struct BambooHRLocation: Decodable {
    let country: String?
    let state: String?
    let province: String?
    let city: String?
}
