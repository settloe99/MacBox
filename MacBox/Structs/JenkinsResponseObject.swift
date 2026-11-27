//
//  JenkinsResponseObject.swift
//  MacBox
//
//  Created by Moonif on 1/17/24.
//

import Cocoa

struct JenkinsResponseObject: Decodable {
    let id: String?
    let number: Int?
    let timestamp: Double?
    let url: String?
    let artifacts: [JenkinsArtifact]?
    let changeSets: [JenkinsChangeSets]?
}

struct JenkinsArtifact: Decodable {
    let fileName: String?
    let relativePath: String?
}

struct JenkinsChangeSets: Decodable {
    let items: [JenkinsChangeSetItem]?
}

struct JenkinsChangeSetItem: Decodable {
    let msg: String?
    let comment: String?
}

extension JenkinsResponseObject {
    func toGithubResponseObject() -> GithubResponseObject {
        // Convert timestamp to date
        let dateVal = TimeInterval(timestamp ?? 0) / 1000.0
        let date = Date(timeIntervalSince1970: dateVal)
        let formattedDate = date.getFormattedDate(format: "yyyy-MM-dd'T'HH:mm:ssZ")
        
        // Convert artifacts to assets
        var assets = [GithubAsset]()
        for artifact in artifacts ?? [] {
            let asset = GithubAsset(url: artifact.fileName, browser_download_url: artifact.relativePath)
            assets.append(asset)
        }
        
        // Use the first available change description.
        // Jenkins may populate either comment or msg.
        let releaseNotes = changeSets?
            .flatMap { $0.items ?? [] }
            .compactMap { item -> String? in
                let comment = item.comment?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let comment = comment, !comment.isEmpty {
                    return comment
                }

                let msg = item.msg?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                return (msg?.isEmpty == false) ? msg : nil
            }
            .first

        let githubObject = GithubResponseObject(
            url: url,
            html_url: nil,
            tag_name: id,
            body: releaseNotes,
            published_at: formattedDate,
            sha: nil,
            assets: assets,
            commit: nil
        )
        
        return githubObject
    }
}
