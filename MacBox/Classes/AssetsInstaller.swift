import Foundation
import ZIPFoundation
import Darwin

struct AssetsInstaller {

    enum InstallationState: Equatable {

        case missing
        case unmanaged
        case managed(sha: String)
    }

    private struct InstalledRevision: Codable {

        let repository: String
        let sha: String
        let installedAt: Date
    }

    private static let markerName =
        ".MacBox-Assets-Version.json"

    private static func fail(
        _ message: String
    ) -> NSError {

        NSError(
            domain: "MacBox.AssetsUpdater",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    private static func exists(
        _ url: URL
    ) throws -> Bool {

        var information = stat()

        let result = url.path.withCString {
            Darwin.lstat($0, &information)
        }

        if result == 0 {
            return true
        }

        if errno == ENOENT {
            return false
        }

        throw fail(
            "Cannot inspect assets path: \(url.path)"
        )
    }

    private static func requireDirectory(
        _ url: URL
    ) throws {

        let fm = FileManager.default

        guard url.path ==
                url.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: url.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeDirectory else {

            throw fail(
                "Missing or unsafe assets directory: \(url.path)"
            )
        }
    }

    private static func requireFile(
        _ url: URL
    ) throws {

        let fm = FileManager.default

        guard url.path ==
                url.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: url.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular else {

            throw fail(
                "Missing or unsafe assets file: \(url.path)"
            )
        }
    }

    // Select the managed installation location.
    // This function does not create any directories.
    static func managedDestination() throws -> URL {

        let fm = FileManager.default

        #if MACBOX_RELEASE_TEST

        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-ReleaseTest",
                isDirectory: true
            )

        let laboratory = root.appendingPathComponent(
            "Assets-Lab",
            isDirectory: true
        )

        try requireDirectory(root)
        try requireDirectory(laboratory)

        return laboratory.appendingPathComponent(
            "assets",
            isDirectory: true
        )

        #elseif DEBUG

        throw fail(
            "Assets installation is disabled in Debug builds."
        )

        #else

        guard let support = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {

            throw fail(
                "Application Support directory unavailable."
            )
        }

        return support.appendingPathComponent(
            "86Box/assets",
            isDirectory: true
        ).standardizedFileURL

        #endif
    }

    static func installationState(
        at destination: URL
    ) throws -> InstallationState {

        guard try exists(destination) else {
            return .missing
        }

        try requireDirectory(destination)

        let marker = destination.appendingPathComponent(
            markerName
        )

        guard try exists(marker) else {
            return .unmanaged
        }

        try requireFile(marker)

        let revision = try JSONDecoder().decode(
            InstalledRevision.self,
            from: Data(contentsOf: marker)
        )

        guard revision.repository == "86Box/assets",
              AssetsRelease.validSHA(revision.sha) else {

            throw fail(
                "Invalid installed assets revision metadata."
            )
        }

        try validateInstalledContents(destination)

        return .managed(sha: revision.sha)
    }

    private static func validateInstalledContents(
        _ directory: URL
    ) throws {

        let fm = FileManager.default

        try requireDirectory(directory)

        let sounds = directory.appendingPathComponent(
            "sounds",
            isDirectory: true
        )

        try requireDirectory(sounds)

        var enumerationError: Error?
        var containsSoundFile = false

        guard let entries = fm.enumerator(
            atPath: sounds.path
        ) else {

            throw fail(
                "Cannot inspect installed sound assets."
            )
        }

        while let relative = entries.nextObject() as? String {

            let entry = sounds.appendingPathComponent(relative)

            do {

                let attributes = try fm.attributesOfItem(
                    atPath: entry.path
                )

                let type = attributes[.type]
                    as? FileAttributeType

                if type == .typeDirectory {

                    try requireDirectory(entry)

                } else if type == .typeRegular {

                    try requireFile(entry)

                    if let size = attributes[.size] as? NSNumber,
                       size.uint64Value > 0 {

                        containsSoundFile = true
                    }

                } else {

                    throw fail(
                        "Unsupported installed asset: \(relative)"
                    )
                }

            } catch {

                enumerationError = error
                break
            }
        }

        if let error = enumerationError {
            throw error
        }

        guard containsSoundFile else {

            throw fail(
                "The installed asset pack contains no sound files."
            )
        }
    }

    // Check the archive before extracting any files.
    private static func validateArchive(
        _ archiveURL: URL,
        expectedSHA: String
    ) throws -> String {

        try requireFile(archiveURL)

        guard AssetsRelease.validSHA(expectedSHA),
              let archive = try? Archive(
                url: archiveURL,
                accessMode: .read
              ) else {

            throw fail(
                "Invalid assets ZIP archive."
            )
        }

        // GitHub codeload archives use this exact root.
        let expectedRoot = "assets-" + expectedSHA

        let maximumSize: UInt64 =
            512 * 1024 * 1024

        var count = 0
        var totalSize: UInt64 = 0

        var seen = Set<String>()

        var pathSpellings: [String: String] = [:]
        var filePaths = Set<String>()
        var directoryPaths = Set<String>()

        var containsSounds = false

        for entry in archive {

            count += 1

            guard count <= 10_000,
                  entry.type == .file ||
                    entry.type == .directory else {

                throw fail(
                    "Unsafe assets archive entry."
                )
            }

            let path = entry.path

            guard !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !path.contains("\0") else {

                throw fail(
                    "Unsafe assets archive filename."
                )
            }

            let trimmed = path.hasSuffix("/")
                ? String(path.dropLast())
                : path

            let parts = trimmed.split(
                separator: "/",
                omittingEmptySubsequences: false
            )

            guard let first = parts.first,
                  String(first) == expectedRoot,
                  parts.allSatisfy({

                      !$0.isEmpty &&
                      $0 != "." &&
                      $0 != ".."

                  }) else {

                throw fail(
                    "Unexpected assets archive path."
                )
            }

            let canonical = trimmed
                .precomposedStringWithCanonicalMapping
                .lowercased()

            guard seen.insert(canonical).inserted else {

                throw fail(
                    "Duplicate assets archive entry."
                )
            }

            // Reject case and Unicode spelling collisions
            // including implicitly created parent directories.
            for index in 1...parts.count {

                let spelling = parts.prefix(index)
                    .joined(separator: "/")

                let key = spelling
                    .precomposedStringWithCanonicalMapping
                    .lowercased()

                if let existing = pathSpellings[key],
                   existing != spelling {

                    throw fail(
                        "Conflicting assets archive paths."
                    )
                }

                pathSpellings[key] = spelling

                if index < parts.count ||
                    entry.type == .directory {

                    directoryPaths.insert(key)

                } else {

                    filePaths.insert(key)
                }
            }

            guard entry.uncompressedSize <= maximumSize,
                  totalSize <= maximumSize -
                    entry.uncompressedSize else {

                throw fail(
                    "Assets archive exceeds the size limit."
                )
            }

            totalSize += entry.uncompressedSize

            if entry.type == .file,
               parts.count >= 3,
               parts[1] == "sounds",
               entry.uncompressedSize > 0 {

                containsSounds = true
            }

            if parts.count >= 2,
               parts[1].lowercased() ==
                    markerName.lowercased() {

                throw fail(
                    "Archive contains reserved MacBox metadata."
                )
            }
        }

        guard count > 0,
              containsSounds,
              filePaths.isDisjoint(with: directoryPaths) else {

            throw fail(
                "Assets archive is incomplete or inconsistent."
            )
        }

        return expectedRoot
    }

    private static func rename(
        from source: URL,
        to destination: URL,
        flags: UInt32
    ) throws {

        let result = source.path.withCString { oldPath in

            destination.path.withCString { newPath in

                renamex_np(
                    oldPath,
                    newPath,
                    flags
                )
            }
        }

        guard result == 0 else {

            let errorCode = errno

            throw fail(
                "Assets installation failed: " +
                String(cString: strerror(errorCode))
            )
        }
    }

    // Install a verified revision using private staging.
    // The previous installation is retained after updates.
    //
    // beforeCommit permits deterministic failure testing.
    @discardableResult
    static func install(
        archiveURL: URL,
        release: AssetsRelease,
        destination requestedDestination: URL,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> URL? {

        let fm = FileManager.default

        let destination =
            requestedDestination.standardizedFileURL

        let parent = destination
            .deletingLastPathComponent()

        guard destination.lastPathComponent == "assets",
              destination.path ==
                destination.resolvingSymlinksInPath().path else {

            throw fail(
                "Unsafe assets installation destination."
            )
        }

        let previous = try installationState(
            at: destination
        )

        guard previous != .unmanaged else {

            throw fail(
                "An unmanaged asset collection already exists. " +
                "MacBox will not overwrite it."
            )
        }

        try requireFile(archiveURL)

        let archiveAttributes = try fm.attributesOfItem(
            atPath: archiveURL.path
        )

        guard let size = archiveAttributes[.size] as? NSNumber,
              size.uint64Value <= 256 * 1024 * 1024 else {

            throw fail(
                "Assets ZIP exceeds the download size limit."
            )
        }

        guard parent.path ==
                parent.resolvingSymlinksInPath().path else {

            throw fail(
                "Unsafe assets installation parent."
            )
        }

        try fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        try requireDirectory(parent)

        let identifier = UUID().uuidString

        let workspace = parent.appendingPathComponent(
            ".MacBox-Assets-transaction-\(identifier)",
            isDirectory: true
        )

        try fm.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        var retainWorkspace = false

        defer {

            if !retainWorkspace {
                try? fm.removeItem(at: workspace)
            }
        }

        let localArchive = workspace
            .appendingPathComponent("download.zip")

        try fm.copyItem(
            at: archiveURL,
            to: localArchive
        )

        let root = try validateArchive(
            localArchive,
            expectedSHA: release.sha
        )

        let extracted = workspace.appendingPathComponent(
            "extracted",
            isDirectory: true
        )

        try fm.unzipItem(
            at: localArchive,
            to: extracted
        )

        let staged = extracted.appendingPathComponent(
            root,
            isDirectory: true
        )

        try validateInstalledContents(staged)

        let marker = staged.appendingPathComponent(
            markerName
        )

        let revision = InstalledRevision(
            repository: "86Box/assets",
            sha: release.sha,
            installedAt: Date()
        )

        try JSONEncoder().encode(revision).write(
            to: marker,
            options: .withoutOverwriting
        )

        guard try installationState(at: staged) ==
                    .managed(sha: release.sha) else {

            throw fail(
                "Prepared assets failed verification."
            )
        }

        // Remove the downloaded archive before committing.
        try fm.removeItem(at: localArchive)

        // Test injection occurs before the final checks.
        try beforeCommit?()

        try requireDirectory(parent)

        guard try installationState(at: destination) ==
                    previous else {

            throw fail(
                "Existing assets changed during preparation."
            )
        }

        switch previous {

        case .missing:

            // Never overwrite a newly created destination.
            try rename(
                from: staged,
                to: destination,
                flags: UInt32(RENAME_EXCL)
            )

            return nil

        case .managed:

            // Preserve the old installation inside the
            // private workspace when exchanging directories.
            //
            // Retain it even if an unexpected error occurs.
            retainWorkspace = true

            try rename(
                from: staged,
                to: destination,
                flags: UInt32(RENAME_SWAP)
            )

            // No fallible operations after the exchange.
            // The old asset collection remains at staged.
            return staged

        case .unmanaged:

            throw fail(
                "Unmanaged assets cannot be replaced."
            )
        }
    }
}

extension AssetsInstaller {

    enum UpdateStatus: Equatable {

        case install(AssetsRelease)

        case update(
            release: AssetsRelease,
            installedSHA: String
        )

        case current(AssetsRelease)
        case bundled(URL)
        case externallyInstalled(URL)
    }

    // Detect assets included with an emulator application
    // without modifying its signed application bundle.
    private static func bundledAssets(
        in emulatorURL: URL?
    ) -> URL? {

        guard let emulatorURL = emulatorURL,
              let bundle = Bundle(url: emulatorURL),
              bundle.bundleIdentifier == "net.86Box.86Box" else {

            return nil
        }

        var candidates: [URL] = [
            emulatorURL.appendingPathComponent(
                "assets",
                isDirectory: true
            )
        ]

        if let resources = bundle.resourceURL {

            candidates.append(
                resources.appendingPathComponent(
                    "assets",
                    isDirectory: true
                )
            )
        }

        if let executable = bundle.executableURL {

            candidates.append(
                executable.deletingLastPathComponent()
                    .appendingPathComponent(
                        "assets",
                        isDirectory: true
                    )
            )
        }

        for candidate in candidates {

            let directory = candidate.standardizedFileURL

            if (try? validateInstalledContents(directory)) != nil {
                return directory
            }
        }

        return nil
    }

    // Determine the appropriate Version Manager state.
    static func checkForUpdate(
        channel: AssetsRelease.Channel,
        emulatorURL: URL?
    ) async throws -> UpdateStatus {

        let destination = try managedDestination()

        let installed = try installationState(
            at: destination
        )

        // Never replace an externally managed collection.
        if installed == .unmanaged {

            try validateInstalledContents(destination)

            return .externallyInstalled(destination)
        }

        // Stable emulator releases may already include
        // everything required for drive audio.
        if case .stable = channel,
           let bundled = bundledAssets(in: emulatorURL) {

            return .bundled(bundled)
        }

        #if !MACBOX_RELEASE_TEST && !DEBUG

        // Recognise system-wide assets without changing them.
        if installed == .missing {

            let systemAssets = URL(
                fileURLWithPath:
                    "/Library/Application Support/86Box/assets",
                isDirectory: true
            )

            if try exists(systemAssets) {

                try validateInstalledContents(systemAssets)

                return .externallyInstalled(systemAssets)
            }
        }

        #endif

        let remote = try await AssetsRelease.fetch(
            channel: channel
        )

        switch installed {

        case .missing:

            return .install(remote)

        case .managed(let sha):

            if sha == remote.sha {

                return .current(remote)

            } else {

                return .update(
                    release: remote,
                    installedSHA: sha
                )
            }

        case .unmanaged:

            return .externallyInstalled(destination)
        }
    }

    private static func requireNoRunningEmulators() throws {

        let process = Process()

        process.executableURL = URL(
            fileURLWithPath: "/usr/bin/pgrep"
        )

        process.arguments = ["-ix", "86Box"]

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 1 else {

            throw fail(
                "Close all running 86Box instances " +
                "before installing or updating assets."
            )
        }
    }

        // Report actual download progress without coupling
    // the Assets installer to the Version Manager UI.
    private final class AssetsDownloadDelegate:
        NSObject,
        URLSessionDownloadDelegate,
        @unchecked Sendable {

        private let progress: @Sendable (Double?) -> Void

        private var continuation:
            CheckedContinuation<(URL, URLResponse), Error>?

        private var result: Result<(URL, URLResponse), Error>?

        private let taskLock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false

        init(
            progress: @escaping @Sendable (Double?) -> Void
        ) {

            self.progress = progress
            super.init()
        }

        func start(
            request: URLRequest,
            continuation: CheckedContinuation<
                (URL, URLResponse),
                Error
            >
        ) {

            self.continuation = continuation

            let session = URLSession(
                configuration: .default,
                delegate: self,
                delegateQueue: nil
            )

            let downloadTask = session.downloadTask(
                with: request
            )

            taskLock.lock()

            task = downloadTask
            let wasCancelled = cancelled

            taskLock.unlock()

            downloadTask.resume()

            if wasCancelled {
                downloadTask.cancel()
            }
        }

        func cancel() {

            taskLock.lock()

            cancelled = true
            let activeTask = task

            taskLock.unlock()

            activeTask?.cancel()
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64,
            totalBytesExpectedToWrite: Int64
        ) {

            guard totalBytesExpectedToWrite > 0 else {

                progress(nil)
                return
            }

            let fraction = Double(totalBytesWritten)
                / Double(totalBytesExpectedToWrite)

            progress(min(max(fraction, 0), 1))
        }

        func urlSession(
            _ session: URLSession,
            downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {

            // URLSession removes its temporary download
            // when this delegate method returns.
            let destination = FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "MacBox-Assets-\(UUID().uuidString).zip"
                )

            do {

                guard let response = downloadTask.response else {

                    throw NSError(
                        domain: "MacBox.Assets.Download",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Assets download response unavailable."
                        ]
                    )
                }

                try FileManager.default.moveItem(
                    at: location,
                    to: destination
                )

                result = .success((destination, response))

                progress(1.0)

            } catch {

                try? FileManager.default.removeItem(
                    at: destination
                )

                result = .failure(error)
            }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didCompleteWithError error: Error?
        ) {

            defer {

                continuation = nil
                result = nil

                taskLock.lock()
                self.task = nil
                taskLock.unlock()

                session.finishTasksAndInvalidate()
            }

            guard let continuation = continuation else {
                return
            }

            if let error = error {

                if case .success(let download)? = result {

                    try? FileManager.default.removeItem(
                        at: download.0
                    )
                }

                continuation.resume(throwing: error)

            } else if let result = result {

                continuation.resume(with: result)

            } else {

                continuation.resume(
                    throwing: NSError(
                        domain: "MacBox.Assets.Download",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Assets download did not produce a file."
                        ]
                    )
                )
            }
        }
    }

    private static func downloadWithProgress(
        request: URLRequest,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> (URL, URLResponse) {

        let delegate = AssetsDownloadDelegate(
            progress: progress
        )

        return try await withTaskCancellationHandler(
            operation: {

                try await withCheckedThrowingContinuation {
                    continuation in

                    delegate.start(
                        request: request,
                        continuation: continuation
                    )
                }
            },
            onCancel: {

                delegate.cancel()
            }
        )
    }

    // Dispose of the previous installation only after
    // verifying that the new installation is valid.
    static func removeVerifiedUpdateBackup(
        _ backupURL: URL,
        for status: UpdateStatus
    ) throws {

        guard case .update(let release, let installedSHA) = status else {

            throw fail(
                "Backup cleanup requires a completed assets update."
            )
        }

        let fm = FileManager.default

        let destination = try managedDestination()
            .standardizedFileURL

        let parent = destination.deletingLastPathComponent()

        let backup = backupURL.standardizedFileURL
        let extracted = backup.deletingLastPathComponent()
        let workspace = extracted.deletingLastPathComponent()

        let prefix = ".MacBox-Assets-transaction-"
        let workspaceName = workspace.lastPathComponent

        guard workspace.deletingLastPathComponent().path
                    == parent.path,
              extracted.lastPathComponent == "extracted",
              workspaceName.hasPrefix(prefix),
              UUID(
                uuidString: String(
                    workspaceName.dropFirst(prefix.count)
                )
              ) != nil else {

            throw fail(
                "Unexpected assets backup location."
            )
        }

        // Never follow symbolic links during cleanup.
        try requireDirectory(parent)
        try requireDirectory(destination)
        try requireDirectory(workspace)
        try requireDirectory(extracted)
        try requireDirectory(backup)

        guard workspace.path ==
                workspace.resolvingSymlinksInPath().path,
              extracted.path ==
                extracted.resolvingSymlinksInPath().path,
              backup.path ==
                backup.resolvingSymlinksInPath().path else {

            throw fail(
                "Unsafe assets backup location."
            )
        }

        // Verify both the new installation and the
        // previous installation before removing anything.
        try validateInstalledContents(destination)

        guard try installationState(at: destination) ==
                    .managed(sha: release.sha),
              try installationState(at: backup) ==
                    .managed(sha: installedSHA) else {

            throw fail(
                "Assets backup cleanup verification failed."
            )
        }

        // Refuse cleanup if the workspace contains
        // anything other than the expected backup.
        guard try fm.contentsOfDirectory(
                    atPath: workspace.path
              ) == ["extracted"],
              try fm.contentsOfDirectory(
                    atPath: extracted.path
              ) == [backup.lastPathComponent] else {

            throw fail(
                "Unexpected files in assets transaction workspace."
            )
        }

        try fm.removeItem(at: workspace)

        NSLog(
            "MacBox: Verified assets transaction workspace removed."
        )
    }

    // Download precisely the revision selected by the
    // update check, then perform the verified transaction.
    @discardableResult
    static func downloadAndInstall(
        _ status: UpdateStatus,
        progress: (@Sendable (Double?) -> Void)? = nil
    ) async throws -> URL? {

        let release: AssetsRelease

        let expectedInstallation: InstallationState

        switch status {

        case .install(let selectedRelease):

            release = selectedRelease
            expectedInstallation = .missing

        case .update(let selectedRelease, let installedSHA):

            release = selectedRelease

            expectedInstallation = .managed(
                sha: installedSHA
            )

        default:

            throw fail(
                "No asset installation or update is required."
            )
        }

        let destination = try managedDestination()

        try requireNoRunningEmulators()

        guard try installationState(at: destination) ==
                    expectedInstallation else {

            throw fail(
                "The installed assets have changed. " +
                "Check for updates again before retrying."
            )
        }

        let downloadURL = try release.archiveURL()

        var request = URLRequest(url: downloadURL)

        request.timeoutInterval = 60

        request.cachePolicy =
            .reloadIgnoringLocalCacheData

        request.setValue(
            "MacBox",
            forHTTPHeaderField: "User-Agent"
        )

                let downloadedFile: URL
        let response: URLResponse

        if let progress = progress {

            (downloadedFile, response) =
                try await downloadWithProgress(
                    request: request,
                    progress: progress
                )

        } else {

            (downloadedFile, response) =
                try await URLSession.shared.download(
                    for: request
                )
        }

        let fm = FileManager.default

        defer {
            try? fm.removeItem(at: downloadedFile)
        }

        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme == "https",
              http.url?.host == "codeload.github.com",
              http.url?.path == downloadURL.path else {

            throw fail(
                "The assets download returned " +
                "an unexpected response."
            )
        }

        try Task.checkCancellation()

        // Recheck the installation after downloading.
        // The emulator may have been started in the meantime.
        try requireNoRunningEmulators()

        guard try installationState(at: destination) ==
                    expectedInstallation else {

            throw fail(
                "The installed assets changed during download."
            )
        }

        return try install(
            archiveURL: downloadedFile
                .resolvingSymlinksInPath(),
            release: release,
            destination: destination,
            beforeCommit: {

                try Task.checkCancellation()

                // Recheck immediately before publishing
                // the prepared asset collection.
                try requireNoRunningEmulators()

                guard try installationState(at: destination) ==
                            expectedInstallation else {

                    throw fail(
                        "The installed assets changed " +
                        "during preparation."
                    )
                }
            }
        )
    }
}
