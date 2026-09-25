import Foundation
import Testing
@testable import FlareJobMonitor

@Suite("ATS detection")
struct ATSDetectorTests {
    @Test("Custom careers pages continue to the verified Greenhouse board",
          arguments: ["discord", "branded", "plain"])
    func customCareersPage(company: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ATSFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let detector = ATSDetectorService(session: session)

        let result = try await detector.detectATSEnhanced(
            from: #require(URL(string: "https://\(company).com/careers"))
        )

        #expect(result.source == .greenhouse)
        #expect(result.confidence == .certain)
        #expect(result.actualATSUrl == "https://job-boards.greenhouse.io/\(company)")
        #expect(result.apiEndpoint == "https://boards-api.greenhouse.io/v1/boards/\(company)/jobs?content=true")
        #expect(result.evidence.contains { $0.kind == "validated endpoint" })
    }

    @Test("Direct Greenhouse board URLs still use the quick match")
    func directBoard() async throws {
        let result = try await ATSDetectorService().detectATSEnhanced(
            from: #require(URL(string: "https://job-boards.greenhouse.io/discord"))
        )
        #expect(result.source == .greenhouse)
        #expect(result.actualATSUrl == "https://job-boards.greenhouse.io/discord")
        #expect(result.evidence.contains { $0.kind == "URL" })
    }
}

private final class ATSFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: String
        if url.host == "discord.com", url.path == "/careers" {
            // The real page's careers-* CSS matches the weak iCIMS marker.
            body = "<html><h1 class='careers-heading'>Careers</h1></html>"
        } else if url.host == "plain.com", url.path == "/careers" {
            body = "<html><h1>Careers</h1></html>"
        } else if url.host == "branded.com", url.path == "/careers" {
            body = "<html><h1>Careers</h1><script src='https://boards.greenhouse.io/embed/job_board/js'></script></html>"
        } else if url.host == "boards-api.greenhouse.io", url.path == "/v1/boards/discord/jobs" {
            body = #"{"jobs":[{"id":1,"absolute_url":"https://job-boards.greenhouse.io/discord/jobs/1"}]}"#
        } else if url.host == "boards-api.greenhouse.io", url.path == "/v1/boards/plain/jobs" {
            body = #"{"jobs":[{"id":1,"absolute_url":"https://job-boards.greenhouse.io/plain/jobs/1"}]}"#
        } else if url.host == "boards-api.greenhouse.io", url.path == "/v1/boards/branded/jobs" {
            body = #"{"jobs":[{"id":1,"absolute_url":"https://branded.com/careers?gh_jid=1"}]}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
