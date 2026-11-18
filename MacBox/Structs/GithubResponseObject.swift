//
//  GithubResponseObject.swift
//  MacBox
//
//  Created by Moonif on 1/8/24.
//

struct GithubResponseObject: Decodable {
    let url: String?
    let html_url: String?
    let tag_name: String?
    let body: String?
    let published_at: String?
    let sha: String?
    let assets: [GithubAsset]?
    let commit: GithubCommit?
}

struct GithubAsset: Decodable {

    let url: String?
    let browser_download_url: String?

    // GitHub release asset metadata.
    let name: String?
    let digest: String?

    // Preserve compatibility with existing Jenkins asset creation.
    init(
        url: String?,
        browser_download_url: String?,
        name: String? = nil,
        digest: String? = nil
    ) {
        self.url = url
        self.browser_download_url = browser_download_url
        self.name = name
        self.digest = digest
    }
}

struct GithubCommit: Decodable {
    let author: GithubCommitAuthor?
}

struct GithubCommitAuthor: Decodable {
    let name: String?
    let date: String?
}
