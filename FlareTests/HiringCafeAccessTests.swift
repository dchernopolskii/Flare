import Foundation
import Testing
@testable import FlareJobMonitor

@Suite("HiringCafe access")
struct HiringCafeAccessTests {
    @Test("403 is reported as browser verification, not a parsing failure")
    func blockedRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BlockedHiringCafeProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let fetcher = HiringCafeDailyFetcher(session: session)
        do {
            _ = try await fetcher.fetchFirstPage()
            Issue.record("Expected the blocked request to fail")
        } catch HiringCafeDailyError.browserVerificationRequired {
            #expect(HiringCafeDailyError.browserVerificationRequired.localizedDescription.contains("Open HiringCafe"))
        }
    }
}

private final class BlockedHiringCafeProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html>Just a moment...</html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
