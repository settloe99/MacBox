//
//  VersionInfoObject.swift
//  MacBox
//
//  Created by Moonif on 1/22/24.
//

import Cocoa

struct VersionInfoObject {
    // 86Box emulator info
    var emulatorUpdateChannel: String?
    var emulatorAutoUrl: URL?
    var emulatorCustomUrl: URL?
    // 86Box ROMs info
    var romsUrls: [URL] = []
    // Update objects
    var emulatorUpdateObject: GithubResponseObject?
    var romsUpdateObject: GithubResponseObject?
    var macboxUpdateObject: GithubResponseObject?
}


extension VersionInfoObject {

    // Compare the published release against the installed version.
    // Only a strictly newer published release is an update.
    static func macBoxReleaseComparison(
        installed: String?,
        published: String?
    ) -> ComparisonResult? {

        func components(_ version: String?) -> [UInt64]? {

            guard let version = version else {
                return nil
            }

            let parts = version.split(
                separator: ".",
                omittingEmptySubsequences: false
            )

            guard parts.count == 3 else {
                return nil
            }

            var numbers: [UInt64] = []

            for part in parts {

                guard !part.isEmpty,
                      part.utf8.allSatisfy({
                          $0 >= 48 && $0 <= 57
                      }),
                      let number = UInt64(part) else {
                    return nil
                }

                numbers.append(number)
            }

            return numbers
        }

        guard let local = components(installed),
              let remote = components(published) else {
            return nil
        }

        for index in 0..<3 {

            if remote[index] > local[index] {
                return .orderedDescending
            }

            if remote[index] < local[index] {
                return .orderedAscending
            }
        }

        return .orderedSame
    }
}
