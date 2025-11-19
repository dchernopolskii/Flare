//
//  MicrosoftModel.swift
//  MSJobMonitor
//
//  Created by Dan Chernopolskii on 9/28/25.
//


import Foundation

struct MSResponse: Codable {
    let operationResult: OperationResult
}

struct OperationResult: Codable {
    let result: SearchResult
}

struct SearchResult: Codable {
    let jobs: [MSJob]
    let totalJobs: Int?
}

struct MSJob: Codable {
    let jobId: String
    let title: String
    let postingDate: String
    let properties: Properties?
}

struct Properties: Codable {
    let description: String?
    let locations: [String]?
    let primaryLocation: String?
    let workSiteFlexibility: String?
    let profession: String?
    let discipline: String?
    let roleType: String?
    let employmentType: String?
}
