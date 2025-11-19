//
//  FetchError.swift
//  MSJobMonitor
//
//  Created by Dan on 11/10/25.
//


import Foundation

enum FetchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case decodingError(details: String)
    case httpError(statusCode: Int)
    case noJobs
    case atsNotDetected
    case missingRequiredField(field: String, jobIndex: Int, source: String)
    case notImplemented(String)
    case networkError(Error)
    case apiError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .decodingError(let details):
            return "Parsing error: \(details)"
        case .httpError(let statusCode):
            return "HTTP error \(statusCode): \(httpStatusMessage(statusCode))"
        case .noJobs:
            return "No jobs found"
        case .atsNotDetected:
            return "Could not detect ATS system"
        case .missingRequiredField(let field, let jobIndex, let source):
            return "[\(source)] Missing '\(field)' at job #\(jobIndex)"
        case .notImplemented(let source):
            return "\(source) not implemented"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API Error: \(message)"
        }
    }
    
    private func httpStatusMessage(_ code: Int) -> String {
        switch code {
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Unknown Error"
        }
    }
}
