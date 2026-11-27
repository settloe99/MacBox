import CommonCrypto
import CryptoKit
import Foundation
import Darwin
import Security

private let fm = FileManager.default
private let laboratoryID = "io.github.settloe99.MacBoxReleaseTest"
private let productionID = "io.github.settloe99.MacBox"
private let trustedReleasePublicKeyX963Base64 = "BPHbb2OKp2V4N6pt7FQed4PIbdlkIcA2NkXWF2uBA+cyN9CtX+NhKUsF6hfZ7fB6XXLs793Kv7G2XBJyle6yvbg="

private func fail(_ message: String) -> NSError {
    return NSError(
        domain: "MacBox.SelfUpdateHelper",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}

private func isRealDirectory(_ url: URL) -> Bool {
    guard url.path == url.resolvingSymlinksInPath().path,
          (try? fm.destinationOfSymbolicLink(atPath: url.path)) == nil,
          let attributes = try? fm.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeDirectory
    else {
        return false
    }
    return true
}

private func validateApp(
    _ url: URL,
    expectedBundleID: String
) throws {

    // Read the actual on-disk Info.plist, not cached
    // Foundation Bundle metadata from an earlier app
    // occupying the same installation path.
    let plistURL = url.appendingPathComponent(
        "Contents/Info.plist"
    )

    guard isRealDirectory(url),
          plistURL.path ==
            plistURL.resolvingSymlinksInPath().path,
          let attributes = try? fm.attributesOfItem(
            atPath: plistURL.path
          ),
          attributes[.type] as? FileAttributeType ==
            .typeRegular,
          let data = try? Data(contentsOf: plistURL),
          let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
          ),
          let info = object as? [String: Any],
          info["CFBundleIdentifier"] as? String ==
            expectedBundleID,
          info["CFBundleExecutable"] as? String ==
            "MacBox" else {

        throw fail("Invalid or unexpected MacBox application.")
    }

    let executable = url.appendingPathComponent(
        "Contents/MacOS/MacBox"
    )

    guard executable.path ==
            executable.resolvingSymlinksInPath().path,
          let executableAttributes =
            try? fm.attributesOfItem(
                atPath: executable.path
            ),
          executableAttributes[.type] as? FileAttributeType ==
            .typeRegular,
          fm.isExecutableFile(atPath: executable.path) else {

        throw fail("MacBox executable is missing or invalid.")
    }
}

// Authenticate a release manifest with our embedded P-256 public key.
// This does not install or modify any application.
private func verifyMacBoxReleaseManifest(
    manifestURL: URL,
    signatureURL: URL
) throws {

    for file in [manifestURL, signatureURL] {
        guard file.path == file.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: file.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= 4096 else {
            throw fail("Invalid release manifest or signature file.")
        }
    }

    let manifest = try Data(contentsOf: manifestURL)
    let signature = try Data(contentsOf: signatureURL)

    guard let text = String(data: manifest, encoding: .utf8) else {
        throw fail("Release manifest is not valid UTF-8.")
    }

    let lines = text.split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    guard lines.count == 4,
          lines[0] == "macbox-release-v1",
          lines[3].isEmpty,
          String(lines[1]).range(
            of: "^version=[0-9]+(\\.[0-9]+){1,3}$",
            options: .regularExpression
          ) != nil,
          String(lines[2]).range(
            of: "^sha256=[0-9a-f]{64}$",
            options: .regularExpression
          ) != nil else {
        throw fail("Invalid MacBox release manifest format.")
    }

    guard let keyBytes = Data(
        base64Encoded: trustedReleasePublicKeyX963Base64
    ),
    keyBytes.count == 65,
    keyBytes.first == 0x04 else {
        throw fail("Invalid embedded release public key.")
    }

    let attributes: [String: Any] = [
        kSecAttrKeyType as String:
            kSecAttrKeyTypeECSECPrimeRandom,
        kSecAttrKeyClass as String:
            kSecAttrKeyClassPublic,
        kSecAttrKeySizeInBits as String: 256
    ]

    guard let publicKey = SecKeyCreateWithData(
        keyBytes as CFData,
        attributes as CFDictionary,
        nil
    ) else {
        throw fail("Cannot load the release verification key.")
    }

    guard SecKeyVerifySignature(
        publicKey,
        .ecdsaSignatureMessageX962SHA256,
        manifest as CFData,
        signature as CFData,
        nil
    ) else {
        throw fail(
            "MacBox release signature verification failed."
        )
    }

    print("PASS: MacBox release signature authenticated.")
}

private func verifySignedMacBoxReleasePackage(
    manifestURL: URL,
    signatureURL: URL,
    archiveURL: URL
) throws -> String {

    // First authenticate the release manifest using our
    // embedded public key.
    try verifyMacBoxReleaseManifest(
        manifestURL: manifestURL,
        signatureURL: signatureURL
    )

    let fm = FileManager.default

    guard archiveURL.path ==
            archiveURL.resolvingSymlinksInPath().path,
          let attributes = try? fm.attributesOfItem(
            atPath: archiveURL.path
          ),
          attributes[.type] as? FileAttributeType ==
            .typeRegular,
          let size = attributes[.size] as? NSNumber,
          size.int64Value > 0,
          size.int64Value <= 512 * 1024 * 1024 else {

        throw fail(
            "Invalid or unsafe MacBox release archive."
        )
    }

    // The manifest format has already been validated
    // and cryptographically authenticated.
    let manifest = try String(
        contentsOf: manifestURL,
        encoding: .utf8
    )

    let lines = manifest.split(
        separator: "\n",
        omittingEmptySubsequences: false
    )

    let releaseVersion = String(
        lines[1].dropFirst("version=".count)
    )

    let expectedSHA256 = String(
        lines[2].dropFirst("sha256=".count)
    )

    // Calculate the checksum of the actual downloaded ZIP.
    let archiveData = try Data(
        contentsOf: archiveURL,
        options: .mappedIfSafe
    )

    var digest = [UInt8](
        repeating: 0,
        count: Int(CC_SHA256_DIGEST_LENGTH)
    )

    archiveData.withUnsafeBytes { buffer in
        _ = CC_SHA256(
            buffer.baseAddress,
            CC_LONG(buffer.count),
            &digest
        )
    }

    let actualSHA256 = digest.map {
        String(format: "%02x", $0)
    }.joined()

    guard actualSHA256 == expectedSHA256 else {
        throw fail(
            "MacBox release package checksum does not match " +
            "the authenticated release manifest."
        )
    }

    print("PASS: Signed release package SHA-256 verified.")
    print("Authenticated release version: \(releaseVersion)")

    return releaseVersion
}

private func validateProductionApp(_ url: URL) throws {

    // Confirm the application has our production bundle identity
    // and the expected executable structure.
    try validateApp(
        url,
        expectedBundleID: productionID
    )

    // Verify the application's code signature and nested code.
    // Ad-hoc signatures are accepted. Unsigned applications
    // and applications with invalid signatures are rejected.
    let verification = Process()

    verification.executableURL = URL(
        fileURLWithPath: "/usr/bin/codesign"
    )

    verification.arguments = [
        "--verify",
        "--deep",
        "--strict",
        url.path
    ]

    verification.standardOutput = FileHandle.nullDevice
    verification.standardError = FileHandle.nullDevice

    try verification.run()
    verification.waitUntilExit()

    guard verification.terminationStatus == 0 else {
        throw fail(
            "The MacBox application failed code-signature " +
            "integrity verification."
        )
    }

    print("PASS: Production application code integrity verified.")
}

private func waitForParentExit(_ pid: pid_t) throws {
    guard pid > 1, pid != getpid() else {
        throw fail("Invalid parent process identifier.")
    }

    let deadline = Date().addingTimeInterval(120)

    while Date() < deadline {
        if kill(pid, 0) != 0 && errno == ESRCH {
            return
        }

        usleep(200_000)
    }

    throw fail(
        "MacBox did not exit within 120 seconds. " +
        "The installation was cancelled."
    )
}

private func relaunch(_ application: URL) throws {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", application.path]

    try task.run()
    task.waitUntilExit()

    guard task.terminationStatus == 0 else {
        throw fail("macOS could not launch the replacement application.")
    }
}

private func runLaboratoryInstallation(
    parentPID: pid_t
) throws {
    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "MacBox-ReleaseTest",
            isDirectory: true
        ).standardizedFileURL

    let source = root.appendingPathComponent(
        "MacBox-UpdateTarget.app",
        isDirectory: true
    )

    let destination = root.appendingPathComponent(
        "MacBox-HelperTarget.app",
        isDirectory: true
    )

    guard isRealDirectory(root),
          destination.path ==
            destination.resolvingSymlinksInPath().path,
          (try? fm.destinationOfSymbolicLink(
            atPath: destination.path
          )) == nil else {
        throw fail("Unsafe Release-Test directory.")
    }

    try validateApp(source, expectedBundleID: laboratoryID)

    let originalExists = fm.fileExists(
        atPath: destination.path
    )

    if originalExists {
        try validateApp(destination, expectedBundleID: laboratoryID)
    }

    let siblings = try fm.contentsOfDirectory(
        atPath: root.path
    )

    guard !siblings.contains(where: {
        $0.hasPrefix(".MacBox-Helper-parked-")
    }) else {
        throw fail(
            "An interrupted installation requires recovery."
        )
    }

    let identifier = UUID().uuidString

    let workspace = root.appendingPathComponent(
        ".MacBox-Helper-work-\(identifier)",
        isDirectory: true
    )

    let staged = workspace.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    let parked = root.appendingPathComponent(
        ".MacBox-Helper-parked-\(identifier).app",
        isDirectory: true
    )

    let rejected = root.appendingPathComponent(
        ".MacBox-Helper-rejected-\(identifier).app",
        isDirectory: true
    )

    try fm.createDirectory(
        at: workspace,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    defer {
        try? fm.removeItem(at: workspace)
    }

    try fm.copyItem(at: source, to: staged)
    try validateApp(staged, expectedBundleID: laboratoryID)

    print("Replacement staged and validated.")
    print("Waiting for MacBox to exit...")

    try waitForParentExit(parentPID)

    if originalExists {
        let backups = root.appendingPathComponent(
            ".MacBox-Helper-backups",
            isDirectory: true
        )

        if fm.fileExists(atPath: backups.path) {
            guard isRealDirectory(backups) else {
                throw fail("Unsafe backup directory.")
            }
        } else {
            try fm.createDirectory(
                at: backups,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        let backup = backups.appendingPathComponent(
            "MacBox-\(identifier).app",
            isDirectory: true
        )

        try fm.copyItem(at: destination, to: backup)
    }

    var originalParked = false
    var newInstalled = false

    do {
        if originalExists {
            try fm.moveItem(at: destination, to: parked)
            originalParked = true
        }

        try fm.moveItem(at: staged, to: destination)
        newInstalled = true

        try validateApp(destination, expectedBundleID: laboratoryID)
        try relaunch(destination)

        if originalParked {
            do {
                try fm.removeItem(at: parked)
            } catch {
                NSLog(
                    "MacBoxHelper: Retained parked application: %@",
                    parked.path
                )
            }
        }

        print("Installation and relaunch request succeeded.")

    } catch {
        let installationError = error

        do {
            if newInstalled &&
                fm.fileExists(atPath: destination.path) {
                try fm.moveItem(
                    at: destination,
                    to: rejected
                )
            }

            if originalParked {
                try fm.moveItem(
                    at: parked,
                    to: destination
                )
            }
        } catch {
            throw fail(
                "Installation and rollback failed. " +
                "The original may remain at \(parked.path). " +
                error.localizedDescription
            )
        }

        throw installationError
    }
}


// Inspect the ZIP structure before any extraction.
// Accept only regular files and directories within MacBox.app
// or Apple's optional __MACOSX metadata directory.
@discardableResult
private func validateProductionReleaseZIP(
    at archiveURL: URL
) throws -> String {

    let fm = FileManager.default

    guard archiveURL.path ==
            archiveURL.resolvingSymlinksInPath().path,
          let attributes = try? fm.attributesOfItem(
            atPath: archiveURL.path
          ),
          attributes[.type] as? FileAttributeType == .typeRegular,
          let size = attributes[.size] as? NSNumber,
          size.int64Value > 0,
          size.int64Value <= 512 * 1024 * 1024 else {
        throw fail("Unsafe release ZIP file.")
    }

    let archive = try Data(
        contentsOf: archiveURL,
        options: []
    )

    try archive.withUnsafeBytes { raw in

        let bytes = raw.bindMemory(to: UInt8.self)
        let length = bytes.count

        func read16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= length - 2 else {
                return nil
            }
            return Int(bytes[offset]) |
                (Int(bytes[offset + 1]) << 8)
        }

        func read32(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= length - 4 else {
                return nil
            }
            return Int(bytes[offset]) |
                (Int(bytes[offset + 1]) << 8) |
                (Int(bytes[offset + 2]) << 16) |
                (Int(bytes[offset + 3]) << 24)
        }

        guard length >= 22 else {
            throw fail("ZIP end-of-directory record missing.")
        }

        // Locate the final ZIP central-directory record.
        let lowest = max(0, length - 22 - 65535)
        var endRecord: Int?

        for offset in stride(
            from: length - 22,
            through: lowest,
            by: -1
        ) {
            if read32(offset) == 0x06054b50,
               let commentLength = read16(offset + 20),
               offset + 22 + commentLength == length {
                endRecord = offset
                break
            }
        }

        guard let eocd = endRecord,
              let disk = read16(eocd + 4),
              let centralDisk = read16(eocd + 6),
              let diskEntries = read16(eocd + 8),
              let entryCount = read16(eocd + 10),
              let centralSize = read32(eocd + 12),
              let centralOffset = read32(eocd + 16),
              disk == 0,
              centralDisk == 0,
              diskEntries == entryCount,
              entryCount > 0,
              entryCount <= 20000,
              entryCount != 0xFFFF,
              centralSize != 0xFFFFFFFF,
              centralOffset != 0xFFFFFFFF,
              centralOffset + centralSize == eocd else {
            throw fail(
                "Unsupported or inconsistent ZIP central directory."
            )
        }

        var cursor = centralOffset
        var seen = Set<String>()
        var regularFiles = Set<String>()
        var ranges: [(start: Int, end: Int)] = []
        var totalExpanded: UInt64 = 0

        var foundInfo = false
        var foundExecutable = false

        for _ in 0..<entryCount {

            guard cursor <= eocd - 46,
                  read32(cursor) == 0x02014b50,
                  let flags = read16(cursor + 8),
                  let method = read16(cursor + 10),
                  let packedSize = read32(cursor + 20),
                  let expandedSize = read32(cursor + 24),
                  let nameLength = read16(cursor + 28),
                  let extraLength = read16(cursor + 30),
                  let commentLength = read16(cursor + 32),
                  let diskStart = read16(cursor + 34),
                  let external = read32(cursor + 38),
                  let localOffset = read32(cursor + 42) else {
                throw fail("Invalid ZIP central-directory entry.")
            }

            let recordEnd = cursor + 46 +
                nameLength + extraLength + commentLength

            guard recordEnd <= eocd,
                  nameLength > 0,
                  nameLength <= 4096,
                  diskStart == 0,
                  packedSize != 0xFFFFFFFF,
                  expandedSize != 0xFFFFFFFF,
                  method == 0 || method == 8,
                  (flags & ~0x080E) == 0 else {
                throw fail("Unsupported ZIP entry.")
            }

            if method == 0 && packedSize != expandedSize {
                throw fail("Invalid stored ZIP entry size.")
            }

            let nameStart = cursor + 46

            let nameData = Data(
                bytes: raw.baseAddress!.advanced(by: nameStart),
                count: nameLength
            )

            guard let name = String(
                data: nameData,
                encoding: .utf8
            ) else {
                throw fail("Invalid ZIP filename encoding.")
            }

            guard name.hasPrefix("MacBox.app/") ||
                    name.hasPrefix("__MACOSX/") else {
                throw fail("ZIP entry outside MacBox.app.")
            }

            guard !name.contains("\\"),
                  name.unicodeScalars.allSatisfy({
                    $0.value >= 32 && $0.value != 127
                  }) else {
                throw fail("Unsafe ZIP filename characters.")
            }

            let directory = name.hasSuffix("/")
            var parts = name.components(separatedBy: "/")

            if directory {
                parts.removeLast()
            }

            guard !parts.isEmpty,
                  parts.allSatisfy({
                    !$0.isEmpty &&
                    $0 != "." &&
                    $0 != ".." &&
                    $0.utf8.count <= 255
                  }) else {
                throw fail("Unsafe ZIP path components.")
            }

            let logicalName = parts.joined(separator: "/")

            let key = logicalName
                .precomposedStringWithCanonicalMapping
                .folding(
                    options: [
                        .caseInsensitive,
                        .diacriticInsensitive,
                        .widthInsensitive
                    ],
                    locale: Locale(identifier: "en_US_POSIX")
                )

            guard seen.insert(key).inserted else {
                throw fail("Duplicate ZIP entry.")
            }

            // Unix file-type bits identify symlinks and special files.
            let fileType = (external >> 16) & 0xF000

            guard fileType == 0 ||
                    fileType == (directory ? 0x4000 : 0x8000),
                  (external & 0x10) == 0 || directory else {
                throw fail("Symbolic link or special ZIP entry.")
            }

            if directory {
                guard expandedSize == 0 else {
                    throw fail("Directory contains file data.")
                }
            } else {
                regularFiles.insert(key)
            }

            guard expandedSize <= 256 * 1024 * 1024 else {
                throw fail("ZIP entry exceeds size limit.")
            }

            totalExpanded += UInt64(expandedSize)

            guard totalExpanded <= 1024 * 1024 * 1024 else {
                throw fail("ZIP extraction size limit exceeded.")
            }

            // Compare the local entry with the central directory.
            guard localOffset < centralOffset,
                  read32(localOffset) == 0x04034b50,
                  read16(localOffset + 6) == flags,
                  read16(localOffset + 8) == method,
                  let localNameLength = read16(localOffset + 26),
                  let localExtraLength = read16(localOffset + 28),
                  localNameLength == nameLength else {
                throw fail("Inconsistent local ZIP header.")
            }

            let localNameStart = localOffset + 30
            let dataStart = localNameStart +
                localNameLength + localExtraLength

            guard dataStart <= centralOffset,
                  packedSize <= centralOffset - dataStart else {
                throw fail("ZIP entry exceeds archive boundaries.")
            }

            for index in 0..<nameLength {
                guard bytes[localNameStart + index] ==
                        bytes[nameStart + index] else {
                    throw fail("ZIP filename header mismatch.")
                }
            }

            ranges.append((
                start: localOffset,
                end: dataStart + packedSize
            ))

            if name == "MacBox.app/Contents/Info.plist" {
                foundInfo = true
            }

            if name == "MacBox.app/Contents/MacOS/MacBox" {
                foundExecutable = true
            }

            cursor = recordEnd
        }

        guard cursor == eocd,
              foundInfo,
              foundExecutable else {
            throw fail("Incomplete or invalid MacBox ZIP contents.")
        }

        // No regular file can also act as a parent directory.
        for key in seen {
            var parts = key.components(separatedBy: "/")

            while parts.count > 1 {
                parts.removeLast()

                guard !regularFiles.contains(
                    parts.joined(separator: "/")
                ) else {
                    throw fail("ZIP file and directory path conflict.")
                }
            }
        }

        // Local ZIP headers and compressed data must not overlap.
        ranges.sort { $0.start < $1.start }

        for index in 1..<ranges.count {
            guard ranges[index - 1].end <=
                    ranges[index].start else {
                throw fail("Overlapping ZIP entries.")
            }
        }
    }

    let validatedDigest = SHA256.hash(data: archive)
        .map { String(format: "%02x", $0) }
        .joined()

    print("PASS: MacBox ZIP structure validated.")

    return validatedDigest
}

private func extractAuthenticatedMacBoxRelease(
    manifestURL: URL,
    signatureURL: URL,
    archiveURL: URL,
    workspace: URL
) throws -> URL {

    guard isRealDirectory(workspace) else {
        throw fail("Unsafe release extraction workspace.")
    }

    // Check the input files before copying them into
    // the helper's private installation workspace.
    for input in [manifestURL, signatureURL, archiveURL] {
        let file = input.standardizedFileURL

        guard file.path == file.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: file.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular else {
            throw fail("Unsafe release input file.")
        }
    }

    let localManifest = workspace.appendingPathComponent(
        "MacBox-release.manifest"
    )

    let localSignature = workspace.appendingPathComponent(
        "MacBox-release.manifest.sig"
    )

    let localArchive = workspace.appendingPathComponent(
        "MacBox-update.zip"
    )

    // Copy the release files before verifying them.
    // The verified copy is the one we will extract.
    try fm.copyItem(at: manifestURL, to: localManifest)
    try fm.copyItem(at: signatureURL, to: localSignature)
    try fm.copyItem(at: archiveURL, to: localArchive)

    // Authenticate the signed manifest and verify that
    // the actual ZIP matches its authorised SHA-256.
    let authenticatedVersion =
        try verifySignedMacBoxReleasePackage(
            manifestURL: localManifest,
            signatureURL: localSignature,
            archiveURL: localArchive
        )

    // Independently inspect the authenticated ZIP before
    // allowing the external helper to extract its contents.
    // Reject unsafe paths, links, duplicates and oversized entries.
    try validateProductionReleaseZIP(at: localArchive)

    // Extract the authenticated ZIP using macOS ditto.
    let extractor = Process()
    extractor.executableURL = URL(
        fileURLWithPath: "/usr/bin/ditto"
    )

    extractor.arguments = [
        "-x",
        "-k",
        localArchive.path,
        workspace.path
    ]

    try extractor.run()
    extractor.waitUntilExit()

    guard extractor.terminationStatus == 0 else {
        throw fail("Authenticated MacBox ZIP extraction failed.")
    }

    let application = workspace.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    // Validate the actual extracted application.
    try validateApp(
        application,
        expectedBundleID: productionID
    )

    guard let bundle = Bundle(url: application),
          let applicationVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
          ) as? String,
          applicationVersion == authenticatedVersion else {

        throw fail(
            "Extracted MacBox version does not match " +
            "the authenticated release manifest."
        )
    }

    print(
        "PASS: Authenticated MacBox v\(authenticatedVersion) " +
        "extracted and validated."
    )

    return application
}

    private func runProductionInstallation(
        parentPID: pid_t,
        manifestURL: URL,
        signatureURL: URL,
        archiveURL: URL,
        destination: URL
    ) throws {

    guard geteuid() != 0 else {
        throw fail("MacBox updater must not run as root.")
    }

    let home = fm.homeDirectoryForCurrentUser.standardizedFileURL

    let stagingRoot = home.appendingPathComponent(
        "Library/Caches/io.github.settloe99.MacBox/StagedUpdates",
        isDirectory: true
    ).standardizedFileURL

    let target = destination.standardizedFileURL
    let targetParent = target.deletingLastPathComponent()

    // All three release files must come directly from
    // our private MacBox update staging directory.
    guard isRealDirectory(stagingRoot) else {
        throw fail("MacBox release staging directory is missing or unsafe.")
    }

    for input in [manifestURL, signatureURL, archiveURL] {
        let file = input.standardizedFileURL

        guard file.deletingLastPathComponent() == stagingRoot,
              file.path == file.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: file.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular else {

            throw fail("Unsafe MacBox release input file.")
        }
    }

    // Only replace an existing MacBox application.
    guard target.lastPathComponent == "MacBox.app",
          isRealDirectory(targetParent),
          isRealDirectory(target),
          target.path == target.resolvingSymlinksInPath().path else {

        throw fail("Unsafe production application destination.")
    }

    // Production installation remains locked until the
    // independent release-authentication path is complete.
    try validateProductionApp(target)

    #if !MACBOX_MIGRATION_LAB

    if !fm.isWritableFile(atPath: targetParent.path) {

        guard target.path == "/Applications/MacBox.app" else {
            throw fail(
                "Unsupported protected MacBox installation location."
            )
        }

        try waitForParentExit(parentPID)

        try runAdministratorAuthorizedInstallation(
            manifest: manifestURL,
            signature: signatureURL,
            archive: archiveURL,
            mode: "install",
            operation: "update"
        )

        return
    }

    #endif

    let siblings = try fm.contentsOfDirectory(
        atPath: targetParent.path
    )

    guard !siblings.contains(where: {
        $0.hasPrefix(".MacBox-SelfUpdate-parked-")
    }) else {
        throw fail(
            "An interrupted MacBox update requires recovery."
        )
    }

    let identifier = UUID().uuidString

    let workspace = targetParent.appendingPathComponent(
        ".MacBox-SelfUpdate-work-\(identifier)",
        isDirectory: true
    )

    let staged = workspace.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    let parked = targetParent.appendingPathComponent(
        ".MacBox-SelfUpdate-parked-\(identifier).app",
        isDirectory: true
    )

    let rejected = targetParent.appendingPathComponent(
        ".MacBox-SelfUpdate-rejected-\(identifier).app",
        isDirectory: true
    )

    try fm.createDirectory(
        at: workspace,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    defer {
        try? fm.removeItem(at: workspace)
    }

    // Copy the authenticated replacement into a workspace
    // on the same filesystem as the existing application.

    // Authenticate the signed release manifest and ZIP,
    // then extract the verified application directly into
    // our private installation workspace.
    let authenticatedApplication =
        try extractAuthenticatedMacBoxRelease(
            manifestURL: manifestURL,
            signatureURL: signatureURL,
            archiveURL: archiveURL,
            workspace: workspace
        )

    guard authenticatedApplication.standardizedFileURL ==
            staged.standardizedFileURL else {

        throw fail(
            "Authenticated release extraction returned " +
            "an unexpected application location."
        )
    }

    // Production signature verification remains enforced.
    try validateProductionApp(staged)

    // Reject updates that do not advance the installed version.
    guard let existingBundle = Bundle(url: target),
          let replacementBundle = Bundle(url: staged),
          let existingVersion = existingBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
          ) as? String,
          let replacementVersion = replacementBundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
          ) as? String,
          replacementVersion.compare(
            existingVersion,
            options: .numeric
          ) == .orderedDescending else {

        throw fail(
            "The authenticated update must be newer " +
            "than the installed MacBox version."
        )
    }

    // Do not replace the application while it is running.
    try waitForParentExit(parentPID)

    // Revalidate the installed application before modifying it.
    try validateProductionApp(target)

    let backups = targetParent.appendingPathComponent(
        ".MacBox-SelfUpdate-backups",
        isDirectory: true
    )

    if fm.fileExists(atPath: backups.path) {
        guard isRealDirectory(backups) else {
            throw fail("Unsafe MacBox backup directory.")
        }
    } else {
        try fm.createDirectory(
            at: backups,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    let backup = backups.appendingPathComponent(
        "MacBox-\(identifier).app",
        isDirectory: true
    )

    // Preserve an independent backup before replacement.
    try fm.copyItem(at: target, to: backup)
    try validateProductionApp(backup)

    var originalParked = false
    var newInstalled = false

    do {
        try fm.moveItem(at: target, to: parked)
        originalParked = true

        try fm.moveItem(at: staged, to: target)
        newInstalled = true

        // Validate the application at its final destination.
        try validateProductionApp(target)

        // Request relaunch only after successful installation.
        try relaunch(target)

        // Preserve the independent backup.
        // The parked copy is no longer required after relaunch.
        do {
            try fm.removeItem(at: parked)
        } catch {
            NSLog(
                "MacBoxHelper: Retained parked application: %@",
                parked.path
            )
        }

        print("Production MacBox installation completed.")
        print("Independent backup: \(backup.path)")

    } catch {
        let installationError = error

        do {
            if newInstalled &&
                fm.fileExists(atPath: target.path) {
                try fm.moveItem(
                    at: target,
                    to: rejected
                )
            }

            if originalParked {
                try fm.moveItem(
                    at: parked,
                    to: target
                )
            }

        } catch {
            throw fail(
                "Production installation and rollback failed. " +
                "The original may remain at \(parked.path). " +
                "Rollback error: \(error.localizedDescription)"
            )
        }

        throw installationError
    }
}


#if MACBOX_MIGRATION_LAB

// Isolated acceptance test for migration from Moonif.MacBox.
// This code is excluded from normal production builds.
private func runLegacyMigrationLaboratory() throws {

    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "MacBox-ReleaseTest/LegacyMigration-Lab",
            isDirectory: true
        ).standardizedFileURL

    let original = root.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    let release = root.appendingPathComponent(
        "Release",
        isDirectory: true
    )

    guard isRealDirectory(root),
          isRealDirectory(original),
          isRealDirectory(release),
          root.path == root.resolvingSymlinksInPath().path,
          original.path == original.resolvingSymlinksInPath().path,
          Bundle(url: original)?.bundleIdentifier ==
            "Moonif.MacBox" else {
        throw fail("Invalid legacy migration laboratory.")
    }

    // Verify the original application's code integrity.
    try validateApp(
        original,
        expectedBundleID: "Moonif.MacBox"
    )

    let signatureCheck = Process()
    signatureCheck.executableURL = URL(
        fileURLWithPath: "/usr/bin/codesign"
    )
    signatureCheck.arguments = [
        "--verify", "--deep", "--strict", original.path
    ]
    signatureCheck.standardOutput = FileHandle.nullDevice
    signatureCheck.standardError = FileHandle.nullDevice

    try signatureCheck.run()
    signatureCheck.waitUntilExit()

    guard signatureCheck.terminationStatus == 0 else {
        throw fail("Original MacBox code signature is invalid.")
    }

    let identifier = UUID().uuidString

    let workspace = root.appendingPathComponent(
        ".MacBox-Legacy-work-\(identifier)",
        isDirectory: true
    )

    let staged = workspace.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    let parked = root.appendingPathComponent(
        ".MacBox-Legacy-parked-\(identifier).app",
        isDirectory: true
    )

    let rejected = root.appendingPathComponent(
        ".MacBox-Legacy-rejected-\(identifier).app",
        isDirectory: true
    )

    let backups = root.appendingPathComponent(
        ".MacBox-Legacy-backups",
        isDirectory: true
    )

    guard !fm.fileExists(atPath: backups.path),
          !fm.fileExists(atPath: workspace.path),
          !fm.fileExists(atPath: parked.path),
          !fm.fileExists(atPath: rejected.path) else {
        throw fail("Migration laboratory already contains transactions.")
    }

    try fm.createDirectory(
        at: workspace,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    defer {
        try? fm.removeItem(at: workspace)
    }

    // Authenticate and extract the signed replacement.
    let authenticated = try extractAuthenticatedMacBoxRelease(
        manifestURL: release.appendingPathComponent(
            "MacBox-release.manifest"
        ),
        signatureURL: release.appendingPathComponent(
            "MacBox-release.manifest.sig"
        ),
        archiveURL: release.appendingPathComponent(
            "MacBox-v0.6.4.zip"
        ),
        workspace: workspace
    )

    guard authenticated.standardizedFileURL ==
            staged.standardizedFileURL else {
        throw fail("Unexpected replacement application location.")
    }

    try validateProductionApp(staged)

    // Preserve the original application independently.
    try fm.createDirectory(
        at: backups,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    let backup = backups.appendingPathComponent(
        "MacBox-\(identifier).app",
        isDirectory: true
    )

    try fm.copyItem(at: original, to: backup)

    try validateApp(
        backup,
        expectedBundleID: "Moonif.MacBox"
    )

    var originalParked = false
    var replacementInstalled = false

    do {
        try fm.moveItem(at: original, to: parked)
        originalParked = true

        try fm.moveItem(at: staged, to: original)
        replacementInstalled = true

        try validateProductionApp(original)

        // Fresh on-disk identity and signature verified above.

        // Independent backup remains available for recovery.
        try? fm.removeItem(at: parked)

        print("PASS: Legacy MacBox migrated in laboratory.")
        print("PASS: Replacement authenticated and verified.")
        print("Original application backup: \(backup.path)")
        print("Migrated application: \(original.path)")

    } catch {
        let installationError = error

        if originalParked {
            do {
                if replacementInstalled &&
                    fm.fileExists(atPath: original.path) {
                    try fm.moveItem(at: original, to: rejected)
                }

                try fm.moveItem(at: parked, to: original)

                print("PASS: Original application restored.")
            } catch {
                throw fail(
                    "Legacy migration rollback failed. " +
                    "Original may remain at \(parked.path). " +
                    "Error: \(error.localizedDescription)"
                )
            }
        }

        throw installationError
    }
}

#endif

// Read-only validation for migrating the original Moonif MacBox.
// No application is modified by this function.

// The laboratory and production installer share the same
// transaction but cannot select arbitrary destinations.
private func legacyMigrationDestination() -> URL {

    #if MACBOX_MIGRATION_LAB

    return fm.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "MacBox-ReleaseTest/LegacyMigration-Shared-Lab/MacBox.app",
            isDirectory: true
        ).standardizedFileURL

    #else

    return URL(
        fileURLWithPath: "/Applications/MacBox.app",
        isDirectory: true
    ).standardizedFileURL

    #endif
}

private func preflightLegacyProductionMigration(
    manifestURL: URL,
    signatureURL: URL,
    archiveURL: URL
) throws -> String {

    let original = legacyMigrationDestination()

    guard original.path ==
            original.resolvingSymlinksInPath().path else {
        throw fail("Unsafe original MacBox location.")
    }

    try validateApp(
        original,
        expectedBundleID: "Moonif.MacBox"
    )

    // Verify the original application has a valid code signature.
    let check = Process()

    check.executableURL = URL(
        fileURLWithPath: "/usr/bin/codesign"
    )

    check.arguments = [
        "--verify",
        "--deep",
        "--strict",
        original.path
    ]

    check.standardOutput = FileHandle.nullDevice
    check.standardError = FileHandle.nullDevice

    try check.run()
    check.waitUntilExit()

    guard check.terminationStatus == 0 else {
        throw fail("Original MacBox signature verification failed.")
    }

    print("PASS: Original Moonif MacBox verified.")

    // Authenticate the independently signed replacement.
    let version = try verifySignedMacBoxReleasePackage(
        manifestURL: manifestURL,
        signatureURL: signatureURL,
        archiveURL: archiveURL
    )

    // Verify the archive structure without extracting it.
    try validateProductionReleaseZIP(at: archiveURL)

    print("PASS: Replacement release authenticated.")
    print("PASS: Replacement archive structure validated.")
    print("PASS: Production legacy migration preflight completed.")

    return version
}

// Dedicated migration transaction for the original Moonif MacBox.
// This is separate from ordinary authenticated self-updates.
// It may only replace /Applications/MacBox.app.
private func runProductionLegacyMigration(
    parentPID: pid_t,
    manifestURL: URL,
    signatureURL: URL,
    archiveURL: URL
) throws {

    // Elevation is deliberately disabled until the
    // dedicated administrator-authorisation path is ready.
    guard geteuid() != 0 else {
        throw fail("Privileged migration is not enabled yet.")
    }

    let target = legacyMigrationDestination()
    let parent = target.deletingLastPathComponent()

    // Require the expected staged-release filename convention.
    let archive = archiveURL.standardizedFileURL
    let manifest = manifestURL.standardizedFileURL
    let signature = signatureURL.standardizedFileURL
    let base = archive.deletingPathExtension()


    // Identify the account that owns the downloaded package.
    // This also works when the installer is running as root.
    guard let archiveAttributes = try? fm.attributesOfItem(
            atPath: archive.path
          ),
          let ownerNumber = archiveAttributes[
            .ownerAccountID
          ] as? NSNumber,
          let account = getpwuid(
            uid_t(ownerNumber.uint32Value)
          ),
          let homePointer = account.pointee.pw_dir else {

        throw fail("Cannot identify release staging owner.")
    }

    let accountHome = URL(
        fileURLWithPath: String(cString: homePointer),
        isDirectory: true
    ).standardizedFileURL

    let expectedStagingRoot = accountHome
        .appendingPathComponent(
            "Library/Caches/io.github.settloe99.MacBox/StagedUpdates",
            isDirectory: true
        ).standardizedFileURL

    guard isRealDirectory(expectedStagingRoot),
          expectedStagingRoot.path ==
            expectedStagingRoot.resolvingSymlinksInPath().path,
          archive.deletingLastPathComponent() ==
            expectedStagingRoot else {

        throw fail("Release files are outside trusted staging.")
    }

    // All three files must be regular, owned by the same
    // user, and free from symbolic-link redirection.
    for input in [archive, manifest, signature] {

        guard input.deletingLastPathComponent() ==
                expectedStagingRoot,
              input.path ==
                input.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: input.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular,
              let owner = attributes[
                .ownerAccountID
              ] as? NSNumber,
              owner.uint32Value ==
                ownerNumber.uint32Value else {

            throw fail("Unsafe authenticated release input.")
        }
    }

    guard archive.pathExtension.lowercased() == "zip",
          UUID(uuidString: base.lastPathComponent) != nil,
          manifest == base.appendingPathExtension("manifest"),
          signature == base.appendingPathExtension("sig"),
          parent.path == parent.resolvingSymlinksInPath().path,
          isRealDirectory(parent),
          isRealDirectory(target),
          target.path == target.resolvingSymlinksInPath().path else {
        throw fail("Unsafe legacy migration destination or input.")
    }

    // Authenticate the signed release and verify the original
    // Moonif application before creating any installation files.
    _ = try preflightLegacyProductionMigration(
        manifestURL: manifest,
        signatureURL: signature,
        archiveURL: archive
    )

    // An interrupted earlier migration must be recovered first.
    #if !MACBOX_MIGRATION_LAB

    if !fm.isWritableFile(atPath: parent.path) {

        guard target.path == "/Applications/MacBox.app" else {
            throw fail("Unsupported protected migration destination.")
        }

        try waitForParentExit(parentPID)

        try runAdministratorAuthorizedInstallation(
            manifest: manifest,
            signature: signature,
            archive: archive,
            mode: "install",
            operation: "migration"
        )

        return
    }

    #endif

    let siblings = try fm.contentsOfDirectory(atPath: parent.path)

    guard !siblings.contains(where: {
        $0.hasPrefix(".MacBox-Legacy-parked-")
    }) else {
        throw fail("An interrupted legacy migration requires recovery.")
    }

    let identifier = UUID().uuidString

    let workspace = parent.appendingPathComponent(
        ".MacBox-Legacy-work-\(identifier)",
        isDirectory: true
    )

    let staged = workspace.appendingPathComponent(
        "MacBox.app",
        isDirectory: true
    )

    let parked = parent.appendingPathComponent(
        ".MacBox-Legacy-parked-\(identifier).app",
        isDirectory: true
    )

    let rejected = parent.appendingPathComponent(
        ".MacBox-Legacy-rejected-\(identifier).app",
        isDirectory: true
    )

    // Never overwrite existing transaction files.
    guard !fm.fileExists(atPath: workspace.path),
          !fm.fileExists(atPath: parked.path),
          !fm.fileExists(atPath: rejected.path) else {
        throw fail("Legacy migration transaction path already exists.")
    }

    try fm.createDirectory(
        at: workspace,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )

    defer {
        try? fm.removeItem(at: workspace)
    }

    // Verify and extract the authenticated application.
    let authenticated = try extractAuthenticatedMacBoxRelease(
        manifestURL: manifest,
        signatureURL: signature,
        archiveURL: archive,
        workspace: workspace
    )

    guard authenticated.standardizedFileURL ==
            staged.standardizedFileURL else {
        throw fail("Unexpected authenticated application location.")
    }

    try validateProductionApp(staged)

    // Wait until the initiating MacBox process has exited.
    try waitForParentExit(parentPID)

    // Recheck the original application before replacement.
    // The ordinary updater's productionID check is deliberately
    // not used for the original Moonif application.
    try validateApp(
        target,
        expectedBundleID: "Moonif.MacBox"
    )

    let originalCheck = Process()
    originalCheck.executableURL = URL(
        fileURLWithPath: "/usr/bin/codesign"
    )
    originalCheck.arguments = [
        "--verify", "--deep", "--strict", target.path
    ]
    originalCheck.standardOutput = FileHandle.nullDevice
    originalCheck.standardError = FileHandle.nullDevice

    try originalCheck.run()
    originalCheck.waitUntilExit()

    guard originalCheck.terminationStatus == 0 else {
        throw fail("Original Moonif MacBox code signature invalid.")
    }

    let backups = parent.appendingPathComponent(
        ".MacBox-Legacy-backups",
        isDirectory: true
    )

    if fm.fileExists(atPath: backups.path) {
        guard isRealDirectory(backups) else {
            throw fail("Unsafe legacy backup directory.")
        }
    } else {
        try fm.createDirectory(
            at: backups,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    let backup = backups.appendingPathComponent(
        "MacBox-\(identifier).app",
        isDirectory: true
    )

    // Preserve the original before modifying its location.
    try fm.copyItem(at: target, to: backup)

    try validateApp(
        backup,
        expectedBundleID: "Moonif.MacBox"
    )

    var originalParked = false
    var replacementInstalled = false

    do {
        try fm.moveItem(at: target, to: parked)
        originalParked = true

        try fm.moveItem(at: staged, to: target)
        replacementInstalled = true

        // Check the replacement at its final location.
        try validateProductionApp(target)

        // When running without elevation, relaunch directly.
        // Elevated installations will require a separate
        // user-session relaunch step.
        #if MACBOX_MIGRATION_LAB

        print("PASS: Laboratory relaunch deliberately suppressed.")

        #else

        try relaunch(target)

        #endif

        // Retain the independent backup.
        do {
            try fm.removeItem(at: parked)
        } catch {
            NSLog(
                "MacBoxMigration: Retained parked original at %@",
                parked.path
            )
        }

        print("PASS: Production legacy migration completed.")
        print("Original application backup: \(backup.path)")
        print("Maintained application: \(target.path)")

    } catch {
        let installationError = error

        if originalParked {
            do {
                if replacementInstalled &&
                    fm.fileExists(atPath: target.path) {
                    try fm.moveItem(at: target, to: rejected)
                }

                try fm.moveItem(at: parked, to: target)

                print("PASS: Original Moonif application restored.")

            } catch {
                throw fail(
                    "Legacy migration and rollback failed. " +
                    "The original may remain at \(parked.path). " +
                    "Rollback error: \(error.localizedDescription)"
                )
            }
        }

        throw installationError
    }
}

private func runAdministratorAuthorizedCommand(
    _ executable: String,
    arguments: [String]
) throws -> String {

    // Quote every argument independently for the POSIX shell.
    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(
            of: "'",
            with: "'\\''"
        ) + "'"
    }

    // This bridge is restricted to the system shell.
    // Never elevate the MacBox helper executable itself.
    guard executable == "/bin/sh" else {
        throw fail("Unsupported administrator command.")
    }

    let command = ([executable] + arguments)
        .map { shellQuote($0) }
        .joined(separator: " ")

    let appleScript = """
    on run argv
        with timeout of 600 seconds
            do shell script (item 1 of argv) with administrator privileges with prompt "MacBox requires administrator permission to install an authenticated application update."
        end timeout
    end run
    """

    let process = Process()

    process.executableURL = URL(
        fileURLWithPath: "/usr/bin/osascript"
    )

    process.arguments = [
        "-e",
        appleScript,
        command
    ]

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()

    let data = output.fileHandleForReading
        .readDataToEndOfFile()

    process.waitUntilExit()

    let result = String(
        data: data,
        encoding: .utf8
    ) ?? ""

    guard process.terminationStatus == 0 else {
        throw fail(
            "Administrator operation was cancelled or failed: " +
            result.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }

    return result.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
}




// Exercise privileged installation against a fixed,
// root-owned laboratory. Never target /Applications.
private func runAdministratorAuthorizedInstallation(
    manifest: URL,
    signature: URL,
    archive: URL,
    mode: String,
    operation: String = "migration"
) throws {

    guard geteuid() != 0,
          mode == "install" || mode == "rollback" else {
        throw fail("Invalid protected migration request.")
    }

    // Initial verification remains unprivileged.
    _ = try verifySignedMacBoxReleasePackage(
        manifestURL: manifest,
        signatureURL: signature,
        archiveURL: archive
    )

    guard operation == "migration" ||
            operation == "update" else {
        throw fail("Unsupported protected operation.")
    }

    let expectedID = operation == "migration"
        ? "Moonif.MacBox"
        : "io.github.settloe99.MacBox"

    let validatedSHA256 = try validateProductionReleaseZIP(
        at: archive
    )

    // Only this fixed shell routine receives elevation.
    #if MACBOX_MIGRATION_LAB

    let installationParentPath =
        "/private/var/tmp/io.github.settloe99.MacBox-Authorization-Lab"

    #else

    guard mode == "install" else {
        throw fail("Laboratory failure simulation is unavailable.")
    }

    let installationParentPath = "/Applications"

    #endif

    let script = #"""
set -eu
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

LAB="__MACBOX_INSTALLATION_PARENT__"
TARGET="$LAB/MacBox.app"

UID_NUMBER="$1"
MANIFEST="$2"
SIGNATURE="$3"
ARCHIVE="$4"
MODE="$5"
VALIDATED_SHA="$6"
EXPECTED_ID="$7"

case "$EXPECTED_ID" in
    Moonif.MacBox|io.github.settloe99.MacBox) ;;
    *) exit 1 ;;
esac

test "$(/usr/bin/id -u)" = "0"
test -d "$LAB"
test ! -L "$LAB"
test "$(/usr/bin/stat -f '%u' "$LAB")" = "0"
if [ "$LAB" = "/Applications" ]; then

    case "$(/usr/bin/stat -f '%Lp' "$LAB")" in
        755|775) ;;
        *) exit 1 ;;
    esac

    case "$(/usr/bin/stat -f '%Sg' "$LAB")" in
        admin|wheel) ;;
        *) exit 1 ;;
    esac

    test "$MODE" = "install"

    # Only elevate when the initiating user cannot
    # write to the approved application directory.
    /usr/bin/sudo -n -u "#$UID_NUMBER" \
        /bin/test ! -w "$LAB"

else
    test "$(/usr/bin/stat -f '%Lp' "$LAB")" = "755"
fi

case "$UID_NUMBER" in
    ''|*[!0-9]*|0) exit 1 ;;
esac

case "$MODE" in
    install|rollback) ;;
    *) exit 1 ;;
esac

validate_app() {
    APP="$1"
    EXPECTED_ID="$2"

    test -d "$APP"
    test ! -L "$APP"

    ACTUAL_ID=$(/usr/libexec/PlistBuddy \
        -c "Print CFBundleIdentifier" \
        "$APP/Contents/Info.plist")

    test "$ACTUAL_ID" = "$EXPECTED_ID"

    /usr/bin/codesign --verify --deep --strict "$APP"
}

validate_app "$TARGET" "$EXPECTED_ID"

WORK=$(/usr/bin/mktemp -d "$LAB/.MacBox-Work.XXXXXX")
PARKED="$WORK/Original.app"

ORIGINAL_PARKED=0
REPLACEMENT_INSTALLED=0
COMMITTED=0

finish() {
    STATUS=$?
    trap - 0
    set +e

    if [ "$COMMITTED" = "0" ] &&
       [ "$ORIGINAL_PARKED" = "1" ]; then

        if [ "$REPLACEMENT_INSTALLED" = "1" ]; then
            if ! /bin/mv "$TARGET" "$WORK/Rejected.app"; then
                echo "FAIL: Cannot park rejected replacement."
                echo "Recovery workspace: $WORK"
                exit 1
            fi
        fi

        if ! /bin/mv "$PARKED" "$TARGET"; then
            echo "FAIL: Rollback could not restore original."
            echo "Recovery workspace: $WORK"
            exit 1
        fi

        if ! validate_app "$TARGET" "$EXPECTED_ID"; then
            echo "FAIL: Restored application failed verification."
            exit 1
        fi

        echo "PASS: Original application restored by rollback."
    fi

    /bin/rm -rf "$WORK"
    exit "$STATUS"
}

trap finish 0

# Read release inputs with the initiating user's permissions,
# not root's permissions. Store copies in root-private storage.
copy_input() {
    INPUT="$1"
    OUTPUT="$2"
    LIMIT="$3"

    case "$INPUT" in
        /*) ;;
        *) exit 1 ;;
    esac

    (
        ulimit -f "$LIMIT"
        /usr/bin/sudo -n -u "#$UID_NUMBER" \
            /bin/cat "$INPUT"
    ) > "$OUTPUT"
}

copy_input "$MANIFEST" "$WORK/release.manifest" 8
copy_input "$SIGNATURE" "$WORK/release.sig" 8
copy_input "$ARCHIVE" "$WORK/release.zip" 1048576

test "$(/usr/bin/stat -f '%z' "$WORK/release.manifest")" -le 4096
test "$(/usr/bin/stat -f '%z' "$WORK/release.sig")" -le 4096
test "$(/usr/bin/stat -f '%z' "$WORK/release.zip")" -le 536870912

# The key is embedded in the helper, not obtained from
# GitHub or from the user-writable release directory.
cat > "$WORK/public.pem" <<'MACBOX_PINNED_KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8dtvY4qnZXg3qm3sVB53g8ht2WQh
wDY2RdYXa4ED5zI30K1f42EpSwXqF9nt8Hpdcuzv3cq/sbZcEnKV7rK9uA==
-----END PUBLIC KEY-----
MACBOX_PINNED_KEY

# Independently authenticate the root-owned package.
/usr/bin/openssl dgst -sha256 \
    -verify "$WORK/public.pem" \
    -signature "$WORK/release.sig" \
    "$WORK/release.manifest"

EXPECTED_SHA=$(/usr/bin/awk -F= \
    '$1 == "sha256" {print $2}' \
    "$WORK/release.manifest")

VERSION=$(/usr/bin/awk -F= \
    '$1 == "version" {print $2}' \
    "$WORK/release.manifest")

printf '%s\n' "$EXPECTED_SHA" |
    /usr/bin/grep -Eq '^[0-9a-f]{64}$'

printf '%s\n' "$VERSION" |
    /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'

ACTUAL_SHA=$(/usr/bin/shasum -a 256 \
    "$WORK/release.zip" | /usr/bin/awk '{print $1}')

test "$ACTUAL_SHA" = "$EXPECTED_SHA"

# The privileged installer must receive the exact bytes
# inspected by the unprivileged ZIP validator.
printf '%s\n' "$VALIDATED_SHA" |
    /usr/bin/grep -Eq '^[0-9a-f]{64}$'

test "$ACTUAL_SHA" = "$VALIDATED_SHA"

echo "PASS: Privileged ZIP matches inspected archive."

echo "PASS: Privileged release authentication succeeded."

# Extract only the independently authenticated package.
/bin/mkdir "$WORK/Extracted"

/usr/bin/ditto -x -k \
    "$WORK/release.zip" \
    "$WORK/Extracted"

NEW="$WORK/Extracted/MacBox.app"

validate_app "$NEW" "io.github.settloe99.MacBox"

NEW_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print CFBundleShortVersionString" \
    "$NEW/Contents/Info.plist")

test "$NEW_VERSION" = "$VERSION"

# Ordinary updates must advance the installed version.
# Legacy migration may replace an equivalent version.
if [ "$EXPECTED_ID" = "io.github.settloe99.MacBox" ]; then

    OLD_VERSION=$(/usr/libexec/PlistBuddy \
        -c "Print CFBundleShortVersionString" \
        "$TARGET/Contents/Info.plist")

    for CHECK_VERSION in "$OLD_VERSION" "$NEW_VERSION"; do
        printf '%s\n' "$CHECK_VERSION" |
            /usr/bin/grep -Eq '^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
    done

    if ! /usr/bin/awk \
        -v old="$OLD_VERSION" \
        -v new="$NEW_VERSION" '
        BEGIN {
            split(old, a, ".")
            split(new, b, ".")

            for (i = 1; i <= 3; i++) {
                if (b[i] + 0 > a[i] + 0) exit 0
                if (b[i] + 0 < a[i] + 0) exit 1
            }

            exit 1
        }
    '; then
        echo "FAIL: Protected update must advance the version."
        exit 1
    fi

    echo "PASS: Protected update advances installed version."
fi

UNSAFE=$(/usr/bin/find "$NEW" \
    ! -type f ! -type d -print)

test -z "$UNSAFE"

/usr/sbin/chown -R root:wheel "$NEW"
/bin/chmod -R a+rX,go-w "$NEW"

validate_app "$NEW" "io.github.settloe99.MacBox"

# Do not replace a running production application.
if [ "$LAB" = "/Applications" ]; then

    if /usr/bin/pgrep -f \
        '^/Applications/MacBox\.app/Contents/MacOS/MacBox([[:space:]]|$)' \
        >/dev/null; then

        echo "FAIL: MacBox is still running."
        exit 1

    else
        STATUS=$?
        test "$STATUS" = "1"
    fi

fi

# Preserve an independent backup in root-private storage.
BACKUPS=$(/usr/bin/mktemp -d \
    "$LAB/.MacBox-Legacy-backup.XXXXXX")

/usr/bin/ditto "$TARGET" "$BACKUPS/MacBox.app"

validate_app "$BACKUPS/MacBox.app" "$EXPECTED_ID"

echo "PASS: Independent original backup verified."

# Transactional replacement.
/bin/mv "$TARGET" "$PARKED"
ORIGINAL_PARKED=1

/bin/mv "$NEW" "$TARGET"
REPLACEMENT_INSTALLED=1

validate_app "$TARGET" "io.github.settloe99.MacBox"

/usr/bin/sudo -n -u "#$UID_NUMBER" \
    /usr/bin/codesign --verify --deep --strict "$TARGET"

/usr/bin/sudo -n -u "#$UID_NUMBER" \
    /bin/test -x "$TARGET/Contents/MacOS/MacBox"

echo "PASS: Installed application verified as normal user."

# Deliberate failure is available only in this laboratory.
if [ "$MODE" = "rollback" ]; then
    echo "TEST: Deliberately triggering rollback."
    exit 42
fi

if [ "$LAB" = "/Applications" ]; then

    # Switch both bootstrap context and user identity.
    # MacBox must never run as root.
    /bin/launchctl asuser "$UID_NUMBER" \
        /usr/bin/sudo -n -H -u "#$UID_NUMBER" \
        /usr/bin/open -n "$TARGET"

    echo "PASS: User-session relaunch requested."

else

    echo "PASS: Relaunch deliberately suppressed in laboratory."

fi

COMMITTED=1

echo "PASS: Protected application replacement succeeded."
echo "Independent backup: $BACKUPS/MacBox.app"
"""#.replacingOccurrences(
        of: "__MACBOX_INSTALLATION_PARENT__",
        with: installationParentPath
    )

    let result = try runAdministratorAuthorizedCommand(
        "/bin/sh",
        arguments: [
            "-c",
            script,
            "macbox-protected-lab",
            String(getuid()),
            manifest.path,
            signature.path,
            archive.path,
            mode,
            validatedSHA256,
            expectedID
        ]
    )

    print(result)
}



private func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())

    #if MACBOX_MIGRATION_LAB

    if args.count == 5,
       (args[0] == "--migrate-protected-lab" ||
        args[0] == "--update-protected-lab") {

        try runAdministratorAuthorizedInstallation(
            manifest: URL(fileURLWithPath: args[1]),
            signature: URL(fileURLWithPath: args[2]),
            archive: URL(fileURLWithPath: args[3]),
            mode: args[4],
            operation: args[0] == "--update-protected-lab"
                ? "update"
                : "migration"
        )

        return
    }

    #endif



    #if MACBOX_MIGRATION_LAB

    if args.count == 5,
       args[0] == "--migrate-legacy-shared-lab",
       let parentPID = Int32(args[1]),
       parentPID > 1 {

        try runProductionLegacyMigration(
            parentPID: parentPID,
            manifestURL: URL(fileURLWithPath: args[2]),
            signatureURL: URL(fileURLWithPath: args[3]),
            archiveURL: URL(fileURLWithPath: args[4])
        )

        return
    }

    #endif



    if args.count == 4,
       args[0] == "--preflight-legacy-migration" {

        _ = try preflightLegacyProductionMigration(
            manifestURL: URL(fileURLWithPath: args[1]),
            signatureURL: URL(fileURLWithPath: args[2]),
            archiveURL: URL(fileURLWithPath: args[3])
        )

        return
    }



    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("MacBox-ReleaseTest")

    let source = root.appendingPathComponent(
        "MacBox-UpdateTarget.app"
    )

    // Verify a production application's signature without
    // installing, modifying or launching the application.
    if args.count == 2,
       args[0] == "--verify-production-app" {

        let application = URL(
            fileURLWithPath: args[1],
            isDirectory: true
        ).standardizedFileURL

        try validateProductionApp(application)

        print("PASS: Production application authenticated.")
        return
    }

    if args.count == 3,
       args[0] == "--verify-manifest" {

        try verifyMacBoxReleaseManifest(
            manifestURL: URL(fileURLWithPath: args[1]),
            signatureURL: URL(fileURLWithPath: args[2])
        )
        return
    }

    if args.count == 4,
       args[0] == "--verify-release-package" {

        _ = try verifySignedMacBoxReleasePackage(
            manifestURL: URL(fileURLWithPath: args[1]),
            signatureURL: URL(fileURLWithPath: args[2]),
            archiveURL: URL(fileURLWithPath: args[3])
        )

        return
    }


    if args.count == 2,
       args[0] == "--validate-release-zip" {

        try validateProductionReleaseZIP(
            at: URL(fileURLWithPath: args[1])
        )
        return
    }


    #if MACBOX_MIGRATION_LAB

    if args == ["--migrate-legacy-lab"] {
        try runLegacyMigrationLaboratory()
        return
    }

    #endif

    #if !DEBUG && !MACBOX_RELEASE_TEST && !MACBOX_MIGRATION_LAB

    // Dedicated production migration command.
    // Ordinary self-updating retains its separate command.
    if args.count == 5,
       args[0] == "--migrate-legacy-production",
       let parentPID = Int32(args[1]),
       parentPID > 1 {

        let manifest = URL(
            fileURLWithPath: args[2]
        ).standardizedFileURL

        let signature = URL(
            fileURLWithPath: args[3]
        ).standardizedFileURL

        let archive = URL(
            fileURLWithPath: args[4]
        ).standardizedFileURL

        try runProductionLegacyMigration(
            parentPID: parentPID,
            manifestURL: manifest,
            signatureURL: signature,
            archiveURL: archive
        )

        return
    }

    #endif

    if args == ["--preflight"] {
        guard isRealDirectory(root) else {
            throw fail("Release-Test laboratory is missing.")
        }

        try validateApp(source, expectedBundleID: laboratoryID)

        print("PASS: Laboratory exists.")
        print("PASS: Source application identity verified.")
        print("PASS: Application executable verified.")
        print("PASS: Helper preflight complete.")
        return
    }

    if args.count == 2,
       args[0] == "--install-lab",
       let pid = Int32(args[1]) {

        try runLaboratoryInstallation(parentPID: pid)
        return
    }

    if args.count == 6,
       args[0] == "--install-production",
       let pid = Int32(args[1]) {

        let manifest = URL(
            fileURLWithPath: args[2]
        )

        let signature = URL(
            fileURLWithPath: args[3]
        )

        let archive = URL(
            fileURLWithPath: args[4]
        )

        let destination = URL(
            fileURLWithPath: args[5],
            isDirectory: true
        )

        try runProductionInstallation(
            parentPID: pid,
            manifestURL: manifest,
            signatureURL: signature,
            archiveURL: archive,
            destination: destination
        )

        return
    }

    throw fail(
        "Usage: MacBoxSelfUpdateHelper --preflight " +
        "or --install-lab <parent-pid>"
    )
}

do {
    try main()
} catch {
    fputs(
        "MacBox updater error: \(error.localizedDescription)\n",
        stderr
    )
    exit(1)
}
