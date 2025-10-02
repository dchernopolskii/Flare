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
            // US, thanks claude
            "usa": "United States",
            "us": "United States",
            "united states": "United States",
            "washington": "United States",
            "wa": "United States",
            "california": "United States",
            "ca": "United States",
            "new york": "United States",
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
