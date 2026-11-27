//
//  AppDelegate.swift
//  MacBox
//
//  Created by Moonif on 4/9/23.
//

import Cocoa
import CryptoKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    // Authenticated release prepared for legacy migration.
    // Retained until the user approves installation.
    private var preparedLegacyMigrationZIP: URL?

    func applicationWillFinishLaunching(_ notification: Notification) {

        #if !DEBUG && !MACBOX_RELEASE_TEST
        migrateLegacyPreferencesIfNeeded()
        #endif

    }

    // Preserve original MacBox settings without replacing
    // preferences already configured in our maintained fork.
    private func migrateLegacyPreferencesIfNeeded() {

        let defaults = UserDefaults.standard
        let domain = "io.github.settloe99.MacBox"
        let migrationKey = "MacBoxLegacyPreferencesMigratedV1"

        guard Bundle.main.bundleIdentifier == domain,
              !defaults.bool(forKey: migrationKey),
              let legacy = defaults.persistentDomain(
                forName: "Moonif.MacBox"
              ) else {
            return
        }

        let existing = defaults.persistentDomain(
            forName: domain
        ) ?? [:]

        let supportedKeys = [
            "appAppearance",
            "disableScreensaver",
            "homeDirPath",
            "emulatorDefaultPath",
            "emulatorUpdateChannel",
            "lastSelectedVM",
            "romsShaVersion"
        ]

        for key in supportedKeys {

            guard existing[key] == nil,
                  let value = legacy[key] else {
                continue
            }

            defaults.set(value, forKey: key)

            NSLog(
                "MacBoxMigration: Preserved legacy preference %@",
                key
            )
        }

        defaults.set(true, forKey: migrationKey)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        // Identify an existing original MacBox installation.
        // The migration is not initiated until the user
        // explicitly approves it.
        #if (!DEBUG && !MACBOX_RELEASE_TEST) || MACBOX_MIGRATION_UI_TEST
        DispatchQueue.main.async { [weak self] in
            if self?.reportMacBoxUpdateFailure() != true &&
               self?.reportLegacyMigrationResult() != true {
                self?.checkForLegacyMacBoxInstallation()
            }
        }
        #endif
    }


    // Detect the original Moonif application using its
    // actual on-disk bundle identifier.
    // This is a read-only check.
    private func checkForLegacyMacBoxInstallation() {

        #if MACBOX_MIGRATION_UI_TEST
        let expectedIdentifier = "io.github.settloe99.MacBoxReleaseTest"
        #else
        let expectedIdentifier = "io.github.settloe99.MacBox"
        #endif

        guard Bundle.main.bundleIdentifier ==
                expectedIdentifier else {
            return
        }

        let original = URL(
            fileURLWithPath: "/Applications/MacBox.app",
            isDirectory: true
        ).standardizedFileURL

        // Never treat our own running application as legacy.
        guard Bundle.main.bundleURL.standardizedFileURL != original,
              original.path ==
                original.resolvingSymlinksInPath().path else {
            return
        }

        let plist = original.appendingPathComponent(
            "Contents/Info.plist"
        )

        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let info = object as? [String: Any],
              info["CFBundleIdentifier"] as? String ==
                "Moonif.MacBox",
              info["CFBundleExecutable"] as? String ==
                "MacBox" else {
            return
        }

        NSLog(
            "MacBoxMigration: Original Moonif MacBox detected at %@",
            original.path
        )

        let confirmation = NSAlert()
        confirmation.alertStyle = .informational
        confirmation.messageText = "Migrate to maintained MacBox?"
        confirmation.informativeText = """
        An installation of the original Moonif MacBox was found.

        Our maintained fork can replace the original application
        while preserving your virtual machines and configuration.

        The original application will be backed up.

        First, MacBox will check the latest published release.
        Nothing will be installed at this stage.
        """

        confirmation.addButton(withTitle: "Check Release")
        confirmation.addButton(withTitle: "Not Now")

        guard confirmation.runModal() ==
                .alertFirstButtonReturn else {
            return
        }

        discoverLegacyMigrationRelease { [weak self] result in
            DispatchQueue.main.async {
                guard self != nil else { return }

                let alert = NSAlert()

                switch result {
                case .success(let release):
                    self?.stageAndAuthenticateMigrationRelease(
                        release
                    ) { result in

                        let resultAlert = NSAlert()

                        switch result {
                        case .success(let stagedZIP):
                            self?.preparedLegacyMigrationZIP = stagedZIP

                            self?.confirmLegacyMigrationInstallation(
                                zip: stagedZIP,
                                releaseVersion: release.version
                            )
                            return

                        case .failure(let error):
                            resultAlert.alertStyle = .warning
                            resultAlert.messageText =
                                "Migration preparation failed"
                            resultAlert.informativeText =
                                error.localizedDescription
                        }

                        resultAlert.addButton(withTitle: "OK")
                        resultAlert.runModal()
                    }
                    return

                case .failure(let error):
                    alert.alertStyle = .warning
                    alert.messageText = "Migration release unavailable"
                    alert.informativeText = error.localizedDescription
                }

                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }


    // Release metadata for the one-time Moonif migration.
    private struct MigrationRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [MigrationAsset]
    }

    private struct MigrationAsset: Decodable {
        let name: String
        let browser_download_url: String
        let digest: String?
    }

    private struct MigrationReleaseDetails {
        let version: String
        let archiveURL: URL
        let manifestURL: URL
        let signatureURL: URL
        let expectedSHA256: String
    }

    // Discover the latest authenticated release's assets.
    // This function performs no installation or filesystem writes.
    private func discoverLegacyMigrationRelease(
        completion: @escaping (
            Result<MigrationReleaseDetails, Error>
        ) -> Void
    ) {

        func failure(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.LegacyMigration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        guard let endpoint = URL(
            string:
                "https://api.github.com/repos/settloe99/MacBox/releases/latest"
        ) else {
            completion(.failure(
                failure("Invalid GitHub release endpoint.")
            ))
            return
        }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )

        request.setValue(
            "application/vnd.github+json",
            forHTTPHeaderField: "Accept"
        )

        request.setValue(
            "MacBox",
            forHTTPHeaderField: "User-Agent"
        )

        URLSession.shared.dataTask(with: request) {
            data, response, error in

            do {
                if let error = error {
                    throw error
                }

                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let data = data,
                      !data.isEmpty,
                      data.count <= 1024 * 1024 else {
                    throw failure(
                        "GitHub release metadata is unavailable."
                    )
                }

                let release = try JSONDecoder().decode(
                    MigrationRelease.self,
                    from: data
                )

                guard !release.draft,
                      !release.prerelease,
                      release.tag_name.range(
                        of: "^[0-9]+\\.[0-9]+\\.[0-9]+$",
                        options: .regularExpression
                      ) != nil else {
                    throw failure(
                        "No suitable published MacBox release."
                    )
                }

                let version = release.tag_name

                let zipName = "MacBox-v\(version).zip"
                let manifestName = "MacBox-release.manifest"
                let signatureName = "MacBox-release.manifest.sig"

                func asset(_ name: String) throws -> MigrationAsset {
                    let matches = release.assets.filter {
                        $0.name == name
                    }

                    guard matches.count == 1,
                          let selected = matches.first else {
                        throw failure(
                            "Missing or duplicate release asset: \(name)"
                        )
                    }

                    return selected
                }

                func verifiedURL(
                    for asset: MigrationAsset
                ) throws -> URL {

                    guard let url = URL(
                            string: asset.browser_download_url
                          ),
                          url.scheme?.lowercased() == "https",
                          url.host?.lowercased() == "github.com",
                          url.path ==
                            "/settloe99/MacBox/releases/download/\(version)/\(asset.name)"
                    else {
                        throw failure(
                            "Unexpected GitHub asset location."
                        )
                    }

                    return url
                }

                let zip = try asset(zipName)
                let manifest = try asset(manifestName)
                let signature = try asset(signatureName)

                guard let digest = zip.digest?.lowercased(),
                      digest.range(
                        of: "^sha256:[0-9a-f]{64}$",
                        options: .regularExpression
                      ) != nil else {
                    throw failure(
                        "Release ZIP has no valid SHA-256 digest."
                    )
                }

                let details = MigrationReleaseDetails(
                    version: version,
                    archiveURL: try verifiedURL(for: zip),
                    manifestURL: try verifiedURL(for: manifest),
                    signatureURL: try verifiedURL(for: signature),
                    expectedSHA256: String(digest.dropFirst(7))
                )

                completion(.success(details))

            } catch {
                completion(.failure(error))
            }
        }.resume()
    }


    // Download and authenticate the migration assets.
    // This does not install or replace an application.
    private func stageAndAuthenticateMigrationRelease(
        _ release: MigrationReleaseDetails,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {

        func failure(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.LegacyMigration",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        Task {
            let fm = FileManager.default

            let cache = fm.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first!

            let staging = cache.appendingPathComponent(
                "io.github.settloe99.MacBox/StagedUpdates",
                isDirectory: true
            ).standardizedFileURL

            let identifier = UUID().uuidString

            let base = staging.appendingPathComponent(identifier)
            let zip = base.appendingPathExtension("zip")
            let manifest = base.appendingPathExtension("manifest")
            let signature = base.appendingPathExtension("sig")

            let stagedFiles = [zip, manifest, signature]

            do {
                try fm.createDirectory(
                    at: staging,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                guard staging.path ==
                        staging.resolvingSymlinksInPath().path,
                      stagedFiles.allSatisfy({
                        !fm.fileExists(atPath: $0.path)
                      }) else {
                    throw failure("Unsafe migration staging directory.")
                }

                try fm.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: staging.path
                )

                // Download the ZIP to a temporary location first.
                let (temporaryZIP, zipResponse) =
                    try await URLSession.shared.download(
                        from: release.archiveURL
                    )

                guard let http = zipResponse as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    throw failure("Release ZIP download failed.")
                }

                let attributes = try fm.attributesOfItem(
                    atPath: temporaryZIP.path
                )

                guard let size = attributes[.size] as? NSNumber,
                      size.int64Value > 0,
                      size.int64Value <= 512 * 1024 * 1024 else {
                    throw failure("Invalid release ZIP size.")
                }

                try fm.moveItem(at: temporaryZIP, to: zip)

                // Check the checksum advertised by GitHub.
                // The signed manifest will be checked separately.
                let zipData = try Data(
                    contentsOf: zip,
                    options: .mappedIfSafe
                )

                let actualDigest = SHA256.hash(data: zipData)
                    .map { String(format: "%02x", $0) }
                    .joined()

                guard actualDigest == release.expectedSHA256 else {
                    throw failure("GitHub ZIP checksum mismatch.")
                }

                // Download both authentication sidecars.
                for (remote, local) in [
                    (release.manifestURL, manifest),
                    (release.signatureURL, signature)
                ] {
                    let (data, response) =
                        try await URLSession.shared.data(from: remote)

                    guard let http = response as? HTTPURLResponse,
                          http.statusCode == 200,
                          !data.isEmpty,
                          data.count <= 4096 else {
                        throw failure(
                            "Release authentication asset unavailable."
                        )
                    }

                    try data.write(to: local, options: .atomic)
                }

                for file in stagedFiles {
                    try fm.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: file.path
                    )
                }

                // Verify using the compiled public verification key
                // in the application's existing updater helper.
                let helper = Bundle.main.bundleURL
                    .appendingPathComponent(
                        "Contents/Helpers/MacBoxSelfUpdateHelper"
                    )

                guard fm.isExecutableFile(atPath: helper.path) else {
                    throw failure("Embedded migration verifier missing.")
                }

                let commands = [
                    [
                        "--verify-release-package",
                        manifest.path,
                        signature.path,
                        zip.path
                    ],
                    [
                        "--validate-release-zip",
                        zip.path
                    ]
                ]

                for arguments in commands {
                    let process = Process()
                    process.executableURL = helper
                    process.arguments = arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice

                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        throw failure(
                            "Release authentication or ZIP validation failed."
                        )
                    }
                }

                DispatchQueue.main.async {
                    completion(.success(zip))
                }

            } catch {
                for file in stagedFiles {
                    try? fm.removeItem(at: file)
                }

                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }


    // Final consent before handing the authenticated release
    // to the external migration installer.
    private func confirmLegacyMigrationInstallation(
        zip: URL,
        releaseVersion: String
    ) {

        let currentVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""

        // Never migrate to a release older than the running fork.
        guard !currentVersion.isEmpty,
              releaseVersion.compare(
                currentVersion,
                options: .numeric
              ) != .orderedAscending else {

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Migration update unavailable"
            alert.informativeText =
                "The published release is older than this version of MacBox."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install maintained MacBox?"

        #if MACBOX_MIGRATION_UI_TEST

        alert.informativeText =
            "MacBox \(releaseVersion) has passed release authentication.\n\n" +
            "The isolated laboratory application will be replaced and backed up.\n\n" +
            "Your original MacBox installation will not be modified."

        #else

        alert.informativeText =
            "MacBox \(releaseVersion) has passed release authentication.\n\n" +
            "The original MacBox application will be backed up and replaced. Your virtual machines will be preserved.\n\n" +
            "Administrator permission may be requested."

        #endif

        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try handoffLegacyMigrationInstallation(zip: zip)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = "Migration could not start"
            failure.informativeText = error.localizedDescription
            failure.addButton(withTitle: "OK")
            failure.runModal()
        }
    }

    private func handoffLegacyMigrationInstallation(
        zip: URL
    ) throws {

        func failure(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.LegacyMigration",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        let fm = FileManager.default
        let base = zip.deletingPathExtension()
        let manifest = base.appendingPathExtension("manifest")
        let signature = base.appendingPathExtension("sig")

        guard UUID(uuidString: base.lastPathComponent) != nil,
              zip.pathExtension == "zip" else {
            throw failure("Invalid migration package location.")
        }

        for input in [manifest, signature, zip] {
            guard input.path ==
                    input.resolvingSymlinksInPath().path,
                  let attributes = try? fm.attributesOfItem(
                    atPath: input.path
                  ),
                  attributes[.type] as? FileAttributeType ==
                    .typeRegular else {
                throw failure("Migration release file missing or unsafe.")
            }
        }

        let helper: URL
        let command: String
        let installationMode: String

        #if MACBOX_MIGRATION_UI_TEST

        helper = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-ReleaseTest/LegacyMigration-Shared-Lab/MacBoxSharedMigrationUIHelper"
            )

        command = "--migrate-legacy-shared-lab"
        installationMode = "laboratory"

        #else

        guard Bundle.main.bundleIdentifier ==
                "io.github.settloe99.MacBox" else {
            throw failure("Invalid production MacBox identity.")
        }

        // Do not initiate migration while the original
        // MacBox application or a registered 86Box instance is open.
        let running = NSWorkspace.shared.runningApplications

        guard !running.contains(where: {
            $0.bundleIdentifier == "Moonif.MacBox" ||
            $0.bundleIdentifier == "net.86Box.86Box"
        }) else {
            throw failure(
                "Close the original MacBox and all virtual machines before migrating."
            )
        }

        helper = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Helpers/MacBoxSelfUpdateHelper"
        )

        command = "--migrate-legacy-production"
        installationMode = "production"

        #endif

        guard helper.path ==
                helper.resolvingSymlinksInPath().path,
              fm.isExecutableFile(atPath: helper.path) else {
            throw failure("Migration installer unavailable.")
        }

        // Retain an installation log outside the application bundle.
        let logDirectory = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Logs/MacBoxMigration",
                isDirectory: true
            )

        try fm.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let logURL = logDirectory.appendingPathComponent(
            "\(UUID().uuidString).log"
        )

        guard fm.createFile(
            atPath: logURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw failure("Could not create migration log.")
        }

        let log = try FileHandle(forWritingTo: logURL)
        defer { log.closeFile() }

        // This launcher runs under the normal user account.
        // It is never granted administrator privileges.
        let script = #"""
"$1" "$2" "$3" "$4" "$5" "$6"
STATUS=$?

if [ "$8" = "laboratory" ] || [ "$STATUS" -ne 0 ]; then
    /usr/bin/open -n "$7" --args \
        --macbox-migration-result "$STATUS" "$9"
fi

exit "$STATUS"
"""#

        let launcher = Process()

        launcher.executableURL = URL(
            fileURLWithPath: "/bin/sh"
        )

        launcher.arguments = [
            "-c",
            script,
            "macbox-migration-launcher",
            helper.path,
            command,
            String(ProcessInfo.processInfo.processIdentifier),
            manifest.path,
            signature.path,
            zip.path,
            Bundle.main.bundleURL.path,
            installationMode,
            logURL.path
        ]

        launcher.standardOutput = log
        launcher.standardError = log

        try launcher.run()

        NSApp.terminate(nil)
    }

    // Report the result when the laboratory application
    // restarts, or when a production migration fails.
    private func reportMacBoxUpdateFailure() -> Bool {

        let args = CommandLine.arguments

        guard let index = args.firstIndex(
            of: "--macbox-update-failure"
        ),
              args.count > index + 2 else {
            return false
        }

        let alert = NSAlert()

        alert.alertStyle = .warning
        alert.messageText = "MacBox update not completed"

        alert.informativeText =
            "Installation failed or administrator authorisation was cancelled.\n\n" +
            "Installation log:\n\(args[index + 2])"

        alert.addButton(withTitle: "OK")
        alert.runModal()

        return true
    }

    private func reportLegacyMigrationResult() -> Bool {

        let args = CommandLine.arguments

        guard let index = args.firstIndex(
            of: "--macbox-migration-result"
        ),
              args.count > index + 2,
              let status = Int(args[index + 1]) else {
            return false
        }

        let alert = NSAlert()

        if status == 0 {
            alert.alertStyle = .informational
            alert.messageText = "Migration completed"
            alert.informativeText =
                "The installation transaction completed successfully."
        } else {
            alert.alertStyle = .warning
            alert.messageText = "Migration not completed"
            alert.informativeText =
                "The installer returned an error or authorisation was cancelled.\n\n" +
                "Installation log:\n\(args[index + 2])"
        }

        alert.addButton(withTitle: "OK")
        alert.runModal()

        // Do not immediately repeat the migration prompt.
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {

        if MainViewController.instance?
            .storageRelocationInProgress == true {

            return .terminateCancel
        }

        return .terminateNow
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        if let mainVC = MainViewController.instance  {
            mainVC.screensaverManager.enableScreensaver()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

}
