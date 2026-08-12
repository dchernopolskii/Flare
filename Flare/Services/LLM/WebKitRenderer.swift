//
//  WebKitRenderer.swift
//  Flare
//
//  Created by Dan on 12/9/25.
//

import Foundation
import WebKit

struct DetectedAPICall {
    let url: String
    let method: String
    let requestBody: String?
    let headers: [String: String]?
    let response: String?
}

struct HTMLPaginationPolicy {
    static func nextURL(
        in html: String,
        initialURL: URL,
        currentURL: URL,
        visitedURLs: Set<String>
    ) -> URL? {
        guard let anchorRegex = try? NSRegularExpression(pattern: #"<a\b[^>]*>"#, options: .caseInsensitive),
              let relRegex = try? NSRegularExpression(pattern: #"\brel\s*=\s*[\"']([^\"']*)[\"']"#, options: .caseInsensitive),
              let hrefRegex = try? NSRegularExpression(pattern: #"\bhref\s*=\s*[\"']([^\"']+)[\"']"#, options: .caseInsensitive) else {
            return nil
        }

        let anchors = anchorRegex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for anchor in anchors {
            guard let anchorRange = Range(anchor.range, in: html) else { continue }
            let tag = String(html[anchorRange])
            let tagRange = NSRange(tag.startIndex..., in: tag)

            guard let relMatch = relRegex.firstMatch(in: tag, range: tagRange),
                  let relRange = Range(relMatch.range(at: 1), in: tag),
                  tag[relRange].split(whereSeparator: { $0.isWhitespace }).contains(where: { $0.lowercased() == "next" }),
                  let hrefMatch = hrefRegex.firstMatch(in: tag, range: tagRange),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else {
                continue
            }

            let href = String(tag[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            guard let candidate = URL(string: href, relativeTo: currentURL)?.absoluteURL else { continue }
            return nextURL(
                candidate: candidate,
                initialURL: initialURL,
                currentURL: currentURL,
                visitedURLs: visitedURLs
            )
        }

        return nil
    }

    static func nextURL(
        candidate: URL,
        initialURL: URL,
        currentURL: URL,
        visitedURLs: Set<String>
    ) -> URL? {
        guard let initial = normalizedComponents(for: initialURL),
              let current = normalizedComponents(for: currentURL),
              var next = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let nextScheme = next.scheme?.lowercased(),
              let nextHost = next.host?.lowercased(),
              nextScheme == initial.scheme,
              nextHost == initial.host,
              next.port == initial.port,
              normalizedPath(next.path) == initial.path,
              normalizedPath(next.path) == current.path else {
            return nil
        }

        next.fragment = nil
        guard let normalizedURL = next.url,
              normalizedURL.absoluteString != currentURL.removingFragment.absoluteString,
              !visitedURLs.contains(normalizedURL.absoluteString) else {
            return nil
        }

        return normalizedURL
    }

    private static func normalizedComponents(for url: URL) -> (scheme: String, host: String, port: Int?, path: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }

        return (scheme, host, components.port, normalizedPath(components.path))
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.count > 1 else { return path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

extension URL {
    var removingFragment: URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url ?? self
    }
}

@MainActor
class WebKitRenderer: NSObject, WKNavigationDelegate {
    private static let maxCapturedCalls = 12
    private static let maxRequestBodyCharacters = 16_384
    private static let maxResponseCharacters = 131_072
    private static let maxTotalCapturedCharacters = 524_288
    private static let maxPaginatedHTMLCharacters = 8_000_000
    private static let defaultMaxHTMLPages = 25

    private var webView: WKWebView?
    private var renderContinuation: CheckedContinuation<RenderResult, Error>?
    private var loadTimeout: Task<Void, Never>?
    private var initialURL: URL?
    private var currentURL: URL?
    private var waitTime: TimeInterval = 5.0
    private var maxHTMLPages = defaultMaxHTMLPages
    private var visitedURLs = Set<String>()
    private var collectedHTMLPages: [String] = []
    private var collectedAPICalls: [DetectedAPICall] = []
    private var collectedHTMLCharacters = 0
    private var isExtracting = false

    struct RenderResult {
        let html: String
        let detectedAPICalls: [DetectedAPICall]
    }

    func renderWithAPIDetection(
        from url: URL,
        waitTime: TimeInterval = 5.0,
        maxHTMLPages: Int = 25
    ) async throws -> RenderResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // A renderer is single-use while a navigation is active. Finishing the
                // previous request keeps a reused instance from leaking its web view or
                // leaving its caller suspended forever.
                finish(throwing: CancellationError())
                renderContinuation = continuation
                self.initialURL = url.removingFragment
                self.currentURL = url.removingFragment
                self.waitTime = waitTime
                self.maxHTMLPages = max(1, maxHTMLPages)
                self.visitedURLs = [url.removingFragment.absoluteString]
                self.collectedHTMLPages = []
                self.collectedAPICalls = []
                self.collectedHTMLCharacters = 0
                self.isExtracting = false

                guard !Task.isCancelled else {
                    finish(throwing: CancellationError())
                    return
                }

                // Create headless WebView with custom config
                let config = WKWebViewConfiguration()
                config.websiteDataStore = .nonPersistent()
                config.mediaTypesRequiringUserActionForPlayback = .all

                let interceptScript = """
            (function() {
                window.__apiCalls = [];
                let capturedCharacters = 0;
                const maxCalls = \(Self.maxCapturedCalls);
                const maxBodyCharacters = \(Self.maxRequestBodyCharacters);
                const maxResponseCharacters = \(Self.maxResponseCharacters);
                const maxTotalCapturedCharacters = \(Self.maxTotalCapturedCharacters);
                const jobPatterns = ['job', 'career', 'position', 'opening', 'requisition', 'posting', 'vacancy', 'opportunity', 'search', 'api', 'graphql', 'hiring', 'talent', 'recruit', 'apply', 'listing', 'role', 'employment', 'work', 'team'];
                const excludedPatterns = ['analytics', 'tracking', 'telemetry', 'beacon', 'pixel', 'facebook', 'google-analytics', 'gtag', 'hotjar', 'segment'];

                function isCandidateURL(value) {
                    const url = String(value || '').toLowerCase();
                    return jobPatterns.some((pattern) => url.includes(pattern)) &&
                        !excludedPatterns.some((pattern) => url.includes(pattern));
                }

                function truncate(value, maximum) {
                    const text = String(value || '');
                    return text.length > maximum ? text.slice(0, maximum) : text;
                }

                function normalizeHeaders(headers) {
                    const result = {};
                    if (!headers) { return result; }
                    try {
                        if (headers instanceof Headers) {
                            let count = 0;
                            headers.forEach((value, key) => {
                                if (count++ < 30) { result[truncate(key, 128)] = truncate(value, 1024); }
                            });
                        } else if (Array.isArray(headers)) {
                            headers.slice(0, 30).forEach(([key, value]) => { result[truncate(key, 128)] = truncate(value, 1024); });
                        } else {
                            Object.keys(headers).slice(0, 30).forEach((key) => { result[truncate(key, 128)] = truncate(headers[key], 1024); });
                        }
                    } catch (e) {}
                    return result;
                }

                function addCall(url, method, body, headers, type) {
                    if (!isCandidateURL(url) || window.__apiCalls.length >= maxCalls) { return null; }
                    const capturedURL = truncate(url, 4096);
                    const capturedMethod = truncate(method || 'GET', 32);
                    const requestBody = truncate(body, maxBodyCharacters);
                    let headerCharacters = 0;
                    try { headerCharacters = JSON.stringify(headers).length; } catch (e) {}
                    const metadataCharacters = capturedURL.length + capturedMethod.length + requestBody.length + headerCharacters + String(type || '').length;
                    if (capturedCharacters + metadataCharacters >= maxTotalCapturedCharacters) { return null; }
                    capturedCharacters += metadataCharacters;
                    const call = {
                        url: capturedURL,
                        method: capturedMethod,
                        body: requestBody,
                        headers: headers,
                        type: type,
                        response: null,
                        status: null
                    };
                    window.__apiCalls.push(call);
                    return call;
                }

                function captureResponse(call, value) {
                    if (!call || capturedCharacters >= maxTotalCapturedCharacters) { return; }
                    const remaining = maxTotalCapturedCharacters - capturedCharacters;
                    const response = truncate(value, Math.min(maxResponseCharacters, remaining));
                    capturedCharacters += response.length;
                    call.response = response;
                }

                // Intercept fetch
                const originalFetch = window.fetch;
                window.fetch = function(...args) {
                    const url = typeof args[0] === 'string' ? args[0] : args[0].url;
                    const options = args[1] || {};
                    const method = options.method || (args[0] && args[0].method) || 'GET';

                    let body = null;
                    if (options.body) {
                        if (typeof options.body === 'string') {
                            body = options.body;
                        } else {
                            try {
                                body = JSON.stringify(options.body);
                            } catch (e) {
                                body = '[could not stringify body]';
                            }
                        }
                    }

                    const headers = normalizeHeaders(options.headers || (args[0] && args[0].headers));
                    const call = addCall(url, method, body, headers, 'fetch');

                    return originalFetch.apply(this, args).then((response) => {
                        if (!call) { return response; }
                        call.status = response.status;
                        const contentType = response.headers && response.headers.get ? (response.headers.get('content-type') || '') : '';
                        if (contentType.includes('json') || contentType.includes('text')) {
                            response.clone().text().then((text) => {
                                captureResponse(call, text);
                            }).catch(() => {});
                        }
                        return response;
                    });
                };

                // Intercept XMLHttpRequest
                const originalXHROpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    this.__url = url;
                    this.__method = method;
                    this.__headers = {};
                    return originalXHROpen.apply(this, arguments);
                };

                const originalXHRSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
                XMLHttpRequest.prototype.setRequestHeader = function(header, value) {
                    this.__headers = this.__headers || {};
                    this.__headers[String(header)] = String(value);
                    return originalXHRSetRequestHeader.apply(this, arguments);
                };

                const originalXHRSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.send = function(body) {
                    if (this.__url) {
                        const call = addCall(this.__url, this.__method || 'GET', body || null, this.__headers || {}, 'xhr');
                        if (call) {
                            this.addEventListener('loadend', function() {
                                call.status = this.status;
                                const contentType = this.getResponseHeader('content-type') || '';
                                if (contentType.includes('json') || contentType.includes('text')) {
                                    captureResponse(call, this.responseText || '');
                                }
                            });
                        }
                    }
                    return originalXHRSend.apply(this, arguments);
                };

                console.log('[Interceptor] Network interception enabled');
            })();
            """

                let userScript = WKUserScript(source: interceptScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
                config.userContentController.addUserScript(userScript)

                webView = WKWebView(frame: .zero, configuration: config)
                webView?.navigationDelegate = self

                print("[WebKitRenderer] Loading with API interception: \(url.absoluteString)")

                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                webView?.load(request)
                scheduleExtractionTimeout(after: waitTime)
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(throwing: CancellationError())
            }
        })
    }

    func renderHTML(from url: URL, waitTime: TimeInterval = 5.0) async throws -> String {
        let result = try await renderWithAPIDetection(from: url, waitTime: waitTime)
        return result.html
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            print("[WebKitRenderer] Page loaded, waiting for JavaScript execution...")

            self.loadTimeout?.cancel()
            self.loadTimeout = nil

            let delay: TimeInterval = self.collectedHTMLPages.isEmpty ? 2.0 : 0.35
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

            print("[WebKitRenderer] Extracting data...")
            guard !Task.isCancelled, self.renderContinuation != nil else { return }
            await self.extractRenderResult()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[WebKitRenderer] Navigation failed: \(error.localizedDescription)")
            finishAfterNavigationFailure(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            print("[WebKitRenderer] Provisional navigation failed: \(error.localizedDescription)")
            finishAfterNavigationFailure(error)
        }
    }

    // MARK: - Private

    private func scheduleExtractionTimeout(after delay: TimeInterval) {
        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }

            guard let self, self.renderContinuation != nil else { return }
            print("[WebKitRenderer] Timeout reached, extracting data...")
            await self.extractRenderResult()
        }
    }

    private func extractRenderResult() async {
        guard let webView = webView,
              renderContinuation != nil,
              !isExtracting else { return }

        isExtracting = true

        do {
            let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
            let apiCallsJSON = try await webView.evaluateJavaScript("JSON.stringify(window.__apiCalls || [])") as? String ?? "[]"
            let nextURLString = try await webView.evaluateJavaScript(
                "document.querySelector('a[rel~=\"next\"]')?.href || null"
            ) as? String

            print("[WebKitRenderer] Extracted \(html.count) characters of rendered HTML")
            print("[WebKitRenderer] API calls JSON: \(apiCallsJSON.prefix(500))")

            var detectedCalls: [DetectedAPICall] = []
            if let data = apiCallsJSON.data(using: .utf8),
               let calls = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {

                for call in calls {
                    if let url = call["url"] as? String,
                       let method = call["method"] as? String {

                        // Expanded list of job-related URL patterns
                        let jobPatterns = [
                            "job", "jobs",
                            "career", "careers",
                            "position", "positions",
                            "opening", "openings",
                            "requisition", "requisitions",
                            "posting", "postings",
                            "vacancy", "vacancies",
                            "opportunity", "opportunities",
                            "search",
                            "api",
                            "graphql",
                            "hiring",
                            "talent",
                            "recruit",
                            "apply",
                            "listing", "listings",
                            "role", "roles",
                            "employment",
                            "work",
                            "team"
                        ]

                        // Patterns to exclude (likely not job-related)
                        let excludePatterns = [
                            "analytics",
                            "tracking",
                            "telemetry",
                            "beacon",
                            "pixel",
                            "ad",
                            "ads",
                            "facebook",
                            "google-analytics",
                            "gtag",
                            "hotjar",
                            "segment"
                        ]

                        let urlLower = url.lowercased()
                        let isJobRelated = jobPatterns.contains { urlLower.contains($0) }
                        let isExcluded = excludePatterns.contains { urlLower.contains($0) }

                        if isJobRelated && !isExcluded {
                            let body = call["body"] as? String
                            let headers: [String: String]?
                            if let headerDict = call["headers"] as? [String: Any] {
                                headers = Dictionary(uniqueKeysWithValues: headerDict.compactMap { key, value in
                                    guard JSONSerialization.isValidJSONObject([key: value]) || value is String || value is NSNumber else {
                                        return nil
                                    }
                                    return (key, String(describing: value))
                                })
                            } else {
                                headers = nil
                            }
                            let response = call["response"] as? String

                            print("[WebKitRenderer] Detected API call: \(method) \(url)")
                            if let body = body {
                                print("[WebKitRenderer]   Body: \(body.prefix(200))...")
                            }

                            detectedCalls.append(DetectedAPICall(
                                url: url,
                                method: method,
                                requestBody: body,
                                headers: headers,
                                response: response
                            ))
                        }
                    }
                }
            }

            print("[WebKitRenderer] Detected \(detectedCalls.count) API calls")

            collectedHTMLPages.append(html)
            collectedHTMLCharacters += html.count
            let remainingCallSlots = max(0, Self.maxCapturedCalls - collectedAPICalls.count)
            collectedAPICalls.append(contentsOf: detectedCalls.prefix(remainingCallSlots))

            if collectedHTMLPages.count < maxHTMLPages,
               collectedHTMLCharacters < Self.maxPaginatedHTMLCharacters,
               let initialURL,
               let currentURL,
               let nextURLString,
               let candidate = URL(string: nextURLString, relativeTo: currentURL)?.absoluteURL,
               let nextURL = HTMLPaginationPolicy.nextURL(
                   candidate: candidate,
                   initialURL: initialURL,
                   currentURL: currentURL,
                   visitedURLs: visitedURLs
               ) {
                print("[WebKitRenderer] Following HTML pagination to page \(collectedHTMLPages.count + 1): \(nextURL.absoluteString)")
                self.currentURL = nextURL
                visitedURLs.insert(nextURL.absoluteString)
                isExtracting = false
                scheduleExtractionTimeout(after: waitTime)
                webView.load(URLRequest(url: nextURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
                return
            }

            let combinedHTML = collectedHTMLPages.joined(separator: "\n<!-- FLARE_PAGE_BREAK -->\n")
            print("[WebKitRenderer] Completed \(collectedHTMLPages.count) HTML page(s), \(combinedHTML.count) total characters")
            finish(returning: RenderResult(html: combinedHTML, detectedAPICalls: collectedAPICalls))

        } catch {
            print("[WebKitRenderer] Failed to extract data: \(error.localizedDescription)")
            finish(throwing: error)
        }
    }

    private func finish(returning result: RenderResult) {
        guard let continuation = renderContinuation else { return }
        renderContinuation = nil
        tearDownWebView()
        continuation.resume(returning: result)
    }

    private func finishAfterNavigationFailure(_ error: Error) {
        guard !collectedHTMLPages.isEmpty else {
            finish(throwing: error)
            return
        }

        print("[WebKitRenderer] Returning \(collectedHTMLPages.count) page(s) collected before pagination failed")
        finish(returning: RenderResult(
            html: collectedHTMLPages.joined(separator: "\n<!-- FLARE_PAGE_BREAK -->\n"),
            detectedAPICalls: collectedAPICalls
        ))
    }

    private func finish(throwing error: Error) {
        guard let continuation = renderContinuation else {
            tearDownWebView()
            return
        }
        renderContinuation = nil
        tearDownWebView()
        continuation.resume(throwing: error)
    }

    private func tearDownWebView() {
        loadTimeout?.cancel()
        loadTimeout = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeAllUserScripts()
        webView = nil
        initialURL = nil
        currentURL = nil
        visitedURLs = []
        collectedHTMLPages = []
        collectedAPICalls = []
        collectedHTMLCharacters = 0
        isExtracting = false
    }
}
