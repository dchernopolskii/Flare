import Foundation

enum HiringCafeDailyError: LocalizedError {
    case browserVerificationRequired
    case invalidResponse
    case httpStatus(Int)
    case missingNextData
    case invalidNextData

    var errorDescription: String? {
        switch self {
        case .browserVerificationRequired:
            return "HiringCafe requires browser verification and is blocking automatic updates. Open HiringCafe to view jobs in your browser. You can retry here later."
        case .invalidResponse:
            return "HiringCafe returned an invalid response."
        case .httpStatus(let status):
            return "HiringCafe returned HTTP \(status)."
        case .missingNextData:
            return "HiringCafe's daily data was not found."
        case .invalidNextData:
            return "HiringCafe's daily data could not be read."
        }
    }
}

struct HiringCafeDailyPage: Equatable {
    let page: Int
    let jobs: [HiringCafeDailyJob]
}

struct HiringCafeLivePage: Equatable {
    let page: Int
    let isLastPage: Bool
    let jobs: [HiringCafeDailyJob]
}

enum HiringCafeDailyParser {
    private struct NextData: Decodable {
        let props: Props
    }

    private struct Props: Decodable {
        let pageProps: PageProps
    }

    private struct PageProps: Decodable {
        let jobs: [PayloadJob]
        let page: Int
    }

    private struct PayloadJob: Decodable {
        let path: String
        let title: String
        let company: String
        let location: String
        let category: String
        let postedAt: String
    }

    private struct LiveNextData: Decodable {
        let props: LiveProps
    }

    private struct LiveProps: Decodable {
        let pageProps: LivePageProps
    }

    private struct LivePageProps: Decodable {
        let ssrHits: [LivePayloadJob]
        let ssrPage: Int?
        let ssrIsLastPage: Bool?
    }

    private struct LivePayloadJob: Decodable {
        let requisitionID: String
        let jobInformation: LiveJobInformation
        let processedData: LiveProcessedData
        let enrichedCompanyData: LiveCompanyData?

        enum CodingKeys: String, CodingKey {
            case requisitionID = "requisition_id"
            case jobInformation = "job_information"
            case processedData = "v5_processed_job_data"
            case enrichedCompanyData = "enriched_company_data"
        }
    }

    private struct LiveJobInformation: Decodable {
        let title: String
    }

    private struct LiveProcessedData: Decodable {
        let companyName: String?
        let formattedWorkplaceLocation: String
        let workplaceType: String?
        let jobCategory: String
        let estimatedPublishDate: String

        enum CodingKeys: String, CodingKey {
            case companyName = "company_name"
            case formattedWorkplaceLocation = "formatted_workplace_location"
            case workplaceType = "workplace_type"
            case jobCategory = "job_category"
            case estimatedPublishDate = "estimated_publish_date"
        }
    }

    private struct LiveCompanyData: Decodable {
        let name: String?
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateFormatter = ISO8601DateFormatter()

    static func parsePage(html: String) throws -> HiringCafeDailyPage {
        let data = try nextData(in: html)
        guard let decoded = try? JSONDecoder().decode(NextData.self, from: data) else {
            throw HiringCafeDailyError.invalidNextData
        }

        let jobs = decoded.props.pageProps.jobs.compactMap { payload -> HiringCafeDailyJob? in
            guard let date = fractionalDateFormatter.date(from: payload.postedAt)
                    ?? dateFormatter.date(from: payload.postedAt) else {
                return nil
            }

            return HiringCafeDailyJob(
                path: payload.path,
                title: payload.title,
                company: payload.company,
                location: payload.location,
                category: payload.category,
                postedAt: date
            )
        }

        return HiringCafeDailyPage(page: decoded.props.pageProps.page, jobs: jobs)
    }

    static func parseLivePage(html: String) throws -> HiringCafeLivePage {
        let data = try nextData(in: html)
        guard let decoded = try? JSONDecoder().decode(LiveNextData.self, from: data) else {
            throw HiringCafeDailyError.invalidNextData
        }

        let pageProps = decoded.props.pageProps
        let jobs: [HiringCafeDailyJob] = pageProps.ssrHits.compactMap { payload -> HiringCafeDailyJob? in
            guard let date = fractionalDateFormatter.date(from: payload.processedData.estimatedPublishDate)
                    ?? dateFormatter.date(from: payload.processedData.estimatedPublishDate) else {
                return nil
            }

            var location = payload.processedData.formattedWorkplaceLocation
            if payload.processedData.workplaceType?.localizedCaseInsensitiveContains("remote") == true,
               !location.localizedCaseInsensitiveContains("remote") {
                location += ", Remote"
            }

            return HiringCafeDailyJob(
                path: "/job/\(payload.requisitionID)",
                title: payload.jobInformation.title,
                company: payload.processedData.companyName
                    ?? payload.enrichedCompanyData?.name
                    ?? "Unknown company",
                location: location,
                category: payload.processedData.jobCategory,
                postedAt: date
            )
        }

        return HiringCafeLivePage(
            page: pageProps.ssrPage ?? 1,
            isLastPage: pageProps.ssrIsLastPage ?? jobs.isEmpty,
            jobs: jobs
        )
    }

    private static func nextData(in html: String) throws -> Data {
        let pattern = #"<script[^>]*id=["']__NEXT_DATA__["'][^>]*>([\s\S]*?)</script>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let fullRange = NSRange(html.startIndex..., in: html)

        guard let match = regex.firstMatch(in: html, range: fullRange),
              let dataRange = Range(match.range(at: 1), in: html) else {
            throw HiringCafeDailyError.missingNextData
        }
        guard let data = String(html[dataRange]).data(using: .utf8) else {
            throw HiringCafeDailyError.invalidNextData
        }
        return data
    }
}

actor HiringCafeDailyFetcher {
    private static let baseURL = URL(string: "https://hiringcafe.com")!
    private static let pageSize = 200
    private static let dailyMaxPages = 100

    private let session: URLSession
    private let liveMaxPages: Int
    private let pageDelay: Duration

    init(
        session: URLSession = .shared,
        liveMaxPages: Int = 100,
        pageDelay: Duration = .milliseconds(350)
    ) {
        self.session = session
        self.liveMaxPages = max(1, liveMaxPages)
        self.pageDelay = pageDelay
    }

    func fetchFirstPage() async throws -> HiringCafeDailyPage {
        try await fetchPage(1)
    }

    func fetchLiveFirstPage(query: String) async throws -> HiringCafeLivePage {
        try await fetchLivePage(1, query: query)
    }

    func fetchLatestBatch(
        startingWith firstPage: HiringCafeDailyPage,
        liveFirstPage: HiringCafeLivePage,
        query: String,
        merging existingSnapshot: HiringCafeDailySnapshot? = nil,
        now: Date = Date()
    ) async throws -> HiringCafeDailySnapshot {
        guard let dailyNewestDate = firstPage.jobs.map(\.postedAt).max() else {
            throw HiringCafeDailyError.invalidNextData
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dailyBatchDate = calendar.startOfDay(for: dailyNewestDate)
        let newestDate = liveFirstPage.jobs.map(\.postedAt).max() ?? dailyNewestDate
        let batchDate = calendar.startOfDay(for: newestDate)
        var dailyJobs = firstPage.jobs.filter { calendar.isDate($0.postedAt, inSameDayAs: dailyBatchDate) }
        let canMerge = existingSnapshot.map {
            calendar.isDate($0.batchDate, inSameDayAs: batchDate)
        } ?? false
        let existingJobs = canMerge ? existingSnapshot?.jobs ?? [] : []
        let existingIDs = Set(existingJobs.map(\.id))
        let foundUnseenDailyJobs = dailyJobs.contains { !existingIDs.contains($0.id) }

        if firstPage.jobs.count >= Self.pageSize && (!canMerge || foundUnseenDailyJobs) {
            for pageNumber in 2...Self.dailyMaxPages {
                try await Task.sleep(for: pageDelay)
                let page = try await fetchPage(pageNumber)
                let jobsInBatch = page.jobs.filter { calendar.isDate($0.postedAt, inSameDayAs: dailyBatchDate) }
                dailyJobs.append(contentsOf: jobsInBatch)
                let pageHasUnseenJobs = jobsInBatch.contains { !existingIDs.contains($0.id) }
                if page.jobs.count < Self.pageSize || jobsInBatch.isEmpty || (canMerge && !pageHasUnseenJobs) {
                    break
                }
            }
        }

        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var liveJobs = liveFirstPage.jobs.filter { $0.postedAt >= cutoff }
        var paginatedLiveIDs = Set(liveFirstPage.jobs.map(\.id))
        let firstLivePageHasUnseenJobs = liveJobs.contains { !existingIDs.contains($0.id) }

        if !liveFirstPage.isLastPage,
           !liveJobs.isEmpty,
           (!canMerge || firstLivePageHasUnseenJobs),
           liveMaxPages >= 2 {
            for pageNumber in 2...liveMaxPages {
                try await Task.sleep(for: pageDelay)
                let page = try await fetchLivePage(pageNumber, query: query)
                let freshJobs = page.jobs.filter { $0.postedAt >= cutoff }
                let pageIDs = Set(freshJobs.map(\.id))
                let pageAddedNewID = !pageIDs.isSubset(of: paginatedLiveIDs)
                paginatedLiveIDs.formUnion(pageIDs)
                liveJobs.append(contentsOf: freshJobs)
                let pageHasUnseenJobs = freshJobs.contains { !existingIDs.contains($0.id) }
                let pageNewestDate = page.jobs.map(\.postedAt).max()

                if page.isLastPage
                    || page.jobs.isEmpty
                    || freshJobs.isEmpty
                    || pageNewestDate.map({ $0 < cutoff }) == true
                    || !pageAddedNewID
                    || (canMerge && !pageHasUnseenJobs) {
                    break
                }
            }
        }

        var seenIDs = Set<String>()
        let uniqueJobs = (liveJobs + dailyJobs + existingJobs)
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { $0.postedAt > $1.postedAt }

        return HiringCafeDailySnapshot(batchDate: batchDate, fetchedAt: Date(), jobs: uniqueJobs)
    }

    private func fetchPage(_ page: Int) async throws -> HiringCafeDailyPage {
        let path = page == 1 ? "/recently-posted-jobs" : "/recently-posted-jobs/\(page)"
        guard let url = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL else {
            throw HiringCafeDailyError.invalidResponse
        }

        let html = try await fetchHTML(at: url)
        return try HiringCafeDailyParser.parsePage(html: html)
    }

    private func fetchLivePage(_ page: Int, query: String) async throws -> HiringCafeLivePage {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw HiringCafeDailyError.invalidResponse
        }

        var searchState = ["sortBy": "date"]
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedQuery.isEmpty {
            searchState["searchQuery"] = normalizedQuery
        }
        guard let searchData = try? JSONSerialization.data(withJSONObject: searchState, options: [.sortedKeys]),
              let encodedSearchState = String(data: searchData, encoding: .utf8) else {
            throw HiringCafeDailyError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "searchState", value: encodedSearchState),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else {
            throw HiringCafeDailyError.invalidResponse
        }

        let html = try await fetchHTML(at: url)
        return try HiringCafeDailyParser.parseLivePage(html: html)
    }

    private func fetchHTML(at url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HiringCafeDailyError.invalidResponse
        }
        if httpResponse.statusCode == 403 {
            throw HiringCafeDailyError.browserVerificationRequired
        }
        guard httpResponse.statusCode == 200 else {
            throw HiringCafeDailyError.httpStatus(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw HiringCafeDailyError.invalidResponse
        }

        return html
    }
}
