//
//  MetaLocationService.swift
//  Flare
//
//  Created by Dan on 11/14/25.
//


import Foundation

struct MetaLocationService {
    
    // Full Meta location mapping
    private static let metaLocations: [String: String] = [
        // Major US Cities
        "seattle": "Seattle, WA",
        "bellevue": "Bellevue, WA",
        "redmond": "Redmond, WA",
        "vancouver": "Vancouver, WA",
        "menlo park": "Menlo Park, CA",
        "menlo": "Menlo Park, CA",
        "san francisco": "San Francisco, CA",
        "sf": "San Francisco, CA",
        "new york": "New York, NY",
        "nyc": "New York, NY",
        "ny": "New York, NY",
        "boston": "Boston, MA",
        "austin": "Austin, TX",
        "los angeles": "Los Angeles, CA",
        "la": "Los Angeles, CA",
        "chicago": "Chicago, IL",
        "washington": "Washington, DC",
        "dc": "Washington, DC",
        "sunnyvale": "Sunnyvale, CA",
        "mountain view": "Mountain View, CA",
        "burlingame": "Burlingame, CA",
        "fremont": "Fremont, CA",
        "irvine": "Irvine, CA",
        "san diego": "San Diego, CA",
        "santa clara": "Santa Clara, CA",
        "sausalito": "Sausalito, CA",
        "san mateo": "San Mateo, CA",
        "pasadena": "Pasadena, CA",
        "northridge": "Northridge, CA",
        "foster city": "Foster City, CA",
        "newark": "Newark, CA",
        "miami": "Miami, Florida",
        "pittsburgh": "Pittsburgh, PA",
        "detroit": "Detroit, MI",
        "denver": "Denver, CO",
        "reston": "Reston, VA",
        "ashburn": "Ashburn, VA",
        "houston": "Houston, TX",
        "fort worth": "Fort Worth, TX",
        
        // State abbreviations
        "wa": "Seattle, WA",
        "ca": "San Francisco, CA",
        "tx": "Austin, TX",
        "ma": "Boston, MA",
        "il": "Chicago, IL",
        "co": "Denver, CO",
        "va": "Reston, VA",
        
        // International
        "london": "London, UK",
        "dublin": "Dublin, Ireland",
        "paris": "Paris, France",
        "berlin": "Berlin, Germany",
        "amsterdam": "Amsterdam, Netherlands",
        "toronto": "Toronto, ON",
        "montreal": "Montreal, Canada",
        "vancouver canada": "Vancouver, Canada",
        "singapore": "Singapore",
        "tokyo": "Tokyo, Japan",
        "sydney": "Sydney, Australia",
        "melbourne": "Melbourne, Australia",
        "bangalore": "Bangalore, India",
        "hyderabad": "Hyderabad, India",
        "mumbai": "Mumbai, India",
        "new delhi": "New Delhi, India",
        "delhi": "New Delhi, India",
        "tel aviv": "Tel Aviv, Israel",
        "seoul": "Seoul, South Korea",
        "hong kong": "Hong Kong",
        "shanghai": "Shanghai, China",
        
        // Remote
        "remote": "Remote, US",
        "remote us": "Remote, US",
        "remote usa": "Remote, US",
        "remote canada": "Remote, Canada",
        "remote uk": "Remote, UK"
    ]
    
    static func getMetaOffices(from locationFilter: String) -> [String] {
        guard !locationFilter.isEmpty else { return [] }
        
        var offices: [String] = []
        let keywords = locationFilter
            .lowercased()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        for keyword in keywords {
            // Direct match
            if let office = metaLocations[keyword] {
                if !offices.contains(office) {
                    offices.append(office)
                }
                continue
            }
            
            // Partial match - check if keyword is contained in any key
            for (key, office) in metaLocations {
                if key.contains(keyword) || keyword.contains(key) {
                    if !offices.contains(office) {
                        offices.append(office)
                        break
                    }
                }
            }
        }
        
        return offices
    }
    
    static let allMetaOffices = [
        // US - West
        "Seattle, WA",
        "Bellevue, WA",
        "Redmond, WA",
        "Vancouver, WA",
        "Menlo Park, CA",
        "San Francisco, CA",
        "Burlingame, CA",
        "Fremont, CA",
        "Sunnyvale, CA",
        "Mountain View, CA",
        "Santa Clara, CA",
        "San Mateo, CA",
        "Foster City, CA",
        "Irvine, CA",
        "Los Angeles, CA",
        "San Diego, CA",
        "Sausalito, CA",
        "Pasadena, CA",
        "Northridge, CA",
        "Newark, CA",
        
        // US - Central
        "Austin, TX",
        "Houston, TX",
        "Fort Worth, TX",
        "Chicago, IL",
        "Denver, CO",
        
        // US - East
        "New York, NY",
        "Boston, MA",
        "Washington, DC",
        "Pittsburgh, PA",
        "Miami, Florida",
        "Reston, VA",
        "Ashburn, VA",
        
        // Remote
        "Remote, US",
        "Remote, Canada",
        "Remote, UK"
    ]
}
