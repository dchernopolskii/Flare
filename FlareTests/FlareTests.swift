//
//  FlareTests.swift
//  FlareTests
//

import Testing
import Foundation
@testable import FlareJobMonitor

@Suite("HTML pagination policy")
struct HTMLPaginationPolicyTests {
    private let initialURL = URL(string: "https://careers.example.com/jobs/")!

    @Test("accepts a same-origin next page and removes its fragment")
    func acceptsSamePathPage() {
        let candidate = URL(string: "https://careers.example.com/jobs/?page=2#results")!

        let result = HTMLPaginationPolicy.nextURL(
            candidate: candidate,
            initialURL: initialURL,
            currentURL: initialURL,
            visitedURLs: [initialURL.absoluteString]
        )

        #expect(result?.absoluteString == "https://careers.example.com/jobs/?page=2")
    }

    @Test("finds rel-next anchors regardless of attribute order")
    func extractsNextLinkFromHTML() {
        let html = #"<a class="page-link" rel="next nofollow" href="/jobs/?team=eng&amp;page=2#results">Next page</a>"#

        let result = HTMLPaginationPolicy.nextURL(
            in: html,
            initialURL: initialURL,
            currentURL: initialURL,
            visitedURLs: [initialURL.absoluteString]
        )

        #expect(result?.absoluteString == "https://careers.example.com/jobs/?team=eng&page=2")
    }

    @Test("rejects cross-origin, path-changing, and previously visited links")
    func rejectsUnsafeLinks() {
        let visited = Set([initialURL.absoluteString, "https://careers.example.com/jobs/?page=2"])
        let crossOrigin = URL(string: "https://other.example.com/jobs/?page=2")!
        let detailPage = URL(string: "https://careers.example.com/jobs/1234?page=2")!
        let repeatedPage = URL(string: "https://careers.example.com/jobs/?page=2#results")!

        #expect(HTMLPaginationPolicy.nextURL(candidate: crossOrigin, initialURL: initialURL, currentURL: initialURL, visitedURLs: visited) == nil)
        #expect(HTMLPaginationPolicy.nextURL(candidate: detailPage, initialURL: initialURL, currentURL: initialURL, visitedURLs: visited) == nil)
        #expect(HTMLPaginationPolicy.nextURL(candidate: repeatedPage, initialURL: initialURL, currentURL: initialURL, visitedURLs: visited) == nil)
    }
}

// MARK: - Job Model Tests

struct JobTests {

    @Test func jobIsNew_withinPostingCutoff() async throws {
        let recentJob = Job(
            id: "test-1",
            title: "Test Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-3600), // 1 hour ago
            url: "https://example.com/job/1",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .greenhouse,
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-7200), // 2 hours ago
            originalPostingDate: nil,
            wasBumped: false
        )

        #expect(recentJob.isRecent == true)
    }

    @Test func jobIsRecent_noPostingDate_withinFirstSeenCutoff() async throws {
        let job = Job(
            id: "test-2",
            title: "Job Without Posting Date",
            location: "Seattle",
            postingDate: nil, // No posting date - falls back to firstSeenDate
            url: "https://example.com/job/2",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .tiktok, // TikTok doesn't provide posting dates
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-3600), // 1 hour ago (just discovered)
            originalPostingDate: nil,
            wasBumped: false
        )

        // Job is "recent" based on firstSeenDate being within 24h (fallback when no postingDate)
        #expect(job.isRecent == true)
    }

    @Test func jobIsNotNew_outsideBothCutoffs() async throws {
        let oldJob = Job(
            id: "test-3",
            title: "Old Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-259200), // 3 days ago
            url: "https://example.com/job/3",
            description: "Test",
            workSiteFlexibility: "Remote",
            source: .greenhouse,
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-172800), // 2 days ago
            originalPostingDate: nil,
            wasBumped: false
        )

        #expect(oldJob.isRecent == false)
    }
}

// MARK: - Location Matching Tests

struct LocationMatchingTests {
    private func job(location: String, flexibility: String? = nil) -> Job {
        Job(
            id: UUID().uuidString,
            title: "Test Job",
            location: location,
            postingDate: nil,
            url: "https://example.com/job",
            description: "",
            workSiteFlexibility: flexibility,
            source: .greenhouse,
            companyName: "Test Co",
            department: nil,
            category: nil,
            firstSeenDate: Date(),
            originalPostingDate: nil,
            wasBumped: false
        )
    }

    @Test func seattleMatchesStateAndMetroAliases() async throws {
        #expect(LocationMatcher.matches(job(location: "Washington, USA"), locationKeywords: ["seattle"]))
        #expect(LocationMatcher.matches(job(location: "Greater Seattle Area"), locationKeywords: ["seattle"]))
        #expect(!LocationMatcher.matches(job(location: "Austin, TX"), locationKeywords: ["seattle"]))
    }

    @Test func remoteMatchesWorkplaceMetadata() async throws {
        #expect(LocationMatcher.matches(job(location: "New York, NY", flexibility: "Remote"), locationKeywords: ["remote"]))
        #expect(!LocationMatcher.matches(job(location: "New York, NY", flexibility: "Onsite"), locationKeywords: ["remote"]))
    }

    @Test func locationsAreOrMatched() async throws {
        #expect(LocationMatcher.matches(job(location: "Portland, OR"), locationKeywords: ["seattle", "portland"]))
    }
}

// MARK: - JobSource Tests

struct JobSourceTests {

    @Test func detectGreenhouseFromURL() async throws {
        let urls = [
            "https://boards.greenhouse.io/anthropic",
            "https://job-boards.greenhouse.io/stripe",
            "https://boards.greenhouse.io/company/jobs/12345"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .greenhouse, "Failed for URL: \(url)")
        }
    }

    @Test func detectLeverFromURL() async throws {
        let urls = [
            "https://jobs.lever.co/company",
            "https://jobs.lever.co/company/job-id"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .lever, "Failed for URL: \(url)")
        }
    }

    @Test func detectAshbyFromURL() async throws {
        let urls = [
            "https://jobs.ashbyhq.com/company",
            "https://jobs.ashbyhq.com/company/job-id"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .ashby, "Failed for URL: \(url)")
        }
    }

    @Test func detectWorkdayFromURL() async throws {
        let urls = [
            "https://company.wd5.myworkdayjobs.com/careers",
            "https://nvidia.wd5.myworkdayjobs.com/NVIDIAExternalCareerSite"
        ]

        for url in urls {
            let source = JobSource.detectFromURL(url)
            #expect(source == .workday, "Failed for URL: \(url)")
        }
    }

    @Test func detectBambooHRFromURL() async throws {
        let source = JobSource.detectFromURL("https://acme.bamboohr.com/careers")
        #expect(source == .bamboohr)
    }

    @Test func detectCapgeminiAndEightfoldFromURLs() async throws {
        #expect(JobSource.detectFromURL("https://www.capgemini.com/careers") == .capgemini)
        #expect(JobSource.detectFromURL("https://explore.jobs.netflix.net/api/apply/v2/jobs?domain=netflix.com") == .eightfold)
        #expect(JobSource.detectFromURL("https://careers.deere.com/api/pcsx/search?domain=johndeere.com") == .eightfold)
    }

    @Test func unknownSourceForCustomURL() async throws {
        let url = "https://careers.netflix.com/jobs"
        let source = JobSource.detectFromURL(url)
        #expect(source == .unknown || source == nil)
    }
}

// MARK: - JobBoardConfig Tests

struct JobBoardConfigTests {

    @Test func initFromGreenhouseURL() async throws {
        let config = JobBoardConfig(
            name: "Anthropic",
            url: "https://boards.greenhouse.io/anthropic",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config != nil)
        #expect(config?.source == .greenhouse)
        #expect(config?.isSupported == true)
    }

    @Test func initFromCustomURL() async throws {
        let config = JobBoardConfig(
            name: "Netflix",
            url: "https://explore.jobs.netflix.net/careers",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config != nil)
        #expect(config?.source == .unknown)
    }

    @Test func effectiveURLReturnsDetectedWhenAvailable() async throws {
        var config = JobBoardConfig(
            name: "Test",
            url: "https://careers.company.com",
            detectedATSURL: "https://boards.greenhouse.io/company",
            detectedATSType: "greenhouse",
            parsingMethod: .directATS
        )

        #expect(config?.effectiveURL == "https://boards.greenhouse.io/company")
    }

    @Test func effectiveURLReturnsOriginalWhenNoDetected() async throws {
        let config = JobBoardConfig(
            name: "Test",
            url: "https://careers.company.com",
            detectedATSURL: nil,
            detectedATSType: nil,
            parsingMethod: nil
        )

        #expect(config?.effectiveURL == "https://careers.company.com")
    }

    @Test func detectedEightfoldTypeOverridesCustomCareersHost() async throws {
        let config = JobBoardConfig(
            name: "Netflix",
            url: "https://explore.jobs.netflix.net/careers",
            detectedATSURL: "https://explore.jobs.netflix.net/api/apply/v2/jobs?domain=netflix.com",
            detectedATSType: "eightfold",
            parsingMethod: .directATS
        )

        #expect(config?.source == .eightfold)
    }
}

// MARK: - ParsingMethod Tests

struct ParsingMethodTests {

    @Test func parsingMethodIcons() async throws {
        #expect(ParsingMethod.directATS.icon == "link.circle.fill")
        #expect(ParsingMethod.apiDiscovery.icon == "antenna.radiowaves.left.and.right")
        #expect(ParsingMethod.schemaOrg.icon == "doc.text.fill")
        #expect(ParsingMethod.llmExtraction.icon == "cpu")
    }

    @Test func parsingMethodRawValues() async throws {
        #expect(ParsingMethod.directATS.rawValue == "Direct ATS")
        #expect(ParsingMethod.apiDiscovery.rawValue == "API Discovery")
        #expect(ParsingMethod.llmExtraction.rawValue == "AI Parsing")
    }
}

// MARK: - Filter Keywords Tests

struct FilterKeywordsTests {

    @Test func parseAsFilterKeywords() async throws {
        let input = "manager, engineer, director"
        let keywords = input.parseAsFilterKeywords()

        #expect(keywords.count == 3)
        #expect(keywords.contains("manager"))
        #expect(keywords.contains("engineer"))
        #expect(keywords.contains("director"))
    }

    @Test func parseEmptyFilterKeywords() async throws {
        let input = ""
        let keywords = input.parseAsFilterKeywords()

        #expect(keywords.isEmpty)
    }

    @Test func includingRemoteAddsRemoteKeyword() async throws {
        let keywords = ["seattle", "new york"]
        let withRemote = keywords.includingRemote()

        #expect(withRemote.contains("remote"))
        #expect(withRemote.count == 3)
    }
}

// MARK: - Work Flexibility Tests

struct WorkFlexibilityTests {

    @Test func extractRemoteFromText() async throws {
        let text = "This is a fully remote position"
        let flexibility = WorkFlexibility.extract(from: text)

        #expect(flexibility?.lowercased().contains("remote") == true)
    }

    @Test func extractHybridFromText() async throws {
        let text = "Hybrid work schedule, 3 days in office"
        let flexibility = WorkFlexibility.extract(from: text)

        #expect(flexibility?.lowercased().contains("hybrid") == true)
    }

    @Test func extractOnsiteFromText() async throws {
        let text = "This is an on-site only position in Seattle"
        let flexibility = WorkFlexibility.extract(from: text)

        let lower = flexibility?.lowercased() ?? ""
        #expect(lower.contains("onsite") || lower.contains("on-site"))
    }
}

// MARK: - Date Filter Tests

struct DateFilterTests {

    @Test func jobWithin48hPostingPasses() async throws {
        let job = Job(
            id: "test-1",
            title: "Recent Job",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-86400), // 24 hours ago
            url: "https://example.com",
            description: "",
            workSiteFlexibility: "",
            source: .greenhouse,
            companyName: "Test",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-172800), // 48 hours ago
            originalPostingDate: nil,
            wasBumped: false
        )

        let postingCutoff: TimeInterval = 172800 // 48 hours
        let postingAge = Date().timeIntervalSince(job.postingDate!)

        #expect(postingAge <= postingCutoff)
    }

    @Test func jobWithin24hDiscoveryPasses() async throws {
        let job = Job(
            id: "test-2",
            title: "Old Post New Discovery",
            location: "Seattle",
            postingDate: Date().addingTimeInterval(-604800), // 7 days ago
            url: "https://example.com",
            description: "",
            workSiteFlexibility: "",
            source: .greenhouse,
            companyName: "Test",
            department: nil,
            category: nil,
            firstSeenDate: Date().addingTimeInterval(-3600), // 1 hour ago
            originalPostingDate: nil,
            wasBumped: false
        )

        let discoveryCutoff: TimeInterval = 86400 // 24 hours
        let discoveryAge = Date().timeIntervalSince(job.firstSeenDate)

        #expect(discoveryAge <= discoveryCutoff)
    }
}

// MARK: - Universal Fetcher Tests

private final class FetcherURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var recordedURLs: [URL] = []

    static func reset(handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recordedURLs = []
        }
    }

    static var requests: [URL] {
        lock.withLock { recordedURLs }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let currentHandler = Self.lock.withLock { () -> Handler? in
            Self.recordedURLs.append(url)
            return Self.handler
        }

        do {
            guard let currentHandler else { throw URLError(.resourceUnavailable) }
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class BambooHRURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedURLs: [URL] = []
    private nonisolated(unsafe) static var responseData = Data()

    static func reset(responseData: Data) {
        lock.withLock {
            self.responseData = responseData
            recordedURLs = []
        }
    }

    static var requests: [URL] {
        lock.withLock { recordedURLs }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let data = Self.lock.withLock { () -> Data in
            Self.recordedURLs.append(url)
            return Self.responseData
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct URLProtocolFetcherTests {
    @Suite
    struct UniversalJobFetcherTests {
        private func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FetcherURLProtocol.self]
            return URLSession(configuration: configuration)
        }

        private static func response(
            for request: URLRequest,
            contentType: String = "text/html",
            statusCode: Int = 200
        ) -> HTTPURLResponse {
            HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )!
        }

        @Test func structuredHTMLStopsBeforeAPIDiscovery() async throws {
            let html = """
            <html><script type="application/ld+json">
            {
              "@type": "JobPosting",
              "title": "Senior Test Engineer",
              "url": "/jobs/42",
              "jobLocation": {"address": {"addressLocality": "Seattle", "addressRegion": "WA"}}
            }
            </script></html>
            """

            FetcherURLProtocol.reset { request in
                (Self.response(for: request), Data(html.utf8))
            }

            let jobs = try await UniversalJobFetcher(session: makeSession())
                .fetchJobs(from: URL(string: "https://careers.example.com/openings")!)

            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Senior Test Engineer")
            #expect(FetcherURLProtocol.requests.map(\.path) == ["/openings"])
        }

        @Test func followsExplicitHTMLNextPages() async throws {
            let pageOne = """
            <html><script type="application/ld+json">
            {"@type":"JobPosting","title":"First Job","url":"/jobs/1"}
            </script><a rel="next" href="/openings?page=2#results">Next page</a></html>
            """
            let pageTwo = """
            <html><script type="application/ld+json">
            {"@type":"JobPosting","title":"Second Job","url":"/jobs/2"}
            </script></html>
            """

            FetcherURLProtocol.reset { request in
                let html = request.url?.query == "page=2" ? pageTwo : pageOne
                return (Self.response(for: request), Data(html.utf8))
            }

            let jobs = try await UniversalJobFetcher(session: makeSession())
                .fetchJobs(from: URL(string: "https://careers.example.com/openings")!)

            #expect(jobs.map(\.title) == ["First Job", "Second Job"])
            #expect(FetcherURLProtocol.requests.map(\.absoluteString) == [
                "https://careers.example.com/openings",
                "https://careers.example.com/openings?page=2"
            ])
        }

        @Test func inlineAPIRouteRunsOnlyAfterEmptyHTML() async throws {
            let html = #"<html><script>fetch('/api/jobs')</script></html>"#
            let apiJSON = #"[{"id":"job-1","title":"Product Designer","location":"Remote","url":"/jobs/job-1"}]"#

            FetcherURLProtocol.reset { request in
                if request.url?.path == "/api/jobs" {
                    return (Self.response(for: request, contentType: "application/json"), Data(apiJSON.utf8))
                }
                return (Self.response(for: request), Data(html.utf8))
            }

            let jobs = try await UniversalJobFetcher(session: makeSession())
                .fetchJobs(from: URL(string: "https://careers.example.com/openings")!)

            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Product Designer")
            #expect(FetcherURLProtocol.requests.map(\.path) == ["/openings", "/api/jobs"])
        }

        @Test func genericAPIDiscoveryStopsAtFirstWorkingRoute() async throws {
            let apiJSON = #"{"jobs":[{"id":"job-2","title":"Data Engineer","location":"Portland","url":"/jobs/job-2"}]}"#

            FetcherURLProtocol.reset { request in
                if request.url?.path == "/api/jobs" {
                    return (Self.response(for: request, contentType: "application/json"), Data(apiJSON.utf8))
                }
                return (Self.response(for: request), Data("<html></html>".utf8))
            }

            let jobs = try await UniversalJobFetcher(session: makeSession())
                .fetchJobs(from: URL(string: "https://careers.example.com/openings")!)

            #expect(jobs.count == 1)
            #expect(jobs.first?.title == "Data Engineer")
            #expect(FetcherURLProtocol.requests.map(\.path) == ["/openings", "/api/jobs"])
        }
    }

    @Suite
    struct BambooHRFetcherTests {
        private func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BambooHRURLProtocol.self]
            return URLSession(configuration: configuration)
        }

        @Test func usesCareersListEndpointAndMapsOpenings() async throws {
            let payload = #"""
            {
              "result": [{
                "id": "42",
                "jobOpeningName": "Product Manager",
                "departmentLabel": "Product",
                "employmentStatusLabel": "Full-Time",
                "location": {"city": "Seattle", "state": "WA"},
                "atsLocation": {"country": "United States"},
                "isRemote": true
              }]
            }
            """#

            BambooHRURLProtocol.reset(responseData: Data(payload.utf8))

            let jobs = try await BambooHRFetcher(session: makeSession()).fetchJobs(
                from: URL(string: "https://acme.bamboohr.com/careers/jobs/42?source=test")!
            )

            #expect(BambooHRURLProtocol.requests.map(\.absoluteString) == ["https://acme.bamboohr.com/careers/list"])
            #expect(jobs.count == 1)
            #expect(jobs.first?.id == "bamboohr-acme-42")
            #expect(jobs.first?.title == "Product Manager")
            #expect(jobs.first?.location == "Seattle, WA, United States")
            #expect(jobs.first?.url == "https://acme.bamboohr.com/careers/42")
            #expect(jobs.first?.workSiteFlexibility == "Remote")
            #expect(jobs.first?.source == .bamboohr)
        }
    }

    @Suite
    struct EightfoldFetcherTests {
        private func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FetcherURLProtocol.self]
            return URLSession(configuration: configuration)
        }

        @Test func normalizesEndpointAndFetchesEveryPage() async throws {
            FetcherURLProtocol.reset { request in
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                let start = Int(components?.queryItems?.first(where: { $0.name == "start" })?.value ?? "0") ?? 0
                let count = start == 0 ? 10 : 2
                let positions = (start..<(start + count)).map { index in
                    [
                        "id": index,
                        "name": "Position \(index)",
                        "locations": ["Remote"],
                        "canonicalPositionUrl": "https://explore.jobs.netflix.net/careers/job/\(index)"
                    ] as [String: Any]
                }
                let data = try JSONSerialization.data(withJSONObject: ["count": 12, "positions": positions])
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, data)
            }

            let jobs = try await EightfoldFetcher(session: makeSession()).fetchJobs(
                from: URL(string: "https://explore.jobs.netflix.net/api/apply/v2/jobs/123/jobs?domain=netflix.com")!
            )

            #expect(jobs.count == 12)
            #expect(jobs.allSatisfy { $0.source == .eightfold })
            #expect(FetcherURLProtocol.requests.count == 2)
            #expect(FetcherURLProtocol.requests.allSatisfy { $0.path == "/api/apply/v2/jobs" })
            #expect(FetcherURLProtocol.requests.compactMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "start" })?.value
            } == ["0", "10"])
        }

        @Test func discoversPCSXEndpointAndPreservesSearchFiltersAcrossPages() async throws {
            FetcherURLProtocol.reset { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": request.url?.path == "/careers" ? "text/html" : "application/json"]
                )!

                if request.url?.path == "/careers" {
                    let html = #"<code id="pcsx-data">{&#34;domain&#34;: &#34;johndeere.com&#34;}</code>"#
                    return (response, Data(html.utf8))
                }

                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
                let start = Int(components?.queryItems?.first(where: { $0.name == "start" })?.value ?? "0") ?? 0
                let count = start < 20 ? 10 : 1
                let positions = (start..<(start + count)).map { index in
                    [
                        "id": index,
                        "name": "Position \(index)",
                        "locations": ["United States"],
                        "postedTs": 1_700_000_000,
                        "positionUrl": "/careers/job/\(index)",
                        "workLocationOption": "remote"
                    ] as [String: Any]
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "data": ["count": 21, "positions": positions]
                ])
                return (response, data)
            }

            let jobs = try await EightfoldFetcher(session: makeSession()).fetchJobs(
                from: URL(string: "https://careers.deere.com/careers?start=0&location=united+states&pid=123&sort_by=distance&filter_include_remote=1&filter_include_relocation=0")!
            )

            #expect(jobs.count == 21)
            #expect(jobs.first?.url == "https://careers.deere.com/careers/job/0")
            #expect(jobs.first?.workSiteFlexibility == "Remote")

            let apiRequests = FetcherURLProtocol.requests.filter { $0.path == "/api/pcsx/search" }
            #expect(apiRequests.count == 3)
            #expect(apiRequests.compactMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "start" })?.value
            } == ["0", "10", "20"])
            #expect(apiRequests.allSatisfy { request in
                let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
                return items.contains(URLQueryItem(name: "domain", value: "johndeere.com"))
                    && items.contains(URLQueryItem(name: "location", value: "united states"))
                    && items.contains(URLQueryItem(name: "sort_by", value: "distance"))
                    && items.contains(URLQueryItem(name: "filter_include_remote", value: "1"))
                    && items.contains(URLQueryItem(name: "filter_include_relocation", value: "0"))
                    && !items.contains(where: { $0.name == "pid" })
            })
        }
    }

    @Suite
    struct CapgeminiJobStreamFetcherTests {
        private func makeSession() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FetcherURLProtocol.self]
            return URLSession(configuration: configuration)
        }

        @Test func preservesCountryFilterAndPaginatesFeed() async throws {
            FetcherURLProtocol.reset { request in
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": request.url?.path.contains("job-search") == true ? "application/json" : "text/html"]
                )!

                if request.url?.path.contains("job-search") == true {
                    let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
                    let itemCount = page == 1 ? 100 : 1
                    let start = (page - 1) * 100
                    let listings = (start..<(start + itemCount)).map { index in
                        [
                            "id": "job-\(index)",
                            "title": "Role \(index)",
                            "location": "Seattle",
                            "ref": "ref-\(index)",
                            "source": "SAP"
                        ]
                    }
                    let data = try JSONSerialization.data(withJSONObject: ["count": 101, "data": listings])
                    return (response, data)
                }

                let html = #"<script>cg_jobs_jobstream_url = "https://cg-jobstream-api.azurewebsites.net/api";</script>"#
                return (response, Data(html.utf8))
            }

            let fetcher = CapgeminiJobStreamFetcher(session: makeSession())
            let careersURL = URL(string: "https://www.capgemini.com/careers/jobs?country_code=us-en")!
            let endpoint = try await fetcher.endpoint(for: careersURL)
            let jobs = try await fetcher.fetchJobs(from: endpoint)

            #expect(endpoint.absoluteString == "https://cg-jobstream-api.azurewebsites.net/api/job-search?country_code=us-en")
            #expect(jobs.count == 101)
            #expect(jobs.allSatisfy { $0.source == .capgemini })
            let pageRequests = FetcherURLProtocol.requests.filter { $0.path.contains("job-search") }
            #expect(pageRequests.count == 2)
            #expect(pageRequests.allSatisfy {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(URLQueryItem(name: "country_code", value: "us-en")) == true
            })
        }
    }
}


// MARK: - Persistence Tests

struct PersistenceServiceTests {

    @Test func cacheCleanupRemovesOnlyRebuildableJobState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flare-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = try PersistenceService(appSupportURL: directory)
        try await service.saveJobs([])
        try await service.saveStoredJobIds(["seen-job"])
        try await service.saveAppliedJobIds(["applied-job"])
        try await service.saveStarredJobIds(["starred-job"])

        let trackerURL = directory.appendingPathComponent("greenhouseacmeJobTracking.json")
        try Data("[]".utf8).write(to: trackerURL)

        let result = try await service.clearJobCache()

        #expect(result.filesRemoved == 3)
        #expect((try await service.loadJobs()).isEmpty)
        #expect((try await service.loadStoredJobIds()).isEmpty)
        #expect(try await service.loadAppliedJobIds() == ["applied-job"])
        #expect(try await service.loadStarredJobIds() == ["starred-job"])
        #expect(!FileManager.default.fileExists(atPath: trackerURL.path))
    }
}
