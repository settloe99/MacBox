import Foundation
import Darwin
import Security

private let fm = FileManager.default
private let laboratoryID = "io.github.settloe99.MacBoxReleaseTest"
private let productionID = "io.github.settloe99.MacBox"

// Production updates remain disabled until we have verified
// our own Apple Developer ID signing identity.
private let trustedProductionTeamID: String? = nil

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

private func validateProductionApp(_ url: URL) throws {

    // Never accept production updates without a verified
    // Apple Developer ID Team ID.
    guard let teamID = trustedProductionTeamID,
          teamID.range(
            of: "^[A-Z0-9]{10}$",
            options: .regularExpression
          ) != nil else {

        throw fail(
            "Production self-updates are disabled until a " +
            "trusted Developer ID signing identity is configured."
        )
    }

    // Verify the application bundle structure and identity.
    try validateApp(
        url,
        expectedBundleID: productionID
    )

    // Require an Apple-issued Developer ID Application
    // certificate belonging to our trusted development team.
    let requirementText = """
    anchor apple generic and
    identifier "\(productionID)" and
    certificate leaf[subject.OU] = "\(teamID)" and
    certificate 1[field.1.2.840.113635.100.6.2.6] exists and
    certificate leaf[field.1.2.840.113635.100.6.1.13] exists
    """

    var requirement: SecRequirement?

    let requirementStatus = SecRequirementCreateWithString(
        requirementText as CFString,
        SecCSFlags(rawValue: 0),
        &requirement
    )

    guard requirementStatus == errSecSuccess,
          let requiredSignature = requirement else {

        throw fail(
            "Could not create the production signing requirement."
        )
    }

    // Load the application as a static code object.
    var staticCode: SecStaticCode?

    let creationStatus = SecStaticCodeCreateWithPath(
        url as CFURL,
        SecCSFlags(rawValue: 0),
        &staticCode
    )

    guard creationStatus == errSecSuccess,
          let applicationCode = staticCode else {

        throw fail(
            "Could not inspect the production application signature."
        )
    }

    // Verify the signature and application resources.
    let validationStatus = SecStaticCodeCheckValidity(
        applicationCode,
        SecCSFlags(rawValue: 0),
        requiredSignature
    )

    guard validationStatus == errSecSuccess else {
        throw fail(
            "The production application failed Developer ID " +
            "signature verification. Installation was rejected."
        )
    }

    print("PASS: Production application signature verified.")
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

private func runProductionInstallation(
    parentPID: pid_t,
    source: URL,
    destination: URL
) throws {

    let home = fm.homeDirectoryForCurrentUser.standardizedFileURL

    let stagingRoot = home.appendingPathComponent(
        "Library/Caches/io.github.settloe99.MacBox/StagedUpdates",
        isDirectory: true
    ).standardizedFileURL

    let candidate = source.standardizedFileURL
    let target = destination.standardizedFileURL

    let candidateParent = candidate.deletingLastPathComponent()
    let targetParent = target.deletingLastPathComponent()

    // Only accept a staged application from our private
    // update directory.
    guard isRealDirectory(stagingRoot),
          isRealDirectory(candidateParent),
          candidateParent.deletingLastPathComponent() == stagingRoot,
          UUID(uuidString: candidateParent.lastPathComponent) != nil,
          candidate.lastPathComponent == "MacBox.app",
          candidate.path == candidate.resolvingSymlinksInPath().path
    else {
        throw fail("Unsafe production update source.")
    }

    // Only replace an existing, genuine MacBox application.
    // Never accept an arbitrary application destination.
    guard target.lastPathComponent == "MacBox.app",
          isRealDirectory(targetParent),
          target.path == target.resolvingSymlinksInPath().path,
          target != candidate
    else {
        throw fail("Unsafe production application destination.")
    }

    // This enforces the trusted Developer ID requirement.
    // Currently it deliberately rejects ALL production updates
    // because trustedProductionTeamID has not been configured.
    try validateProductionApp(candidate)
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
    try fm.copyItem(at: candidate, to: staged)

    // Verify the copied application again.
    try validateProductionApp(staged)

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

    if args.count == 4,
       args[0] == "--install-production",
       let pid = Int32(args[1]) {

        let source = URL(
            fileURLWithPath: args[2],
            isDirectory: true
        )

        let destination = URL(
            fileURLWithPath: args[3],
            isDirectory: true
        )

        try runProductionInstallation(
            parentPID: pid,
            source: source,
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
