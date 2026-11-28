import Foundation

struct AssetsRelease: Equatable {

    enum Channel: Equatable {
        case experimental
        case stable(version: String)
    }

    let sha: String
    let date: Date
    let message: String
    let reference: String

    private struct CommitResponse: Decodable {

        struct Commit: Decodable {

            struct Committer: Decodable {
                let date: Date
            }

            let committer: Committer
            let message: String
        }

        let sha: String
        let commit: Commit
    }

    private static func failure(
        _ message: String
    ) -> NSError {

        NSError(
            domain: "MacBox.AssetsUpdater",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    static func validSHA(_ sha: String) -> Bool {

        sha.utf8.count == 40 &&
        sha.utf8.allSatisfy {

            ($0 >= 48 && $0 <= 57) ||
            ($0 >= 97 && $0 <= 102)
        }
    }

    static func references(
        for channel: Channel
    ) throws -> [String] {

        switch channel {

        case .experimental:

            return ["main"]

        case .stable(let version):

            let parts = version.split(
                separator: ".",
                omittingEmptySubsequences: false
            )

            guard parts.count == 2 ||
                    parts.count == 3,
                  parts.allSatisfy({

                      !$0.isEmpty &&
                      $0.utf8.allSatisfy {
                          $0 >= 48 && $0 <= 57
                      } &&
                      UInt64($0) != nil

                  }) else {

                throw failure(
                    "Invalid stable 86Box version."
                )
            }

            var candidates = ["v" + version]

            // Accommodate versions reported as 6.0.0
            // when the corresponding tag is v6.0.
            if parts.count == 3 &&
                parts[2] == "0" {

                candidates.append(
                    "v" + parts.prefix(2)
                        .joined(separator: ".")
                )
            }

            return candidates
        }
    }

    static func decode(
        _ data: Data,
        reference: String
    ) throws -> AssetsRelease {

        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(
            CommitResponse.self,
            from: data
        )

        guard validSHA(response.sha) else {

            throw failure(
                "GitHub returned an invalid assets revision."
            )
        }

        return AssetsRelease(
            sha: response.sha,
            date: response.commit.committer.date,
            message: response.commit.message,
            reference: reference
        )
    }

    func archiveURL() throws -> URL {

        guard Self.validSHA(sha),
              let url = URL(
                string:
                    "https://codeload.github.com/" +
                    "86Box/assets/zip/" + sha
              ) else {

            throw Self.failure(
                "Invalid assets download revision."
            )
        }

        return url
    }

    static func fetch(
        channel: Channel,
        session: URLSession = .shared
    ) async throws -> AssetsRelease {

        let candidates = try references(
            for: channel
        )

        for reference in candidates {

            guard let url = URL(
                string:
                    "https://api.github.com/repos/" +
                    "86Box/assets/commits/" + reference
            ) else {

                throw failure(
                    "Invalid assets metadata URL."
                )
            }

            var request = URLRequest(url: url)

            request.timeoutInterval = 30
            request.cachePolicy =
                .reloadIgnoringLocalCacheData

            request.setValue(
                "application/vnd.github+json",
                forHTTPHeaderField: "Accept"
            )

            request.setValue(
                "MacBox",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) =
                try await session.data(for: request)

            guard let http =
                    response as? HTTPURLResponse else {

                throw failure(
                    "Invalid assets metadata response."
                )
            }

            // A missing stable tag may have an equivalent
            // version spelling, such as v6.0 instead of v6.0.0.
            if http.statusCode == 404 {

                if case .stable = channel {
                    continue
                }
            }

            guard http.statusCode == 200 else {

                throw failure(
                    "Assets update check failed " +
                    "(HTTP \(http.statusCode))."
                )
            }

            return try decode(
                data,
                reference: reference
            )
        }

        throw failure(
            "No matching asset revision exists " +
            "for this stable 86Box version."
        )
    }
}
