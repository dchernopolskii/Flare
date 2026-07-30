//
//  LocationService.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 10/1/25.
//


import Foundation

struct ParsedLocation {
    let raw: String
    let city: String
    let state: String
    let country: String
    let isRemote: Bool
    let isMultiple: Bool
    
    init(from raw: String) {
        self.raw = raw
        let lower = raw.lowercased()
        self.isRemote = lower.contains("remote")
        
        let parts = raw
            .replacingOccurrences(of: ";", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        
        if parts.count >= 3 {
            self.city = parts[0]
            self.state = parts[parts.count - 2]
            self.country = parts.last ?? ""
            self.isMultiple = raw.localizedCaseInsensitiveContains("multiple locations")
        } else if parts.count == 2 {
            self.city = parts[0]
            self.state = ""
            self.country = parts[1]
            self.isMultiple = false
        } else {
            self.city = ""
            self.state = ""
            self.country = raw
            self.isMultiple = false
        }
    }
    
    var displayString: String {
        if isMultiple { return "Multiple Locations, \(country)" }
        if !city.isEmpty && !state.isEmpty { return "\(city), \(state)" }
        if !state.isEmpty { return state }
        return country
    }
}

struct LocationService {
    static func extractTargetCountries(from filter: String) -> Set<String> {
        guard !filter.isEmpty else { return ["United States", "Canada"] }
        
        let filterLower = filter.lowercased()
        var countries = Set<String>()
        
        let countryMappings: [String: String] = [
            "usa": "United States",
            "us": "United States",
            "united states": "United States",
            "washington state": "United States",
            "wa": "United States",
            "california": "United States",
            "ca": "United States",
            "new york state": "United States",
            "ny": "United States",
            "massachusetts": "United States",
            "ma": "United States",
            "texas": "United States",
            "tx": "United States",
            "illinois": "United States",
            "il": "United States",
            "georgia": "United States",
            "ga": "United States",
            "colorado": "United States",
            "co": "United States",
            "oregon": "United States",
            "or": "United States",
            "florida": "United States",
            "fl": "United States",
            "virginia": "United States",
            "va": "United States",
            "north carolina": "United States",
            "nc": "United States",
            "new jersey": "United States",
            "nj": "United States",
            "pennsylvania": "United States",
            "pa": "United States",
            "michigan": "United States",
            "mi": "United States",
            "minnesota": "United States",
            "mn": "United States",
            "ohio": "United States",
            "oh": "United States",
            "arizona": "United States",
            "az": "United States",
            "utah": "United States",
            "ut": "United States",
            "nevada": "United States",
            "nv": "United States",
            "seattle": "United States",
            "redmond": "United States",
            "bellevue": "United States",
            "san francisco": "United States",
            "sf": "United States",
            "bay area": "United States",
            "mountain view": "United States",
            "sunnyvale": "United States",
            "san jose": "United States",
            "los angeles": "United States",
            "la": "United States",
            "boston": "United States",
            "austin": "United States",
            "chicago": "United States",
            "atlanta": "United States",
            "denver": "United States",
            "portland": "United States",
            "miami": "United States",
            "houston": "United States",
            "dallas": "United States",
            "dc": "United States",
            "washington dc": "United States",

            // Canada
            "canada": "Canada",
            "toronto": "Canada",
            "vancouver": "Canada",
            "montreal": "Canada",
            "ottawa": "Canada",
            "calgary": "Canada",
            "edmonton": "Canada",
            "winnipeg": "Canada",
            "quebec": "Canada",

            // United Kingdom
            "uk": "United Kingdom",
            "united kingdom": "United Kingdom",
            "england": "United Kingdom",
            "scotland": "United Kingdom",
            "wales": "United Kingdom",
            "northern ireland": "United Kingdom",
            "london": "United Kingdom",
            "manchester": "United Kingdom",
            "edinburgh": "United Kingdom",
            "glasgow": "United Kingdom",
            "birmingham": "United Kingdom",
            "bristol": "United Kingdom",
            "cambridge": "United Kingdom",
            "oxford": "United Kingdom",

            // Ireland
            "ireland": "Ireland",
            "dublin": "Ireland",
            "cork": "Ireland",
            "galway": "Ireland",

            // Australia
            "australia": "Australia",
            "sydney": "Australia",
            "melbourne": "Australia",
            "brisbane": "Australia",
            "perth": "Australia",
            "adelaide": "Australia",

            // India
            "india": "India",
            "bangalore": "India",
            "bengaluru": "India",
            "hyderabad": "India",
            "pune": "India",
            "delhi": "India",
            "new delhi": "India",
            "mumbai": "India",
            "gurgaon": "India",
            "noida": "India",
            "chennai": "India",

            // Germany
            "germany": "Germany",
            "berlin": "Germany",
            "munich": "Germany",
            "frankfurt": "Germany",
            "hamburg": "Germany",
            "stuttgart": "Germany",

            // France
            "france": "France",
            "paris": "France",
            "lyon": "France",
            "toulouse": "France",

            // Others
            "netherlands": "Netherlands",
            "amsterdam": "Netherlands",
            "rotterdam": "Netherlands",
            "hague": "Netherlands",

            "sweden": "Sweden",
            "stockholm": "Sweden",
            "gothenburg": "Sweden",

            "switzerland": "Switzerland",
            "zurich": "Switzerland",
            "geneva": "Switzerland",

            "spain": "Spain",
            "madrid": "Spain",
            "barcelona": "Spain",

            "italy": "Italy",
            "milan": "Italy",
            "rome": "Italy",

            "singapore": "Singapore",
            "hong kong": "Hong Kong",
            "china": "China",
            "shanghai": "China",
            "beijing": "China",
            "shenzhen": "China",

            "japan": "Japan",
            "tokyo": "Japan",
            "osaka": "Japan",
            "kyoto": "Japan"
        ]
        
        for (keyword, country) in countryMappings {
            if filterLower.contains(keyword) {
                countries.insert(country)
            }
        }
        
        if countries.isEmpty {
            countries.insert("United States")
        }
        
        return countries
    }
}

enum LocationMatcher {
    private static let remoteTerms = ["remote", "work from home", "distributed", "anywhere"]

    // These are deliberately metro/state aliases, not country aliases. A Seattle
    // preference should find a board that only says "Washington, USA", but it
    // should not turn into a match for every job in the United States.
    private static let aliases: [String: [String]] = [
        "seattle": ["seattle", "greater seattle", "greater seattle area", "seattle metropolitan area", "puget sound", "king county", "washington", "wa"],
        "redmond": ["redmond", "greater seattle", "puget sound", "king county", "washington", "wa"],
        "bellevue": ["bellevue", "greater seattle", "puget sound", "king county", "washington", "wa"],
        "washington": ["washington", "wa", "seattle", "redmond", "bellevue", "everett", "tacoma", "puget sound"],
        "wa": ["washington", "wa", "seattle", "redmond", "bellevue", "everett", "tacoma", "puget sound"],
        "san francisco": ["san francisco", "sf", "bay area", "silicon valley", "california", "ca"],
        "sf": ["san francisco", "sf", "bay area", "silicon valley", "california", "ca"],
        "new york": ["new york", "nyc", "new york city", "new york state", "ny"],
        "nyc": ["new york", "nyc", "new york city", "new york state", "ny"],
        "portland": ["portland", "oregon", "or"]
    ]

    static func matches(_ job: Job, locationKeywords: [String]) -> Bool {
        let keywords = locationKeywords.map(normalize).filter { !$0.isEmpty }
        guard !keywords.isEmpty else { return true }

        let values = [job.location, job.workSiteFlexibility ?? ""]
            .map(normalize)
            .filter { !$0.isEmpty }

        return keywords.contains { keyword in
            if isRemoteKeyword(keyword) {
                return values.contains { value in remoteTerms.contains { value.contains($0) } }
            }

            let candidates = aliases[keyword] ?? [keyword]
            return candidates.contains { candidate in
                values.contains { containsLocationTerm($0, term: candidate) }
            }
        }
    }

    static func physicalKeywords(from locationFilter: String) -> [String] {
        locationFilter.parseAsFilterKeywords().filter { !isRemoteKeyword(normalize($0)) }
    }

    static func includesRemote(_ locationFilter: String) -> Bool {
        locationFilter.parseAsFilterKeywords().contains { isRemoteKeyword(normalize($0)) }
    }

    private static func isRemoteKeyword(_ keyword: String) -> Bool {
        remoteTerms.contains { keyword.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "/" })
            .joined(separator: " ")
    }

    private static func containsLocationTerm(_ value: String, term: String) -> Bool {
        guard term.count > 2 else {
            return value.split(separator: " ").contains { String($0) == term }
        }
        return value.contains(term)
    }
}

extension LocationService {
    
    // MARK: - Microsoft API Mapping
    static func getMicrosoftLocationParams(_ locationString: String) -> [String] {
        guard !locationString.isEmpty else { return [] }
        
        // Parse individual locations from comma-separated string
        let locations = locationString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        return locations.map { location in
            let capitalized = location.split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
            
            return capitalized
        }
    }
    
    // MARK: - TikTok API Mapping
    static func getTikTokLocationCodes(_ locationString: String) -> [String] {
        let locations = parseLocations(from: locationString)
        var codes: [String] = []
        
        for location in locations {
            if let code = cityCodeMap[location.lowercased()] {
                codes.append(code)
            } else if let stateCode = getStateCodes(for: location) {
                codes.append(contentsOf: stateCode)
            }
        }
        
        return codes
    }

    private static func parseLocations(from locationString: String) -> [String] {
        return locationString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("remote") }
    }
    
    private static func getStateCodes(for location: String) -> [String]? {
        let lower = location.lowercased()
        
        switch lower {
        case "washington", "wa":
            return ["CT_157"] // Seattle
        case "california", "ca":
            return ["CT_75", "CT_94", "CT_243", "CT_1103355"] // SF, LA, Mountain View, San Jose
        case "new york", "ny":
            return ["CT_114"] // New York
        case "texas", "tx":
            return ["CT_247"] // Austin
        default:
            return nil
        }
    }
    
    // MARK: - Static Mappings
    private static let countryMap: [String: String] = [
        "usa": "United States",
        "us": "United States",
        "united states": "United States",
        "canada": "Canada",
        "uk": "United Kingdom",
        "united kingdom": "United Kingdom",
        "germany": "Germany",
        "france": "France",
        "india": "India",
        "australia": "Australia",
        "ireland": "Ireland",
        "netherlands": "Netherlands",
        "singapore": "Singapore"
    ]
    
    private static let locationToCountryMap: [String: String] = [
        "seattle": "United States",
        "san francisco": "United States",
        "sf": "United States",
        "new york city": "United States",
        "nyc": "United States",
        "los angeles": "United States",
        "la": "United States",
        "austin": "United States",
        "chicago": "United States",
        "boston": "United States",
        "washington dc": "United States",
        "dc": "United States",
        "california": "United States",
        "washington state": "United States",
        "texas": "United States",
        "new york state": "United States",
        "london": "United Kingdom",
        "dublin": "Ireland",
        "paris": "France",
        "berlin": "Germany",
        "bangalore": "India",
        "sydney": "Australia",
        "amsterdam": "Netherlands",
        "singapore": "Singapore"
    ]
    
    // TikTok City Code Mapping (from API response)
    private static let cityCodeMap: [String: String] = [
        "seattle": "CT_157",
        "san francisco": "CT_75",
        "new york": "CT_114",
        "los angeles": "CT_94",
        "austin": "CT_247",
        "chicago": "CT_221",
        "mountain view": "CT_243",
        "san jose": "CT_1103355",
        "washington d.c.": "CT_233",
        "dc": "CT_233",
        "boston": "CT_114",
        "london": "CT_93",
        "dublin": "CT_37",
        "paris": "CT_5",
        "berlin": "CT_6",
        "amsterdam": "CT_100766",
        "singapore": "CT_163",
        "tokyo": "CT_34",
        "sydney": "CT_244",
        "bangalore": "CT_44",
        "gurgaon": "CT_44",
        "stockholm": "CT_1102285",
        "copenhagen": "CT_101458",
        "munich": "CT_226",
        "madrid": "CT_96",
        "milan": "CT_204",
        "brussels": "CT_235",
        "warsaw": "CT_209",
        "istanbul": "CT_206",
        "dubai": "CT_33",
        "tel aviv": "CT_249",
        "jakarta": "CT_169",
        "bangkok": "CT_98",
        "kuala lumpur": "CT_65",
        "seoul": "CT_134",
        "ho chi minh city": "CT_60"
    ]
}
