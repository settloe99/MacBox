import Foundation
import Darwin

private let fm = FileManager.default
private let expectedID = "io.github.settloe99.MacBoxReleaseTest"

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

private func validateApp(_ url: URL) throws {
    guard isRealDirectory(url),
          let bundle = Bundle(url: url),
          bundle.bundleIdentifier == expectedID,
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

    try validateApp(source)

    let originalExists = fm.fileExists(
        atPath: destination.path
    )

    if originalExists {
        try validateApp(destination)
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
    try validateApp(staged)

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

        try validateApp(destination)
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

private func main() throws {
    let args = Array(CommandLine.arguments.dropFirst())

    let root = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("MacBox-ReleaseTest")

    let source = root.appendingPathComponent(
        "MacBox-UpdateTarget.app"
    )

    if args == ["--preflight"] {
        guard isRealDirectory(root) else {
            throw fail("Release-Test laboratory is missing.")
        }

        try validateApp(source)

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
