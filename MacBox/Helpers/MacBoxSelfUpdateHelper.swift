import CommonCrypto
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

    guard isRealDirectory(url),
          let bundle = Bundle(url: url),
          bundle.bundleIdentifier == expectedBundleID,
          let executableName = bundle.object(
            forInfoDictionaryKey: "CFBundleExecutable"
          ) as? String,
          executableName == "MacBox"
    else {
        throw fail("Invalid or unexpected MacBox application.")
    }

    let executable = url.appendingPathComponent(
        "Contents/MacOS/MacBox"
    )

    guard fm.isExecutableFile(atPath: executable.path) else {
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

private func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())

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
