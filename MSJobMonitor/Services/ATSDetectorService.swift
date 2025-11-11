//
//  ATSDetectorService.swift
//  MSJobMonitor
//

import Foundation

actor ATSDetectorService {
    static let shared = ATSDetectorService()
    
    struct DetectionResult {
        let source: JobSource?
        let confidence: Confidence
        let apiEndpoint: String?
        let actualATSUrl: String?
        let message: String
        
        enum Confidence {
            case certain
            case likely
            case uncertain
            case notDetected
        }
    }
    
    func detectATS(from url: URL) async throws -> DetectionResult {
        print("[ATS Detector] Starting detection for: \(url.absoluteString)")
        
        if let quickMatch = JobSource.detectFromURL(url.absoluteString) {
            print("[ATS Detector] Quick match found: \(quickMatch.rawValue)")
            return DetectionResult(
                source: quickMatch,
                confidence: .certain,
                apiEndpoint: nil,
                actualATSUrl: url.absoluteString,
                message: "Detected \(quickMatch.rawValue) from URL pattern"
            )
        }
        
        print("[ATS Detector] No quick match, fetching page content...")
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            print("[ATS Detector] Failed to decode HTML")
            throw FetchError.invalidResponse
        }
        
        print("[ATS Detector] Fetched HTML, length: \(html.count) characters")
        
        let isCareersPage = isLikelyCareersPage(url: url, html: html)
        let indicators = analyzeATSIndicators(in: html)
        print("[ATS Detector] Found indicators: \(indicators)")
        print("[ATS Detector] Probing ATS APIs...")
        if let probeResult = await probeATSystems(indicators: indicators, originalURL: url, isCareersPage: isCareersPage) {
            print("[ATS Detector] Found via API probe: \(probeResult.source?.rawValue ?? "unknown")")
            return probeResult
        }
        
        print("[ATS Detector] Searching for embedded ATS URLs...")
        if let embeddedResult = await findEmbeddedATSUrls(in: html, originalURL: url) {
            print("[ATS Detector] Found via embedded URLs: \(embeddedResult.source?.rawValue ?? "unknown")")
            return embeddedResult
        }
        
        print("[ATS Detector] Searching in JSON/script data...")
        if let jsonResult = findATSUrlsInJSON(in: html, originalURL: url) {
            print("[ATS Detector] Found via JSON: \(jsonResult.source?.rawValue ?? "unknown")")
            return jsonResult
        }
        
        print("[ATS Detector] Searching for API patterns...")
        if let apiResult = findJobAPIPatterns(in: html, originalURL: url) {
            print("[ATS Detector] Found API pattern but couldn't determine ATS")
            return apiResult
        }
        
        print("[ATS Detector] No ATS detected")
        
        return DetectionResult(
            source: nil,
            confidence: .notDetected,
            apiEndpoint: nil,
            actualATSUrl: nil,
            message: "Could not detect ATS system from this page"
        )
    }
    
    // MARK: - Careers Page Detection
    
    private func isLikelyCareersPage(url: URL, html: String) -> Bool {
        let urlString = url.absoluteString.lowercased()
        let urlIndicators = ["career", "job", "hiring", "join", "positions"]
        let hasCareerUrl = urlIndicators.contains { urlString.contains($0) }
        let htmlLower = html.lowercased()
        let contentIndicators = [
            "open position", "job opening", "join our team", "we're hiring",
            "apply now", "view all jobs", "current opening"
        ]
        let hasCareerContent = contentIndicators.contains { htmlLower.contains($0) }
        
        return hasCareerUrl || hasCareerContent
    }
    
    // MARK: - ATS Indicator Analysis
    
    private struct ATSIndicators {
        var greenhouse: Int = 0
        var lever: Int = 0
        var ashby: Int = 0
        var workday: Int = 0
        
        var isEmpty: Bool {
            greenhouse == 0 && lever == 0 && ashby == 0 && workday == 0
        }
        
        var strongest: (source: String, count: Int)? {
            let all = [
                ("greenhouse", greenhouse),
                ("lever", lever),
                ("ashby", ashby),
                ("workday", workday)
            ]
            return all.max(by: { $0.1 < $1.1 })
        }
    }
    
    private func analyzeATSIndicators(in html: String) -> ATSIndicators {
        let htmlLower = html.lowercased()
        var indicators = ATSIndicators()
        let greenhouseKeywords = ["greenhouse.io", "boards.greenhouse", "grnhse", "gh-", "data-gh"]
        for keyword in greenhouseKeywords {
            if htmlLower.contains(keyword) {
                indicators.greenhouse += 1
            }
        }
        
        let leverKeywords = [
            "lever.co",              // ATS domain
            "jobs.lever",            // Job board
            "api.lever",             // API endpoint
            "data-lever",            // HTML attribute
            "lever-application",     // Common class name
            "lever ats",             // Explicit mention
            "levercareers"           // Combined word
        ]
        for keyword in leverKeywords {
            if htmlLower.contains(keyword) {
                indicators.lever += 1
            }
        }
        
        let ashbyKeywords = ["ashbyhq", "jobs.ashbyhq", "ashby.com"]
        for keyword in ashbyKeywords {
            if htmlLower.contains(keyword) {
                indicators.ashby += 1
            }
        }
        
        let workdayKeywords = ["myworkdayjobs", "wd1.", "wd5.", "workday.com/careers"]
        for keyword in workdayKeywords {
            if htmlLower.contains(keyword) {
                indicators.workday += 1
            }
        }
        
        return indicators
    }
    
    // MARK: - ATS Probing
    
    private func probeATSystems(indicators: ATSIndicators, originalURL: URL, isCareersPage: Bool) async -> DetectionResult? {
        let companySlug = extractCompanySlug(from: originalURL)
        
        if !indicators.isEmpty {
            print("[Probe] Probing based on indicators...")
            
            let probes: [(count: Int, probe: () async -> DetectionResult?)] = [
                (indicators.greenhouse, { await self.probeGreenhouse(companySlug: companySlug) }),
                (indicators.lever, { await self.probeLever(companySlug: companySlug) }),
                (indicators.ashby, { await self.probeAshby(companySlug: companySlug) }),
            ]
            
            for (count, probe) in probes.sorted(by: { $0.count > $1.count }) where count > 0 {
                if let result = await probe() {
                    return result
                }
            }
        }
        
        if isCareersPage && indicators.isEmpty {
            print("[Probe] No indicators found, but looks like careers page. Trying fallback probes...")
            
            // Try in order of popularity
            if let result = await probeGreenhouse(companySlug: companySlug) {
                return result
            }
            
            if let result = await probeLever(companySlug: companySlug) {
                return result
            }
            
            if let result = await probeAshby(companySlug: companySlug) {
                return result
            }
            
            print("[Probe] Fallback probes failed")
        }
        
        return nil
    }
    
    // MARK: - Greenhouse Probing
    
    private func probeGreenhouse(companySlug: String) async -> DetectionResult? {
        let apiUrl = "https://boards-api.greenhouse.io/v1/boards/\(companySlug)/jobs?content=true"
        
        print("[Greenhouse Probe] Testing: \(apiUrl)")
        
        guard let result = try? await fetchGreenhouseAPIDetails(apiUrl: apiUrl) else {
            print("[Greenhouse Probe] Failed")
            return nil
        }
        
        print("[Greenhouse Probe] Success!")
        return result
    }
    
    private func fetchGreenhouseAPIDetails(apiUrl: String) async throws -> DetectionResult {
        guard let url = URL(string: apiUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw FetchError.invalidResponse
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = json["jobs"] as? [[String: Any]],
              !jobs.isEmpty,
              let firstJob = jobs.first,
              let absoluteUrl = firstJob["absolute_url"] as? String else {
            throw FetchError.invalidResponse
        }
        
        let baseUrl = extractGreenhouseBaseUrl(from: absoluteUrl)
        
        return DetectionResult(
            source: .greenhouse,
            confidence: .certain,
            apiEndpoint: apiUrl,
            actualATSUrl: baseUrl,
            message: "Found Greenhouse via API: \(baseUrl)"
        )
    }
    
    private func extractGreenhouseBaseUrl(from jobUrl: String) -> String {
        if let url = URL(string: jobUrl) {
            var pathComponents = url.pathComponents.filter { $0 != "/" }
            
            if let lastComponent = pathComponents.last, Int(lastComponent) != nil {
                pathComponents.removeLast()
            }
            
            if pathComponents.last == "jobs" {
                pathComponents.removeLast()
            }
            
            let basePath = "/" + pathComponents.joined(separator: "/")
            return "\(url.scheme ?? "https")://\(url.host ?? "")\(basePath)"
        }
        return jobUrl
    }
    
    // MARK: - Lever Probing
    
    private func probeLever(companySlug: String) async -> DetectionResult? {
        let apiUrl = "https://api.lever.co/v0/postings/\(companySlug)?mode=json"
        
        print("[Lever Probe] Testing: \(apiUrl)")
        
        guard let result = try? await fetchLeverAPIDetails(apiUrl: apiUrl, companySlug: companySlug) else {
            print("[Lever Probe] Failed")
            return nil
        }
        
        print("[Lever Probe] Success!")
        return result
    }
    
    private func fetchLeverAPIDetails(apiUrl: String, companySlug: String) async throws -> DetectionResult {
        guard let url = URL(string: apiUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode) else {
            throw FetchError.invalidResponse
        }
        
        guard let jobs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !jobs.isEmpty else {
            throw FetchError.invalidResponse
        }
        
        let baseUrl = "https://jobs.lever.co/\(companySlug)"
        
        return DetectionResult(
            source: .lever,
            confidence: .certain,
            apiEndpoint: apiUrl,
            actualATSUrl: baseUrl,
            message: "Found Lever via API: \(baseUrl)"
        )
    }
    
    // MARK: - Ashby Probing
    
    private func probeAshby(companySlug: String) async -> DetectionResult? {
        let baseUrl = "https://jobs.ashbyhq.com/\(companySlug)/"
        
        print("[Ashby Probe] Testing: \(baseUrl)")
        
        guard let result = try? await fetchAshbyJobBoard(baseUrl: baseUrl) else {
            print("[Ashby Probe] Failed")
            return nil
        }
        
        print("[Ashby Probe] Success!")
        return result
    }
    
    private func fetchAshbyJobBoard(baseUrl: String) async throws -> DetectionResult {
        guard let url = URL(string: baseUrl) else {
            throw FetchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        
        let (data, httpResponse) = try await URLSession.shared.data(for: request)
        
        guard let response = httpResponse as? HTTPURLResponse,
              (200...299).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8),
              html.contains("ashbyhq") || html.contains("Ashby") else {
            throw FetchError.invalidResponse
        }
        
        return DetectionResult(
            source: .ashby,
            confidence: .certain,
            apiEndpoint: nil,
            actualATSUrl: baseUrl,
            message: "Found Ashby job board: \(baseUrl)"
        )
    }
    
    // MARK: - Helper Methods
    
    private func extractCompanySlug(from url: URL) -> String {
        if let host = url.host {
            let parts = host.components(separatedBy: ".")
            if parts.count >= 2 {
                let domain = parts[parts.count - 2]
                return domain.lowercased()
            }
        }
        return "company"
    }
    
    private func normalizeAshbyUrl(_ url: String) -> String {
        guard let urlObj = URL(string: url) else { return url }
        
        let pathComponents = urlObj.pathComponents.filter { $0 != "/" }
        
        if pathComponents.count > 1 {
            let lastComponent = pathComponents.last ?? ""
            
            let uuidPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#
            if let regex = try? NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive),
               regex.firstMatch(in: lastComponent, range: NSRange(lastComponent.startIndex..., in: lastComponent)) != nil {
                
                let baseComponents = pathComponents.dropLast()
                let basePath = "/" + baseComponents.joined(separator: "/") + "/"
                return "\(urlObj.scheme ?? "https")://\(urlObj.host ?? "")\(basePath)"
            }
        }
        
        return url
    }
    
    // MARK: - Embedded URLs Detection
    
    private func findEmbeddedATSUrls(in html: String, originalURL: URL) async -> DetectionResult? {
        print("[Embedded Search] Searching for embedded ATS URLs...")
        
        let atsUrlPatterns: [(pattern: String, source: JobSource)] = [
            (#"https?://[^"'\s]*\.wd[0-9]+\.myworkdayjobs\.com/[^"'\s]*"#, .workday),
            (#"https?://[^"'\s]*\.myworkdayjobs\.com/[^"'\s]*"#, .workday),
            (#"https?://[^"'\s]*\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://boards-api\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://job-boards\.greenhouse\.io/[^"'\s]*"#, .greenhouse),
            (#"https?://jobs\.lever\.co/[^"'\s]*"#, .lever),
            (#"https?://[^"'\s]*\.lever\.co[^"'\s]*"#, .lever),
            (#"https?://jobs\.ashbyhq\.com/[^"'\s]*"#, .ashby),
            (#"https?://[^"'\s]*\.workable\.com/[^"'\s]*"#, .workable),
            (#"https?://[^"'\s]*\.smartrecruiters\.com/[^"'\s]*"#, .smartrecruiters),
            (#"https?://[^"'\s]*\.jobvite\.com/[^"'\s]*"#, .jobvite),
        ]
        
        for (index, (pattern, source)) in atsUrlPatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range, in: html) {
                
                var foundUrl = String(html[range])
                foundUrl = foundUrl.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                
                print("[Embedded Search] Found \(source.rawValue) URL: \(foundUrl)")
                
                if source == .workday {
                    if let workdayConfig = parseWorkdayUrl(foundUrl) {
                        let normalizedUrl = normalizeWorkdayUrl(foundUrl)
                        return DetectionResult(
                            source: .workday,
                            confidence: .certain,
                            apiEndpoint: nil,
                            actualATSUrl: normalizedUrl,
                            message: "✅ Found Workday ATS: \(workdayConfig.company).\(workdayConfig.instance).myworkdayjobs.com/\(workdayConfig.siteName)"
                        )
                    }
                }
                
                var normalizedUrl = foundUrl
                if source == .ashby {
                    normalizedUrl = normalizeAshbyUrl(foundUrl)
                } else if source == .workday {
                    normalizedUrl = normalizeWorkdayUrl(foundUrl)
                }
                
                return DetectionResult(
                    source: source,
                    confidence: .certain,
                    apiEndpoint: nil,
                    actualATSUrl: normalizedUrl,
                    message: "Found \(source.rawValue) ATS embedded in page: \(normalizedUrl)"
                )
            }
        }
        
        if let redirectUrl = findMetaRedirect(in: html) {
            if let source = JobSource.detectFromURL(redirectUrl) {
                return DetectionResult(
                    source: source,
                    confidence: .likely,
                    apiEndpoint: nil,
                    actualATSUrl: redirectUrl,
                    message: "Found redirect to \(source.rawValue): \(redirectUrl)"
                )
            }
        }
        
        if let jsRedirect = findJavaScriptRedirect(in: html) {
            if let source = JobSource.detectFromURL(jsRedirect) {
                return DetectionResult(
                    source: source,
                    confidence: .likely,
                    apiEndpoint: nil,
                    actualATSUrl: jsRedirect,
                    message: "Found JS redirect to \(source.rawValue)"
                )
            }
        }
        
        return nil
    }
    
    private func normalizeWorkdayUrl(_ url: String) -> String {
        guard let urlObj = URL(string: url),
              let host = urlObj.host else { return url }
        
        let path = urlObj.path
        let stripPatterns = ["/job/", "/details/", "/apply"]
        var basePath = path
        
        for pattern in stripPatterns {
            if let range = path.range(of: pattern) {
                basePath = String(path[..<range.lowerBound])
                break
            }
        }
        
        if !basePath.hasSuffix("/") {
            basePath += "/"
        }
        
        return "\(urlObj.scheme ?? "https")://\(host)\(basePath)"
    }
    
    private func parseWorkdayUrl(_ url: String) -> (company: String, instance: String, siteName: String)? {
        guard let urlComponents = URL(string: url),
              let host = urlComponents.host else { return nil }
        
        let hostParts = host.components(separatedBy: ".")
        guard hostParts.count >= 3,
              hostParts[1].hasPrefix("wd"),
              hostParts[2] == "myworkdayjobs" else { return nil }
        
        let company = hostParts[0]
        let instance = hostParts[1]
        
        let normalizedUrl = normalizeWorkdayUrl(url)
        guard let normalizedComponents = URL(string: normalizedUrl) else {
            return (company: company, instance: instance, siteName: "careers")
        }
        
        var siteName = normalizedComponents.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        if siteName.isEmpty {
            siteName = "careers"
        }
        
        return (company: company, instance: instance, siteName: siteName)
    }
    
    private func findMetaRedirect(in html: String) -> String? {
        let pattern = #"<meta[^>]*http-equiv=[\"']refresh[\"'][^>]*content=[\"'][^\"']*url=([^\"'\s]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: html) {
            return String(html[range])
        }
        return nil
    }
    
    private func findJavaScriptRedirect(in html: String) -> String? {
        let patterns = [
            #"window\.location\.href\s*=\s*[\"']([^\"']+)[\"']"#,
            #"window\.location\.replace\([\"']([^\"']+)[\"']\)"#,
            #"location\.href\s*=\s*[\"']([^\"']+)[\"']"#
        ]
        
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                return String(html[range])
            }
        }
        return nil
    }
    
    private func findATSUrlsInJSON(in html: String, originalURL: URL) -> DetectionResult? {
        let jsonPatterns = [
            #"["\']?(https?://(?:boards?-?api)?\.greenhouse\.io/[^"'\s]+)["\']?"#,
            #"["\']?(https?://jobs\.lever\.co/[^"'\s]+)["\']?"#,
            #"["\']?(https?://jobs\.ashbyhq\.com/[^"'\s]+)["\']?"#,
            #"["\']?(https?://[^"'\s]*\.myworkdayjobs\.com/[^"'\s]+)["\']?"#,
        ]
        
        for (index, pattern) in jsonPatterns.enumerated() {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: html) {
                
                let foundUrl = String(html[range])
                
                if let source = JobSource.detectFromURL(foundUrl) {
                    var normalizedUrl = foundUrl
                    if source == .ashby {
                        normalizedUrl = normalizeAshbyUrl(foundUrl)
                    } else if source == .workday {
                        normalizedUrl = normalizeWorkdayUrl(foundUrl)
                    }
                    
                    return DetectionResult(
                        source: source,
                        confidence: .certain,
                        apiEndpoint: nil,
                        actualATSUrl: normalizedUrl,
                        message: "Found \(source.rawValue) ATS URL in page data: \(normalizedUrl)"
                    )
                }
            }
        }
        
        return nil
    }
    
    private func findJobAPIPatterns(in html: String, originalURL: URL) -> DetectionResult? {
        let dynamicLoadingIndicators = [
            "graphql", "apollo", "__APOLLO", "careersPageQuery", "jobsQuery",
            "window.__INITIAL_STATE__", "window.__data", "react-root", "ng-app", "vue-app"
        ]
        
        var foundIndicators: [String] = []
        for indicator in dynamicLoadingIndicators {
            if html.localizedCaseInsensitiveContains(indicator) {
                foundIndicators.append(indicator)
            }
        }
        
        if foundIndicators.count >= 2 {
            var suggestionMessage = "This page loads jobs dynamically via JavaScript. "
            
            if html.contains("greenhouse") || html.contains("gh-") {
                suggestionMessage += "It appears to use Greenhouse. Try: https://boards.greenhouse.io/\(extractCompanySlug(from: originalURL))"
            } else if html.contains("lever") {
                suggestionMessage += "It appears to use Lever. Try: https://jobs.lever.co/\(extractCompanySlug(from: originalURL))"
            } else if html.contains("ashby") {
                suggestionMessage += "It appears to use Ashby. Try: https://jobs.ashbyhq.com/\(extractCompanySlug(from: originalURL))"
            } else {
                suggestionMessage += "Try finding a direct link to a specific job posting from this page."
            }
            
            return DetectionResult(
                source: nil,
                confidence: .uncertain,
                apiEndpoint: nil,
                actualATSUrl: nil,
                message: suggestionMessage
            )
        }
        
        return nil
    }
}
