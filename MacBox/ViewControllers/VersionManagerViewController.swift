//
//  VersionManagerViewController.swift
//  MacBox
//
//  Created by Moonif on 1/15/24.
//

import Cocoa
import CommonCrypto
import ZIPFoundation

class VersionManagerViewController: NSViewController {

    // IBOutlets
    @IBOutlet weak var tagsStackView: NSStackView!

    @IBOutlet weak var versionTagTextField: NSTextField!
    @IBOutlet weak var experimentalTagTextField: NSTextField!
    @IBOutlet weak var stableTagTextField: NSTextField!

    @IBOutlet weak var emulatorUpdateDateTextField: NSTextField!
    @IBOutlet weak var romsUpdateDateTextField: NSTextField!
    @IBOutlet weak var macboxUpdateDateTextField: NSTextField!

    @IBOutlet var emulatorReleaseNoteTextView: NSTextView!

    @IBOutlet var macboxReleaseNoteTextView: NSTextView!

    @IBOutlet weak var emulatorUpdateButton: NSButton!
    @IBOutlet weak var emulatorUpdateCheckImageView: NSImageView!
    @IBOutlet weak var emulatorUpdateProgressIndicator: NSProgressIndicator!

    @IBOutlet weak var romsUpdateButton: NSButton!
    @IBOutlet weak var romsUpdateCheckImageView: NSImageView!
    @IBOutlet weak var romsUpdateProgressIndicator: NSProgressIndicator!

    @IBOutlet weak var macboxUpdateButton: NSButton!
    @IBOutlet weak var macboxUpdateCheckImageView: NSImageView!
    @IBOutlet weak var macboxUpdateProgressIndicator: NSProgressIndicator!

    // Variables
    let dateFormatter = DateFormatter()
    private let userDefaults = UserDefaults.standard
    private let fileManager = FileManager.default
    #if MACBOX_RELEASE_TEST
        private let homeDirURL = URL(fileURLWithPath: "MacBox-ReleaseTest", isDirectory: true, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
    #elseif DEBUG
        private let homeDirURL = URL(fileURLWithPath: "MacBox-Dev", isDirectory: true, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
    #else
        private let homeDirURL = URL(fileURLWithPath: "MacBox", isDirectory: true, relativeTo: FileManager.default.homeDirectoryForCurrentUser)
    #endif
    private let dateInputFormatString = "yyyy-MM-dd'T'HH:mm:ssZ"
    private let dateOutputFormatString = "MMM dd, yyyy"
    var isStableChannel: Bool = false
    var emulatorAppVer: String = "0"
    var emulatorBuildVer: String = "0"
    private var emulatorUpdatedURL: URL?
    private var emulatorUpdatedAppVer: String?
    private var emulatorUpdatedBuildVer: String?

    var downloadTasks: [DownloadInfo] = []

    struct DownloadInfo {
        var type: updateType
        var downloadTask: URLSessionDownloadTask
        var updateButton: NSButton
        var progressIndicator: NSProgressIndicator
        var updateCheck: NSImageView
    }

    enum updateType {
        case emulator
        case roms
        case macbox
    }

    // View did load
    override func viewDidLoad() {
        super.viewDidLoad()

        // Config views
        configView()
    }

    // View will appear
    override func viewWillAppear() {
        // Remove fullscreen window button
        self.view.window?.styleMask.remove(.fullScreen)
        self.view.window?.styleMask.remove(.resizable)
    }

    // View did layout
    override func viewDidLayout() {
        // Adjust tags appearance
        for view in tagsStackView.views {
            view.layer?.masksToBounds = true
            view.layer?.cornerRadius = 4
        }
    }

    // View will disappear
    override func viewWillDisappear() {
        // Cancel all download tasks
        for downloadTask in downloadTasks {
            downloadTask.downloadTask.cancel()
        }
    }

    // Prevent updater operations during initial development testing
    private func updaterPermitted(_ type: updateType) -> Bool {
        #if MACBOX_RELEASE_TEST
        guard type == .emulator else {
            return false
        }

        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-ReleaseTest",
                isDirectory: true
            ).standardizedFileURL

        let expected = root
            .appendingPathComponent(
                "86Box.app",
                isDirectory: true
            ).standardizedFileURL

        var isDirectory: ObjCBool = false

        guard fm.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue,
        root.path == root.resolvingSymlinksInPath().path else {
            NSLog("MacBoxReleaseTest: Unsafe working directory.")
            return false
        }

        guard (try? fm.destinationOfSymbolicLink(
            atPath: expected.path
        )) == nil else {
            NSLog("MacBoxReleaseTest: Symbolic link rejected.")
            return false
        }

        if fm.fileExists(atPath: expected.path) {
            guard expected.path ==
                expected.resolvingSymlinksInPath().path,
                let bundle = Bundle(url: expected),
                bundle.bundleIdentifier == "net.86Box.86Box" else {
                NSLog("MacBoxReleaseTest: Invalid emulator.")
                return false
            }
        }

        NSLog("MacBoxReleaseTest: Emulator installation permitted.")
        return true

        #elseif DEBUG

        // ROM and MacBox self-updates remain disabled.
        switch type {
        case .roms, .macbox:
            return false
        case .emulator:
            break
        }

        let fm = FileManager.default

        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-Dev",
                isDirectory: true
            ).standardizedFileURL

        let expected = root
            .appendingPathComponent(
                "86Box.app",
                isDirectory: true
            ).standardizedFileURL

        // Check the configured preference directly.
        guard let configuredPath = UserDefaults.standard
            .string(forKey: "emulatorDefaultPath"),
            configuredPath.hasPrefix("/") else {
            NSLog("MacBoxDev: No valid emulator path configured.")
            return false
        }

        let configured = URL(
            fileURLWithPath: configuredPath,
            isDirectory: true
        ).standardizedFileURL

        guard configured.path == expected.path else {
            NSLog(
                "MacBoxDev: Unexpected emulator path: %@",
                configured.path
            )
            return false
        }

        // The development root must exist and must not be a symlink.
        var rootIsDirectory: ObjCBool = false

        guard fm.fileExists(
            atPath: root.path,
            isDirectory: &rootIsDirectory
        ),
        rootIsDirectory.boolValue,
        root.path == root.resolvingSymlinksInPath()
            .standardizedFileURL.path else {
            NSLog("MacBoxDev: Unsafe development directory.")
            return false
        }

        // Reject symbolic links, including dangling links.
        guard (try? fm.destinationOfSymbolicLink(
            atPath: expected.path
        )) == nil else {
            NSLog("MacBoxDev: Emulator destination is a symbolic link.")
            return false
        }

        var appIsDirectory: ObjCBool = false

        if fm.fileExists(
            atPath: expected.path,
            isDirectory: &appIsDirectory
        ) {
            // Existing installation: verify the application.
            guard appIsDirectory.boolValue,
                  expected.path == expected.resolvingSymlinksInPath()
                    .standardizedFileURL.path,
                  let bundle = Bundle(url: expected),
                  bundle.bundleIdentifier == "net.86Box.86Box" else {
                NSLog("MacBoxDev: Existing 86Box installation is invalid.")
                return false
            }
        } else {
            // Fresh installation: destination is empty.
            NSLog("MacBoxDev: Fresh 86Box installation permitted.")
        }

        NSLog("MacBoxDev: Development emulator update permitted.")
        return true

        #else
        return true
        #endif
    }

        // Config views initial properties
        private func configView() {
            // Populate update info
            populateEmulatorUpdateInfo()
            populateRomsUpdateInfo()
            populateMacBoxUpdateInfo()
            // Set update buttons visibility
            setUpdateButtons()

                #if MACBOX_RELEASE_TEST
                let testApp = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("MacBox-ReleaseTest/86Box.app")

                emulatorUpdateButton.title = FileManager.default.fileExists(
                    atPath: testApp.path
                ) ? "Update" : "Install"

                emulatorUpdateButton.isEnabled = updaterPermitted(.emulator)

                // Enable ROM installation in the isolated Release-Test laboratory.
                // The button action and managedRomsDestination() enforce the
                // laboratory destination before installation can begin.
                romsUpdateButton.isEnabled = true

                macboxUpdateButton.isEnabled = false

                #elseif DEBUG
                let devApp = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("MacBox-Dev/86Box.app")

                emulatorUpdateButton.title = FileManager.default.fileExists(
                    atPath: devApp.path
                ) ? "Update" : "Install"

                emulatorUpdateButton.isEnabled = updaterPermitted(.emulator)
                romsUpdateButton.isEnabled = false
                macboxUpdateButton.isEnabled = false
                #endif

        }

    // Populate 86Box update info
    private func populateEmulatorUpdateInfo() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        dateFormatter.dateFormat = dateInputFormatString
        let date: Date? = dateFormatter.date(from: versionInfoObject.emulatorUpdateObject?.published_at ?? "")
        let formattedDate = date?.getFormattedDate(format: dateOutputFormatString)

        var relativeDate = ""
        if #available(macOS 10.15, *) {
            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            relativeDate = relativeDateFormatter.localizedString(for: date ?? Date(), relativeTo: Date())
        } else {
            // Fallback on earlier versions
            relativeDate = formattedDate ?? "-"
        }

        emulatorUpdateDateTextField.stringValue = relativeDate
        emulatorUpdateDateTextField.toolTip = formattedDate

        emulatorReleaseNoteTextView.string = isStableChannel ? versionInfoObject.emulatorUpdateObject?.body ?? "-" : "What's New:\n" + (versionInfoObject.emulatorUpdateObject?.body ?? "-")

        // Tags
        versionTagTextField.stringValue = isStableChannel ? versionInfoObject.emulatorUpdateObject?.tag_name ?? "-" : "Build #" + (versionInfoObject.emulatorUpdateObject?.tag_name ?? "-")
        stableTagTextField.isHidden = !isStableChannel
        experimentalTagTextField.isHidden = isStableChannel
    }

    // Populate 86Box ROMs update info
    private func populateRomsUpdateInfo() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        dateFormatter.dateFormat = dateInputFormatString
        let date: Date? = dateFormatter.date(from: versionInfoObject.romsUpdateObject?.commit?.author?.date ?? "")
        let formattedDate = date?.getFormattedDate(format: dateOutputFormatString)

        var relativeDate = ""
        if #available(macOS 10.15, *) {
            let relativeDateFormatter = RelativeDateTimeFormatter()
            relativeDateFormatter.unitsStyle = .full

            relativeDate = relativeDateFormatter.localizedString(for: date ?? Date(), relativeTo: Date())
        } else {
            // Fallback on earlier versions
            relativeDate = formattedDate ?? "-"
        }

        romsUpdateDateTextField.stringValue = relativeDate
        romsUpdateDateTextField.toolTip = formattedDate
    }

    // Populate MacBox update information
    private func populateMacBoxUpdateInfo() {

        let versionInfoObject = MainViewController.instance.versionInfoObject

        // No published release was returned by the update feed.
        guard let release = versionInfoObject.macboxUpdateObject else {
            macboxUpdateDateTextField.stringValue = "Release unavailable"
            macboxUpdateDateTextField.toolTip =
                "No release information was returned by GitHub."

            macboxReleaseNoteTextView.string = """
            No published MacBox release is currently available
            from settloe99/MacBox.
            """

            return
        }

        dateFormatter.dateFormat = dateInputFormatString

        if let publishedAt = release.published_at,
           let date = dateFormatter.date(from: publishedAt) {

            let formattedDate = date.getFormattedDate(
                format: dateOutputFormatString
            )

            if #available(macOS 10.15, *) {
                let relativeDateFormatter = RelativeDateTimeFormatter()
                relativeDateFormatter.unitsStyle = .full

                macboxUpdateDateTextField.stringValue =
                    relativeDateFormatter.localizedString(
                        for: date,
                        relativeTo: Date()
                    )
            } else {
                macboxUpdateDateTextField.stringValue = formattedDate
            }

            macboxUpdateDateTextField.toolTip = formattedDate

        } else {
            macboxUpdateDateTextField.stringValue = "Date unavailable"
            macboxUpdateDateTextField.toolTip = nil
        }

        macboxReleaseNoteTextView.string = release.body ?? "-"
    }

    // Set update buttons visibility
    private func setUpdateButtons() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        emulatorUpdateButton.isHidden = false
        emulatorUpdateCheckImageView.isHidden = true
        emulatorUpdateProgressIndicator.isHidden = true

        romsUpdateButton.isHidden = false
        romsUpdateCheckImageView.isHidden = true
        romsUpdateProgressIndicator.isHidden = true

        macboxUpdateButton.isHidden = false
        macboxUpdateCheckImageView.isHidden = true
        macboxUpdateProgressIndicator.isHidden = true

        // Compare 86Box version
        if let emulatorOnlineVersion = versionInfoObject.emulatorUpdateObject?.tag_name {
            if isStableChannel {
                // Stable: compare app version
                if emulatorOnlineVersion.dropFirst() == emulatorAppVer {
                    emulatorUpdateButton.isHidden = true
                    emulatorUpdateCheckImageView.isHidden = false
                }
            }
            else {
                // Experimental: compare build version
                if emulatorOnlineVersion == emulatorBuildVer {
                    emulatorUpdateButton.isHidden = true
                    emulatorUpdateCheckImageView.isHidden = false
                }
            }
        }

        // Set ROM button label based on installation state.
        #if MACBOX_RELEASE_TEST
        let romsInstalled: Bool

        if let destination = try? managedRomsDestination() {
            let machines = destination.appendingPathComponent(
                "machines",
                isDirectory: true
            )

            var isDirectory: ObjCBool = false

            romsInstalled = FileManager.default.fileExists(
                atPath: machines.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        } else {
            romsInstalled = false
        }

        romsUpdateButton.title = romsInstalled
            ? NSLocalizedString("Update", comment: "")
            : NSLocalizedString("Install", comment: "")

        #else
        if versionInfoObject.romsUrls.isEmpty {
            romsUpdateButton.title = NSLocalizedString("Install", comment: "")
        } else {
            romsUpdateButton.title = NSLocalizedString("Update", comment: "")
        }
        #endif

        // Compare the installed ROM revision with the latest
        // revision reported by GitHub.
        if let remoteSha = versionInfoObject.romsUpdateObject?.sha,
           let localSha = userDefaults.string(forKey: "romsShaVersion"),
           localSha == String(remoteSha) {

            #if MACBOX_RELEASE_TEST
            // Release-Test uses the isolated ROM laboratory.
            let installedRomsAvailable = romsInstalled
            #else
            // Preserve the original production ROM discovery.
            let installedRomsAvailable = !versionInfoObject.romsUrls.isEmpty
            #endif

            if installedRomsAvailable {
                romsUpdateButton.isHidden = true
                romsUpdateCheckImageView.isHidden = false
            }
        }

        // Compare MacBox version only when a release exists.
        if let onlineVersion = versionInfoObject.macboxUpdateObject?.tag_name,
           !onlineVersion.isEmpty {

            let installedVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String

            if installedVersion == onlineVersion {
                // Installed version matches the published release.
                macboxUpdateButton.isHidden = true
                macboxUpdateCheckImageView.isHidden = false
            } else {
                // A different published release is available.
                macboxUpdateButton.isHidden = false
                macboxUpdateCheckImageView.isHidden = true
            }

        } else {
            // No valid release information.
            // Neither an Update button nor a green tick is appropriate.
            macboxUpdateButton.isHidden = true
            macboxUpdateCheckImageView.isHidden = true
        }
    }

    // Fetch 86Box updated macOS binary
    private func fetchEmulatorUpdateBinary() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        for asset in versionInfoObject.emulatorUpdateObject?.assets ?? [] {
            guard let downloadURL = asset.browser_download_url else {
                continue
            }

            if isStableChannel {
                let assetURL = downloadURL.lowercased()

                guard assetURL.contains("macos"),
                      assetURL.contains("arm64"),
                      assetURL.hasSuffix(".zip"),
                      let url = URL(string: downloadURL),
                      url.scheme == "https",
                      url.host == "github.com" else {
                    continue
                }

                downloadEmulatorBinary(url: url)
                return
            }

            let filename = (downloadURL as NSString)
                .lastPathComponent.lowercased()

            guard filename.hasSuffix(".zip"),
                  filename.contains("macos"),
                  filename.contains("arm64"),
                  !downloadURL.hasPrefix("/"),
                  !downloadURL.contains(".."),
                  let buildString = versionInfoObject.emulatorUpdateObject?.tag_name,
                  let buildNumber = Int(buildString),
                  buildNumber > 0 else {
                continue
            }

            var components = URLComponents()
            components.scheme = "https"
            components.host = "ci.86box.net"
            components.path = "/job/86Box/\(buildNumber)/artifact/\(downloadURL)"

            guard let url = components.url else {
                continue
            }

            NSLog(
                "MacBox: Selected 86Box download: %@",
                url.absoluteString
            )

            downloadEmulatorBinary(url: url)
            return
        }

        emulatorUpdateProgressIndicator.isHidden = true
        emulatorUpdateButton.isHidden = false

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "No compatible 86Box download found"
        alert.informativeText = """
        The update server did not provide a compatible macOS
        archive for the selected release.

        The existing 86Box installation has not been changed.
        """
        alert.runModal()
    }

    // Download 86Box binary
    private func downloadEmulatorBinary(url: URL) {
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: OperationQueue.main)

        let downloadTask = session.downloadTask(with: url)

        let downloadInfo = DownloadInfo(
            type: .emulator,
            downloadTask: downloadTask,
            updateButton: emulatorUpdateButton,
            progressIndicator: emulatorUpdateProgressIndicator,
            updateCheck: emulatorUpdateCheckImageView
        )

        downloadTasks.append(downloadInfo)

        downloadTask.resume()
    }

    // Update 86Box binary with the new version
    private func updateEmulatorBinary(location: URL) {
        let destination: URL

        #if MACBOX_RELEASE_TEST
        destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacBox-ReleaseTest/86Box.app")
        #elseif DEBUG
        // Development builds may only install into MacBox-Dev.
        destination = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-Dev/86Box.app",
                isDirectory: true
            )
        #else
        // Preserve the user's selected emulator location.
        let versionInfoObject =
            MainViewController.instance.versionInfoObject

        destination = versionInfoObject.emulatorCustomUrl
            ?? versionInfoObject.emulatorAutoUrl
            ?? homeDirURL.appendingPathComponent(
                "86Box.app",
                isDirectory: true
            )
        #endif

        do {
            let installationURL = destination.standardizedFileURL

            // The shared installer validates the destination,
            // downloaded application, version and code signature.
            // It also handles backups and rollback.
            let (appVersion, buildVersion) =
                try installVerifiedEmulator(
                    from: location,
                    installedAppURL: installationURL
                )

            // Record the successfully installed version.
            emulatorUpdatedURL = installationURL
            emulatorUpdatedAppVer = appVersion
            emulatorUpdatedBuildVer = buildVersion

            // Refresh MacBox's emulator information.
            MainViewController.instance.checkFor86Box(
                url: installationURL,
                appVer: appVersion,
                buildVer: buildVersion
            )

            // Update the Version Manager interface.
            emulatorUpdateProgressIndicator.isHidden = true
            emulatorUpdateButton.isHidden = true
            emulatorUpdateCheckImageView.isHidden = false

            NSLog(
                "MacBox: 86Box installation completed. Version %@, build %@",
                appVersion,
                buildVersion
            )

        } catch {
            NSLog(
                "MacBox: 86Box installation failed: %@",
                error.localizedDescription
            )

            emulatorUpdateProgressIndicator.isHidden = true
            emulatorUpdateButton.isHidden = false
            emulatorUpdateCheckImageView.isHidden = true

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "86Box installation failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

        // Shared transactional 86Box installer.
        // The caller supplies the installation directory.
        private func installVerifiedEmulator(
            from downloadedFile: URL,
            installedAppURL: URL
        ) throws -> (String, String) {
            let fm = FileManager.default
            let installed = installedAppURL.standardizedFileURL
            let root = installed.deletingLastPathComponent()

            #if MACBOX_RELEASE_TEST
            let workingRoot = root
            #elseif DEBUG
            // Preserve the development directories we have already tested.
            let workingRoot = root
            #else
            // Keep updater files in the user's Application Support folder.
            let workingRoot = fm.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("MacBox", isDirectory: true)
            .appendingPathComponent("Updater", isDirectory: true)
            #endif

            let temporary = workingRoot.appendingPathComponent("tmp")
            let backups = workingRoot.appendingPathComponent("86Box-backups")

            func fail(_ message: String) -> NSError {
                NSError(
                    domain: "MacBoxDev.Updater",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }

            // Validate the installation destination.
            guard installed.isFileURL,
                installed.lastPathComponent == "86Box.app"
            else {
                throw fail("Invalid 86Box installation destination.")
            }


            #if MACBOX_RELEASE_TEST

            let testDestination = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("MacBox-ReleaseTest/86Box.app")
                .standardizedFileURL

            guard installed.path == testDestination.path else {
                throw fail("Release-Test cannot modify production 86Box.")
            }
            #elseif DEBUG
            let expected = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("MacBox-Dev/86Box.app")
                .standardizedFileURL

            guard installed.path == expected.path else {
                throw fail(
                    "Development updates cannot modify production installations."
                )
            }
            #endif

            func requireRealDirectory(_ url: URL) throws {
                let path = url.standardizedFileURL
                guard path.path == path.resolvingSymlinksInPath().path,
                    let attributes = try? fm.attributesOfItem(atPath: path.path),
                    attributes[.type] as? FileAttributeType == .typeDirectory
                else {
                    throw fail("Unsafe directory: \(url.path)")
                }
            }

            func prepareDirectory(_ url: URL) throws {
                if !fm.fileExists(atPath: url.path) {
                    try fm.createDirectory(
                        at: url,
                        withIntermediateDirectories: false
                    )
                }
                try requireRealDirectory(url)
            }

            // Use the shared verifier for application identity,
            // signature, architecture and version validation.
            func verify(_ app: URL) throws -> (String, String) {
                let verified = try EmulatorIntegrity.verify(app)
                return (verified.version, verified.build)
            }

            // Never trust an application preference for this destination.
            try requireRealDirectory(root)

            // Record the exact managed destination before any
            // installation files are moved. Startup recovery must
            // still find this directory if 86Box.app is missing.
            #if !DEBUG
            let recoveryDefaults = UserDefaults.standard
            recoveryDefaults.set(
                installed.path,
                forKey: "MacBoxManaged86BoxPath"
            )

            guard recoveryDefaults.synchronize() else {
                throw fail(
                    "Unable to save the 86Box recovery destination. " +
                    "Installation cancelled before replacement."
                )
            }
            #endif

            // Detect incomplete transactions from a previous update.
            // Do not start another installation until recovery is complete.
            let transactionEntries = try fm.contentsOfDirectory(
                atPath: root.path
            )

            let unfinishedTransactions = transactionEntries.filter { name in
                (name.hasPrefix(".MacBox-86Box-previous-") ||
                 name.hasPrefix(".MacBox-86Box-incoming-")) &&
                name.hasSuffix(".app")
            }

            guard unfinishedTransactions.isEmpty else {
                throw fail(
                    "An interrupted 86Box update was detected. " +
                    "No files have been changed. " +
                    "Recovery is required before another installation. " +
                    "Remaining files: " +
                    unfinishedTransactions.joined(separator: ", ")
                )
            }

            let hasExistingInstallation: Bool
            if fm.fileExists(atPath: installed.path) {
                try requireRealDirectory(installed)

                // Never treat a damaged existing application as
                // a normal update candidate.
                do {
                    _ = try verify(installed)
                } catch {
                    throw fail(
                        "The existing 86Box installation failed " +
                        "integrity verification. The update has been " +
                        "blocked without modifying the emulator. " +
                        "Use the recovery process rather than a " +
                        "normal update. Details: " +
                        error.localizedDescription
                    )
                }

                hasExistingInstallation = true
            } else {

                // Reject even a dangling symbolic link at the destination.
                guard (try? fm.destinationOfSymbolicLink(
                    atPath: installed.path
                )) == nil else {
                    throw fail("Unsafe installation destination.")
                }

                hasExistingInstallation = false
            }

            #if !DEBUG
            try fm.createDirectory(
                at: workingRoot,
                withIntermediateDirectories: true
            )
            try requireRealDirectory(workingRoot)
            #endif

            try prepareDirectory(temporary)
            try prepareDirectory(backups)

            guard NSRunningApplication.runningApplications(
                withBundleIdentifier: "net.86Box.86Box"
            ).isEmpty else {
                throw fail("Close all running 86Box instances first.")
            }

            let stage = temporary.appendingPathComponent(
                UUID().uuidString, isDirectory: true
            )
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)

            defer {
                try? fm.removeItem(at: stage)
            }

            let archiveURL = stage.appendingPathComponent("download.zip")
            try fm.copyItem(at: downloadedFile, to: archiveURL)

            // Reject archive entries outside the expected application.
            guard let archive = Archive(url: archiveURL, accessMode: .read) else {
                throw fail("Downloaded file is not a valid ZIP archive.")
            }

            for entry in archive {
                let path = entry.path
                let components = path.split(separator: "/")
                guard (path == "86Box.app" || path.hasPrefix("86Box.app/")),
                    !components.contains(".."),
                    !path.contains("\\")
                else {
                    throw fail("Unexpected ZIP archive path: \(path)")
                }
            }

            try fm.unzipItem(at: archiveURL, to: stage)

            let candidate = stage.appendingPathComponent("86Box.app")
            let replacement = try verify(candidate)

            // Validate the downloaded application against the selected release.
            guard let releaseTag = MainViewController.instance
                .versionInfoObject.emulatorUpdateObject?.tag_name else {
                throw fail("The selected release has no version information.")
            }

            if isStableChannel {
                // Stable tags are formatted as v6.0, v6.1, etc.
                guard releaseTag.lowercased().hasPrefix("v"),
                    String(releaseTag.dropFirst()) == replacement.0,
                    Int(replacement.1) != nil else {
                    throw fail(
                        "The downloaded application does not match the selected stable release."
                    )
                }
            } else {
                // Experimental tags contain Jenkins build numbers.
                guard releaseTag == replacement.1,
                    Int(replacement.1) != nil else {
                    throw fail(
                        "The downloaded application does not match the selected experimental build."
                    )
                }
            }

            // Fresh installations have no previous application to back up.
            if !hasExistingInstallation {

                let incoming = root.appendingPathComponent(
                    ".MacBox-86Box-incoming-\(UUID().uuidString).app"
                )

                guard !fm.fileExists(atPath: incoming.path),
                      (try? fm.destinationOfSymbolicLink(
                        atPath: incoming.path
                      )) == nil else {
                    throw fail("Unsafe staging destination.")
                }

                // Copy beside the destination, then verify the staged app.
                try fm.copyItem(at: candidate, to: incoming)

                defer {
                    if fm.fileExists(atPath: incoming.path) {
                        try? fm.removeItem(at: incoming)
                    }
                }

                let staged = try verify(incoming)

                guard staged.0 == replacement.0,
                      staged.1 == replacement.1 else {
                    throw fail("Fresh installation staging verification failed.")
                }

                // Do not overwrite an installation that appeared meanwhile.
                guard !fm.fileExists(atPath: installed.path),
                      (try? fm.destinationOfSymbolicLink(
                        atPath: installed.path
                      )) == nil else {
                    throw fail("Installation destination is no longer empty.")
                }

                try fm.moveItem(at: incoming, to: installed)

                do {
                    let checked = try verify(installed)

                    guard checked.0 == replacement.0,
                          checked.1 == replacement.1 else {
                        throw fail("Installed application verification failed.")
                    }
                } catch {
                    let installationError = error

                    do {
                        try fm.removeItem(at: installed)
                    } catch {
                        throw fail(
                            "Installation verification failed, and cleanup also failed. " +
                            error.localizedDescription
                        )
                    }

                    throw fail(
                        "Fresh installation failed; incomplete application removed. " +
                        installationError.localizedDescription
                    )
                }

                NSLog(
                    "MacBox: Fresh 86Box installation completed: build %@",
                    replacement.1
                )

                return replacement
            }

            // Existing installations continue through the tested
            // backup, replacement and rollback routine.

            let previous = try verify(installed)

            // Only permit genuine upgrades to existing installations.
            if isStableChannel {
                let comparison = replacement.0.compare(
                    previous.0,
                    options: .numeric
                )

                guard comparison == .orderedDescending else {
                    throw fail(
                        "Stable version \(replacement.0) is not newer than " +
                        "the installed version \(previous.0). " +
                        "Downgrades and reinstalls are blocked."
                    )
                }
            } else {
                guard let newBuild = Int(replacement.1),
                    let oldBuild = Int(previous.1),
                    newBuild > oldBuild else {
                    throw fail(
                        "Experimental build \(replacement.1) is not newer " +
                        "than the installed build \(previous.1)."
                    )
                }
            }

            // Prepare unique paths for this installation transaction.
            let transactionID = UUID().uuidString

            let backup = backups.appendingPathComponent(
                "86Box-\(previous.1)-\(transactionID).app"
            )

            let incoming = root.appendingPathComponent(
                ".MacBox-86Box-incoming-\(transactionID).app"
            )

            let parked = root.appendingPathComponent(
                ".MacBox-86Box-previous-\(transactionID).app"
            )

            guard !fm.fileExists(atPath: incoming.path),
                  !fm.fileExists(atPath: parked.path),
                  !fm.fileExists(atPath: backup.path) else {
                throw fail("Installation transaction paths already exist.")
            }

            // Stage the replacement beside the installed application.
            // A failure here leaves the existing emulator untouched.
            try fm.copyItem(at: candidate, to: incoming)

            defer {
                if fm.fileExists(atPath: incoming.path) {
                    try? fm.removeItem(at: incoming)
                }
            }

            let staged = try verify(incoming)

            guard staged.0 == replacement.0,
                  staged.1 == replacement.1 else {
                throw fail("Staged application verification failed.")
            }

            // Preserve and verify an independent recovery copy
            // before modifying the installed application.
            do {
                try fm.copyItem(at: installed, to: backup)

                let saved = try verify(backup)
                guard saved.0 == previous.0,
                      saved.1 == previous.1 else {
                    throw fail("Backup version verification failed.")
                }
            } catch {
                throw fail(
                    "Unable to create a verified backup: " +
                    error.localizedDescription
                )
            }

            // Reverify the existing application immediately before
            // moving it. Abort if it has become damaged or its
            // version has changed during preparation.
            let beforeMove: (String, String)

            do {
                beforeMove = try verify(installed)
            } catch {
                throw fail(
                    "The existing emulator failed its final " +
                    "integrity check. Installation cancelled " +
                    "before replacement. Details: " +
                    error.localizedDescription
                )
            }

            guard beforeMove.0 == previous.0,
                  beforeMove.1 == previous.1 else {
                throw fail(
                    "The installed emulator version changed during " +
                    "update preparation. Installation cancelled."
                )
            }

            // Park the verified original before installing its replacement.
            // If parking fails, abort without touching the installed app.
            try fm.moveItem(at: installed, to: parked)

            do {
                // Install the staged replacement using a local move.
                try fm.moveItem(at: incoming, to: installed)

                let checked = try verify(installed)

                guard checked.0 == replacement.0,
                      checked.1 == replacement.1 else {
                    throw fail("Installed version verification failed.")
                }


            } catch {
                let installationError = error

                do {
                    // Never remove a destination unless the parked
                    // original is present and verified.
                    let parkedCheck = try verify(parked)

                    guard parkedCheck.0 == previous.0,
                          parkedCheck.1 == previous.1 else {
                        throw fail(
                            "The parked original is missing or does " +
                            "not match the expected version. " +
                            "No installation files were removed."
                        )
                    }

                    let destinationOccupied =
                        fm.fileExists(atPath: installed.path) ||
                        (try? fm.destinationOfSymbolicLink(
                            atPath: installed.path
                        )) != nil

                    if destinationOccupied {
                        // Only discard a verified replacement belonging
                        // to this transaction. Preserve any unknown or
                        // damaged application for manual recovery.
                        guard let current = try? verify(installed),
                              current.0 == replacement.0,
                              current.1 == replacement.1 else {
                            throw fail(
                                "An unknown or damaged application " +
                                "occupies the installation destination. " +
                                "Files have been preserved for manual recovery."
                            )
                        }

                        try fm.removeItem(at: installed)
                    }

                    try fm.moveItem(at: parked, to: installed)
                    let restored = try verify(installed)
                    guard restored.0 == previous.0,
                          restored.1 == previous.1 else {
                        throw fail("Rollback version verification failed.")
                    }

                } catch {
                    throw fail("""
                    Installation failed and automatic rollback failed.

                    Installation error:
                    \(installationError.localizedDescription)

                    Rollback error:
                    \(error.localizedDescription)

                    Verified backup:
                    \(backup.path)

                    Previous installation location:
                    \(parked.path)
                    """)
                }

                throw fail(
                    "Installation failed; the original emulator was restored. " +
                    installationError.localizedDescription
                )
            }

            // The replacement is verified and the independent backup
            // is retained, so the parked copy is no longer needed.
            do {
                try fm.removeItem(at: parked)
            } catch {
                NSLog(
                    "MacBox: Could not remove parked application: %@",
                    error.localizedDescription
                )
            }

            NSLog(
                "MacBox: Installed build %@; backup retained at %@",
                replacement.1,
                backup.path
            )

            return replacement

        }

    // Select one managed, per-user ROM installation destination.
    // Never use discovered VM-specific or system-wide ROM folders.
    private func managedRomsDestination() throws -> URL {
        let fm = FileManager.default

        #if MACBOX_RELEASE_TEST
        // ROM installation tests must never target the user's
        // actual 86Box ROM collection.
        let testRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-ReleaseTest",
                isDirectory: true
            ).standardizedFileURL

        let lab = testRoot.appendingPathComponent(
            "ROMs-Lab",
            isDirectory: true
        )

        guard testRoot.path ==
                testRoot.resolvingSymlinksInPath().path,
              lab.path == lab.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: lab.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeDirectory else {
            throw NSError(
                domain: "MacBox.ROMUpdater",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The isolated ROM test directory is missing or unsafe."
                ]
            )
        }

        return lab.appendingPathComponent(
            "roms",
            isDirectory: true
        )
        #else

        guard let support = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL else {
            throw NSError(
                domain: "MacBox.ROMUpdater",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "User Application Support directory unavailable."
                ]
            )
        }

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.ROMUpdater",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let modern = support.appendingPathComponent(
            "86Box/roms",
            isDirectory: true
        )

        let legacy = support.appendingPathComponent(
            "net.86box.86Box/roms",
            isDirectory: true
        )

        func directoryExistsSafely(_ url: URL) throws -> Bool {
            guard url.path == url.resolvingSymlinksInPath().path,
                  (try? fm.destinationOfSymbolicLink(
                    atPath: url.path
                  )) == nil else {
                throw fail("Unsafe ROM directory path: \(url.path)")
            }

            guard fm.fileExists(atPath: url.path) else {
                return false
            }

            guard let attributes = try? fm.attributesOfItem(
                atPath: url.path
            ),
                  attributes[.type] as? FileAttributeType ==
                    .typeDirectory else {
                throw fail("ROM path is not a directory: \(url.path)")
            }

            return true
        }

        let modernExists = try directoryExistsSafely(modern)
        let legacyExists = try directoryExistsSafely(legacy)

        guard !(modernExists && legacyExists) else {
            throw fail(
                "Both modern and legacy ROM directories exist. " +
                "Choose which collection MacBox should manage " +
                "before installing updates."
            )
        }

        if modernExists {
            return modern
        }

        if legacyExists {
            return legacy
        }

        // Fresh installations use the current per-user location.
        // This function only selects a path; it creates nothing.
        return modern
        #endif
    }

    // Download the exact ROM revision identified by the update check.
    private func fetchRomsUpdateFile() {
        guard let sha = MainViewController.instance
                .versionInfoObject.romsUpdateObject?.sha,
              sha.range(
                of: "^[0-9a-fA-F]{40}$",
                options: .regularExpression
              ) != nil,
              let url = URL(
                string: "https://api.github.com/repos/86Box/roms/zipball/\(sha)"
              ) else {

            romsUpdateProgressIndicator.isHidden = true
            romsUpdateButton.isHidden = false

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ROM update information unavailable"
            alert.informativeText = """
            MacBox could not identify a valid ROM revision.

            No ROM files have been downloaded or modified.

            Check for updates again before retrying.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        downloadRomsFile(url: url)
    }

    // Download 86Box ROMs file
    private func downloadRomsFile(url: URL) {
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: OperationQueue.main)

        let downloadTask = session.downloadTask(with: url)

        let downloadInfo = DownloadInfo(
            type: .roms,
            downloadTask: downloadTask,
            updateButton: romsUpdateButton,
            progressIndicator: romsUpdateProgressIndicator,
            updateCheck: romsUpdateCheckImageView
        )

        downloadTasks.append(downloadInfo)

        downloadTask.resume()
    }


    // Validate and install one ROM collection transactionally.
    private func installRomsTransaction(downloadedFile: URL) throws {
        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.ROMUpdater",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        // A real destination is selected by our isolated/production
        // selector, never by the list of discovered ROM folders.
        let destination = try managedRomsDestination()
            .standardizedFileURL
        let parent = destination.deletingLastPathComponent()

        guard destination.lastPathComponent == "roms",
              destination.path != parent.path,
              destination.path ==
                destination.resolvingSymlinksInPath().path else {
            throw fail("Unsafe ROM destination.")
        }

        // Inspect the ZIP before extracting any contents.
        guard let archive = try? Archive(
            url: downloadedFile,
            accessMode: .read
        ) else {
            throw fail("The ROM download is not a valid ZIP archive.")
        }

        var rootName: String?
        var seen = Set<String>()
        var entryCount = 0
        var totalSize: UInt64 = 0
        var containsMachineROM = false

        let maxExpandedSize: UInt64 = 4 * 1024 * 1024 * 1024

        for entry in archive {
            entryCount += 1

            guard entryCount <= 50_000,
                  entry.type != .symlink else {
                throw fail("The ROM archive contains unsafe entries.")
            }

            let path = entry.path

            guard !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !path.contains("\0") else {
                throw fail("Unsafe ROM archive filename.")
            }

            let trimmed = path.hasSuffix("/")
                ? String(path.dropLast()) : path

            let components = trimmed.split(
                separator: "/",
                omittingEmptySubsequences: false
            )

            guard !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  }) else {
                throw fail("Invalid ROM archive path.")
            }

            let root = String(components[0])

            guard root.hasPrefix("86Box-roms-") else {
                throw fail("Unexpected ROM archive structure.")
            }

            if let expectedRoot = rootName {
                guard root == expectedRoot else {
                    throw fail("Multiple archive roots detected.")
                }
            } else {
                rootName = root
            }

            let key = trimmed.precomposedStringWithCanonicalMapping
                .lowercased()

            guard seen.insert(key).inserted else {
                throw fail("Duplicate ROM archive entry.")
            }

            guard entry.uncompressedSize <= maxExpandedSize,
                  totalSize <=
                    maxExpandedSize - entry.uncompressedSize else {
                throw fail("ROM archive exceeds the size limit.")
            }

            totalSize += entry.uncompressedSize

            if entry.type == .file,
               components.count >= 3,
               components[1] == "machines" {
                containsMachineROM = true
            }
        }

        guard entryCount > 0,
              containsMachineROM,
              let root = rootName else {
            throw fail("ROM archive is empty or incomplete.")
        }

        // The parent must be a real directory, not a symlink.
        try fm.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        guard parent.path == parent.resolvingSymlinksInPath().path,
              (try fm.attributesOfItem(
                atPath: parent.path
              )[.type] as? FileAttributeType) == .typeDirectory else {
            throw fail("Unsafe ROM installation parent directory.")
        }

        // Refuse to start a new transaction if an older one
        // left an original ROM collection parked.
        let siblings = try fm.contentsOfDirectory(
            atPath: parent.path
        )

        guard !siblings.contains(where: {
            $0.hasPrefix(".MacBox-ROMs-parked-")
        }) else {
            throw fail(
                "An interrupted ROM update needs recovery. " +
                "No ROM files have been modified."
            )
        }

        let identifier = UUID().uuidString

        let workspace = parent.appendingPathComponent(
            ".MacBox-ROMs-work-\(identifier)",
            isDirectory: true
        )

        let extracted = workspace.appendingPathComponent(
            "extracted",
            isDirectory: true
        )

        let parked = parent.appendingPathComponent(
            ".MacBox-ROMs-parked-\(identifier)",
            isDirectory: true
        )

        let rejected = parent.appendingPathComponent(
            ".MacBox-ROMs-rejected-\(identifier)",
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

        // ZIPFoundation performs extraction and checks file CRCs.
        try fm.unzipItem(at: downloadedFile, to: extracted)

        let staged = extracted.appendingPathComponent(
            root,
            isDirectory: true
        )

        let stagedMachines = staged.appendingPathComponent(
            "machines",
            isDirectory: true
        )

        var isDirectory: ObjCBool = false

        guard fm.fileExists(
            atPath: stagedMachines.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw fail("Extracted ROM collection failed validation.")
        }

        // Protect the existing ROM collection before replacement.
        let originalExists = fm.fileExists(
            atPath: destination.path
        )

        if originalExists {
            guard (
                try fm.attributesOfItem(
                    atPath: destination.path
                )[.type] as? FileAttributeType
            ) == .typeDirectory else {
                throw fail("The existing ROM path is not a directory.")
            }

            let backups = parent.appendingPathComponent(
                ".MacBox-ROMs-backups",
                isDirectory: true
            )

            try fm.createDirectory(
                at: backups,
                withIntermediateDirectories: true
            )

            guard backups.path ==
                    backups.resolvingSymlinksInPath().path else {
                throw fail("Unsafe ROM backup directory.")
            }

            let backup = backups.appendingPathComponent(
                "roms-\(identifier)",
                isDirectory: true
            )

            // A backup must succeed before the original is moved.
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

            var finalIsDirectory: ObjCBool = false

            guard fm.fileExists(
                atPath: destination
                    .appendingPathComponent("machines").path,
                isDirectory: &finalIsDirectory
            ), finalIsDirectory.boolValue else {
                throw fail("Installed ROM collection failed verification.")
            }

            // The independent backup already exists. Remove the
            // parked original only after verifying the replacement.
            if originalParked {
                do {
                    try fm.removeItem(at: parked)
                } catch {
                    NSLog(
                        "MacBox: Retained parked ROMs: %@",
                        parked.path
                    )
                }
            }
        } catch {
            let installationError = error

            do {
                if newInstalled &&
                    fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: destination, to: rejected)
                }

                if originalParked {
                    try fm.moveItem(at: parked, to: destination)
                }
            } catch {
                throw fail(
                    "ROM installation failed, and automatic rollback " +
                    "also failed. The original may remain at: " +
                    parked.path + ". Rollback error: " +
                    error.localizedDescription
                )
            }

            throw installationError
        }
    }

    // Update 86Box ROMs with the downloaded revision.
    private func updateRomsFile(location: URL) {
        #if DEBUG
        NSLog("MacBoxDev: ROM installation blocked.")
        return
        #endif

        do {
            try installRomsTransaction(
                downloadedFile: location
            )

            if let sha = MainViewController.instance
                .versionInfoObject.romsUpdateObject?.sha {
                userDefaults.set(sha, forKey: "romsShaVersion")
            }

            romsUpdateProgressIndicator.isHidden = true
            romsUpdateButton.isHidden = true
            romsUpdateCheckImageView.isHidden = false

            NSLog("MacBox: ROM installation completed.")
        } catch {
            romsUpdateProgressIndicator.isHidden = true
            romsUpdateButton.isHidden = false
            romsUpdateCheckImageView.isHidden = true

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "ROM installation failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()

            NSLog(
                "MacBox: ROM installation failed: %@",
                error.localizedDescription
            )
        }
    }

    // Fetch MacBox updated macOS binary
    private func fetchMacBoxUpdateBinary() {

        let versionInfoObject = MainViewController.instance.versionInfoObject

        func reject(_ reason: String) {
            macboxUpdateProgressIndicator.isHidden = true
            macboxUpdateButton.isHidden = false

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "MacBox update unavailable"
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        let matchingAssets: [(asset: GithubAsset, url: URL)] = (
            versionInfoObject.macboxUpdateObject?.assets ?? []
        ).compactMap { asset in

            guard let downloadURL = asset.browser_download_url,
                  let url = URL(string: downloadURL),
                  url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "github.com",
                  url.path.hasPrefix(
                    "/settloe99/MacBox/releases/download/"
                  ),
                  url.pathExtension.lowercased() == "zip",
                  url.lastPathComponent.lowercased().contains("macbox")
            else {
                return nil
            }

            return (asset: asset, url: url)
        }

        guard matchingAssets.count == 1,
              let selected = matchingAssets.first else {

            reject(
                "Exactly one MacBox application ZIP must be " +
                "present in the fork's GitHub release."
            )
            return
        }

        guard let digest = selected.asset.digest?.lowercased(),
              digest.range(
                of: "^sha256:[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil else {

            reject(
                "The release package has no valid SHA-256 digest. " +
                "The download has been cancelled."
            )
            return
        }

        let expectedSHA256 = String(digest.dropFirst(7))

        NSLog(
            "MacBox: Selected verified release asset: %@",
            selected.url.lastPathComponent
        )

        downloadMacBoxBinary(
            url: selected.url,
            expectedSHA256: expectedSHA256
        )
    }

    // Calculate the SHA-256 checksum of a downloaded application ZIP.
    private func macBoxDownloadSHA256(
        at fileURL: URL
    ) throws -> String {

        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )

        guard let size = attributes[.size] as? NSNumber,
              size.int64Value > 0,
              size.int64Value <= 512 * 1024 * 1024 else {

            throw NSError(
                domain: "MacBox.Download",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The MacBox download has an invalid file size."
                ]
            )
        }

        let data = try Data(
            contentsOf: fileURL,
            options: .mappedIfSafe
        )

        var digest = [UInt8](
            repeating: 0,
            count: Int(CC_SHA256_DIGEST_LENGTH)
        )

        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(
                buffer.baseAddress,
                CC_LONG(buffer.count),
                &digest
            )
        }

        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    // Preserve a verified MacBox download for the external updater.
    // URLSession temporary downloads may disappear after the callback.
    private func stageVerifiedMacBoxDownload(
        from temporaryURL: URL,
        expectedSHA256: String
    ) throws -> URL {

        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        guard let caches = fm.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL else {
            throw fail("User cache directory unavailable.")
        }

        let root = caches.appendingPathComponent(
            "io.github.settloe99.MacBox",
            isDirectory: true
        )

        let stagingDirectory = root.appendingPathComponent(
            "StagedUpdates",
            isDirectory: true
        )

        // Reject redirected paths before creating anything.
        for directory in [caches, root, stagingDirectory] {
            guard directory.path ==
                    directory.resolvingSymlinksInPath().path else {
                throw fail("Unsafe update staging directory.")
            }
        }

        try fm.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        guard stagingDirectory.path ==
                stagingDirectory.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: stagingDirectory.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeDirectory else {
            throw fail("Invalid update staging directory.")
        }

        let stagedFile = stagingDirectory.appendingPathComponent(
            "\(UUID().uuidString).zip"
        )

        try fm.copyItem(
            at: temporaryURL,
            to: stagedFile
        )

        do {
            try fm.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stagedFile.path
            )

            // Verify that staging did not change the download.
            let stagedSHA256 = try macBoxDownloadSHA256(
                at: stagedFile
            )

            guard stagedSHA256 == expectedSHA256 else {
                throw fail(
                    "The staged MacBox update failed SHA-256 verification."
                )
            }

            // Revalidate the preserved archive before handoff.
            try validateMacBoxUpdateArchive(
                at: stagedFile
            )

            NSLog(
                "MacBox: Verified update staged at %@",
                stagedFile.path
            )

            return stagedFile

        } catch {
            try? fm.removeItem(at: stagedFile)
            throw error
        }
    }

    // Download MacBox binary
    private func downloadMacBoxBinary(
        url: URL,
        expectedSHA256: String
    ) {

        let sessionConfig = URLSessionConfiguration.default

        let session = URLSession(
            configuration: sessionConfig,
            delegate: self,
            delegateQueue: OperationQueue.main
        )

        let downloadTask = session.downloadTask(with: url)

        // Associate the expected GitHub digest with this
        // particular download task.
        downloadTask.taskDescription = expectedSHA256

        let downloadInfo = DownloadInfo(
            type: .macbox,
            downloadTask: downloadTask,
            updateButton: macboxUpdateButton,
            progressIndicator: macboxUpdateProgressIndicator,
            updateCheck: macboxUpdateCheckImageView
        )

        downloadTasks.append(downloadInfo)
        downloadTask.resume()
    }

    // Validate a MacBox application ZIP before extraction.
    // This function only inspects the archive and changes no files.
    private func validateMacBoxUpdateArchive(
        at downloadedFile: URL
    ) throws {

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        guard let archive = try? Archive(
            url: downloadedFile,
            accessMode: .read
        ) else {
            throw fail("The MacBox download is not a valid ZIP archive.")
        }

        let maxEntries = 50_000
        let maxExpandedSize: UInt64 = 2 * 1024 * 1024 * 1024

        var entryCount = 0
        var totalSize: UInt64 = 0
        var seenPaths = Set<String>()

        var containsInfoPlist = false
        var containsExecutable = false

        for entry in archive {
            entryCount += 1

            guard entryCount <= maxEntries,
                  entry.type != .symlink else {
                throw fail(
                    "The MacBox archive contains unsupported or unsafe entries."
                )
            }

            let path = entry.path

            guard !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !path.contains("\0") else {
                throw fail("Unsafe MacBox archive filename.")
            }

            let trimmedPath = path.hasSuffix("/")
                ? String(path.dropLast())
                : path

            let components = trimmedPath.split(
                separator: "/",
                omittingEmptySubsequences: false
            )

            guard !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                  }),
                  components[0] == "MacBox.app" else {
                throw fail(
                    "Unexpected MacBox archive directory structure."
                )
            }

            let normalisedPath = trimmedPath
                .precomposedStringWithCanonicalMapping
                .lowercased()

            guard seenPaths.insert(normalisedPath).inserted else {
                throw fail("Duplicate MacBox archive entry.")
            }

            guard entry.uncompressedSize <= maxExpandedSize,
                  totalSize <=
                    maxExpandedSize - entry.uncompressedSize else {
                throw fail("MacBox archive exceeds the size limit.")
            }

            totalSize += entry.uncompressedSize

            if entry.type == .file {
                if trimmedPath == "MacBox.app/Contents/Info.plist" {
                    containsInfoPlist = true
                }

                if trimmedPath == "MacBox.app/Contents/MacOS/MacBox" {
                    containsExecutable = true
                }
            }
        }

        guard entryCount > 0,
              containsInfoPlist,
              containsExecutable else {
            throw fail(
                "The archive does not contain a complete MacBox application."
            )
        }

        NSLog(
            "MacBox: Application archive validation passed (%d entries).",
            entryCount
        )
    }

    // Select the application destination for a MacBox self-update.
    // Release-Test must never replace the running MacBox application.
    private func managedMacBoxUpdateDestination() throws -> URL {
        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        #if MACBOX_RELEASE_TEST

        let root = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "MacBox-ReleaseTest",
                isDirectory: true
            ).standardizedFileURL

        let destination = root.appendingPathComponent(
            "MacBox-UpdateTarget.app",
            isDirectory: true
        ).standardizedFileURL

        guard root.path == root.resolvingSymlinksInPath().path,
              let rootAttributes = try? fm.attributesOfItem(
                atPath: root.path
              ),
              rootAttributes[.type] as? FileAttributeType ==
                .typeDirectory,
              destination.path ==
                destination.resolvingSymlinksInPath().path,
              destination.path !=
                Bundle.main.bundleURL.standardizedFileURL.path else {

            throw fail(
                "Unsafe Release-Test MacBox update destination."
            )
        }

        if fm.fileExists(atPath: destination.path) {
            guard let attributes = try? fm.attributesOfItem(
                atPath: destination.path
            ),
            attributes[.type] as? FileAttributeType ==
                .typeDirectory else {

                throw fail(
                    "Existing test application path is invalid."
                )
            }
        }

        return destination

        #elseif DEBUG

        throw fail(
            "MacBox self-updates are disabled in DEBUG builds."
        )

        #else

        return Bundle.main.bundleURL.standardizedFileURL

        #endif
    }

    // Install a MacBox update transactionally.
    // Initially enabled only for our isolated Release-Test laboratory.
    private func installMacBoxUpdateTransaction(
        downloadedFile: URL
    ) throws {

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        #if MACBOX_RELEASE_TEST

        let fm = FileManager.default

        // Never install over the running application.
        let destination = try managedMacBoxUpdateDestination()
            .standardizedFileURL

        let parent = destination.deletingLastPathComponent()

        guard destination.lastPathComponent == "MacBox-UpdateTarget.app",
              destination != Bundle.main.bundleURL.standardizedFileURL,
              destination.path == destination.resolvingSymlinksInPath().path,
              parent.path == parent.resolvingSymlinksInPath().path else {
            throw fail("Unsafe MacBox update destination.")
        }

        // Validate the downloaded archive before any extraction.
        try validateMacBoxUpdateArchive(at: downloadedFile)

        // Refuse to overwrite an interrupted installation.
        let siblings = try fm.contentsOfDirectory(
            atPath: parent.path
        )

        guard !siblings.contains(where: {
            $0.hasPrefix(".MacBox-SelfUpdate-parked-")
        }) else {
            throw fail(
                "An interrupted MacBox installation requires recovery."
            )
        }

        let identifier = UUID().uuidString

        let workspace = parent.appendingPathComponent(
            ".MacBox-SelfUpdate-work-\(identifier)",
            isDirectory: true
        )

        let extracted = workspace.appendingPathComponent(
            "extracted",
            isDirectory: true
        )

        let staged = extracted.appendingPathComponent(
            "MacBox.app",
            isDirectory: true
        )

        let parked = parent.appendingPathComponent(
            ".MacBox-SelfUpdate-parked-\(identifier).app",
            isDirectory: true
        )

        let rejected = parent.appendingPathComponent(
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

        // Extract into the temporary workspace, never the destination.
        try fm.unzipItem(at: downloadedFile, to: extracted)

        // Verify the extracted application bundle.
        guard let stagedBundle = Bundle(url: staged),
              stagedBundle.bundleIdentifier ==
                "io.github.settloe99.MacBoxReleaseTest",
              stagedBundle.object(
                forInfoDictionaryKey: "CFBundleExecutable"
              ) as? String == "MacBox" else {
            throw fail(
                "The extracted application has an unexpected identity."
            )
        }

        let executable = staged.appendingPathComponent(
            "Contents/MacOS/MacBox"
        )

        guard let executableAttributes = try? fm.attributesOfItem(
                atPath: executable.path
              ),
              executableAttributes[.type] as? FileAttributeType ==
                .typeRegular,
              fm.isExecutableFile(atPath: executable.path) else {
            throw fail(
                "The extracted MacBox executable is invalid."
            )
        }

        // Check whether a previous test application exists.
        let originalExists = fm.fileExists(
            atPath: destination.path
        )

        if originalExists {
            guard let existingBundle = Bundle(url: destination),
                  existingBundle.bundleIdentifier ==
                    "io.github.settloe99.MacBoxReleaseTest" else {
                throw fail(
                    "The existing test application is not a valid MacBox."
                )
            }

            // Preserve an independent backup before replacing anything.
            let backups = parent.appendingPathComponent(
                ".MacBox-SelfUpdate-backups",
                isDirectory: true
            )

            try fm.createDirectory(
                at: backups,
                withIntermediateDirectories: true
            )

            guard backups.path ==
                    backups.resolvingSymlinksInPath().path else {
                throw fail("Unsafe MacBox backup directory.")
            }

            let backup = backups.appendingPathComponent(
                "MacBox-\(identifier).app",
                isDirectory: true
            )

            try fm.copyItem(
                at: destination,
                to: backup
            )
        }

        var originalParked = false
        var newInstalled = false

        do {
            // Move the existing application aside.
            if originalExists {
                try fm.moveItem(
                    at: destination,
                    to: parked
                )
                originalParked = true
            }

            // Install the staged replacement.
            try fm.moveItem(
                at: staged,
                to: destination
            )
            newInstalled = true

            // Verify the installed application again.
            guard let installedBundle = Bundle(url: destination),
                  installedBundle.bundleIdentifier ==
                    "io.github.settloe99.MacBoxReleaseTest",
                  fm.isExecutableFile(
                    atPath: destination.appendingPathComponent(
                        "Contents/MacOS/MacBox"
                    ).path
                  ) else {
                throw fail(
                    "Installed MacBox failed verification."
                )
            }

            // The independent backup remains available.
            if originalParked {
                do {
                    try fm.removeItem(at: parked)
                } catch {
                    NSLog(
                        "MacBox: Retained parked application: %@",
                        parked.path
                    )
                }
            }

            NSLog(
                "MacBox: Test application installation completed."
            )

        } catch {
            let installationError = error

            // Roll back if any operation after replacement fails.
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
                    "MacBox installation and automatic rollback failed. " +
                    "The original may remain at: " +
                    parked.path +
                    ". Rollback error: " +
                    error.localizedDescription
                )
            }

            throw installationError
        }

        #else

        // Production self-updates require a verified external
        // replacement and relaunch mechanism.
        throw fail(
            "Transactional MacBox self-installation is not yet " +
            "enabled outside Release-Test."
        )

        #endif
    }

    // Prepare an already verified MacBox ZIP for the external
    // updater. Extraction is isolated from the installed app.
    private func prepareStagedMacBoxApplication(
        from downloadedZIP: URL
    ) throws -> URL {

        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        guard let caches = fm.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first?.standardizedFileURL else {
            throw fail("User cache directory unavailable.")
        }

        let stagingRoot = caches.appendingPathComponent(
            "io.github.settloe99.MacBox/StagedUpdates",
            isDirectory: true
        ).standardizedFileURL

        let archive = downloadedZIP.standardizedFileURL

        // Only accept an ordinary ZIP file previously staged
        // by our verified download workflow.
        guard archive.deletingLastPathComponent() == stagingRoot,
              archive.pathExtension.lowercased() == "zip",
              archive.path == archive.resolvingSymlinksInPath().path,
              stagingRoot.path ==
                stagingRoot.resolvingSymlinksInPath().path,
              let rootAttributes = try? fm.attributesOfItem(
                atPath: stagingRoot.path
              ),
              rootAttributes[.type] as? FileAttributeType ==
                .typeDirectory,
              let archiveAttributes = try? fm.attributesOfItem(
                atPath: archive.path
              ),
              archiveAttributes[.type] as? FileAttributeType ==
                .typeRegular else {

            throw fail("Unsafe or missing staged MacBox archive.")
        }

        // Validate ZIP contents before extracting.
        try validateMacBoxUpdateArchive(at: archive)

        let identifier = UUID().uuidString

        let extractionRoot = stagingRoot.appendingPathComponent(
            identifier,
            isDirectory: true
        )

        let application = extractionRoot.appendingPathComponent(
            "MacBox.app",
            isDirectory: true
        )

        try fm.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            // Extract only into the private staging directory.
            try fm.unzipItem(
                at: archive,
                to: extractionRoot
            )

            // Validate the extracted application's identity.
            guard application.path ==
                    application.resolvingSymlinksInPath().path,
                  let bundle = Bundle(url: application),
                  bundle.bundleIdentifier ==
                    "io.github.settloe99.MacBox",
                  bundle.object(
                    forInfoDictionaryKey: "CFBundleExecutable"
                  ) as? String == "MacBox" else {

                throw fail(
                    "The extracted application has an unexpected identity."
                )
            }

            let executable = application.appendingPathComponent(
                "Contents/MacOS/MacBox"
            )

            guard executable.path ==
                    executable.resolvingSymlinksInPath().path,
                  let attributes = try? fm.attributesOfItem(
                    atPath: executable.path
                  ),
                  attributes[.type] as? FileAttributeType ==
                    .typeRegular,
                  fm.isExecutableFile(atPath: executable.path) else {

                throw fail(
                    "The extracted MacBox executable is invalid."
                )
            }

            NSLog(
                "MacBox: Production update prepared at %@",
                application.path
            )

            return application

        } catch {
            // Remove incomplete extraction, leaving the
            // previously verified ZIP untouched.
            try? fm.removeItem(at: extractionRoot)
            throw error
        }
    }

    // Hand a verified MacBox update to the external updater.
    // The running application is never replaced directly.
    private func updateMacBoxBinary(location: URL) {

        #if DEBUG || MACBOX_RELEASE_TEST

        // Development and Release-Test builds must never
        // initiate a production application replacement.
        macboxUpdateProgressIndicator.isHidden = true
        macboxUpdateButton.isHidden = false

        NSLog(
            "MacBox: Production self-update blocked in test build."
        )

        return

        #else

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.SelfUpdater",
                code: 6,
                userInfo: [
                    NSLocalizedDescriptionKey: message
                ]
            )
        }

        do {
            let fm = FileManager.default

            let destination = Bundle.main.bundleURL
                .standardizedFileURL

            // Only our production application can initiate
            // a production update.
            guard Bundle.main.bundleIdentifier ==
                    "io.github.settloe99.MacBox",
                  destination.lastPathComponent == "MacBox.app" else {

                throw fail(
                    "This is not a production MacBox installation."
                )
            }

            let helper = destination.appendingPathComponent(
                "Contents/Helpers/MacBoxSelfUpdateHelper"
            )

            guard helper.path ==
                    helper.resolvingSymlinksInPath().path,
                  fm.isExecutableFile(atPath: helper.path) else {

                throw fail(
                    "The external MacBox updater helper is missing."
                )
            }

            // Verify an application using the helper's
            // trusted Developer ID signing requirement.
            func verifyProductionApplication(_ app: URL) throws {

                let verification = Process()
                verification.executableURL = helper

                verification.arguments = [
                    "--verify-production-app",
                    app.path
                ]

                try verification.run()
                verification.waitUntilExit()

                guard verification.terminationStatus == 0 else {
                    throw fail(
                        "Production application authentication failed. " +
                        "The update has been cancelled. " +
                        "A trusted Developer ID signing identity " +
                        "must be configured before automatic " +
                        "updates can be enabled."
                    )
                }
            }

            // Authenticate the currently installed application
            // before preparing a replacement.
            try verifyProductionApplication(destination)

            // Extract the downloaded ZIP into our private
            // staging directory.
            let stagedApplication =
                try prepareStagedMacBoxApplication(
                    from: location
                )

            // Authenticate the extracted replacement.
            try verifyProductionApplication(stagedApplication)

            // Both applications must pass authentication
            // before the user is offered installation.
            let confirmation = NSAlert()
            confirmation.alertStyle = .warning
            confirmation.messageText = "Install MacBox update?"

            confirmation.informativeText = """
            The downloaded MacBox update has passed archive,
            checksum and application signature verification.

            MacBox will now close while its external updater
            installs the replacement.

            The existing application will be backed up before
            replacement, and the updated application will
            launch automatically.

            Destination:
            \(destination.path)
            """

            confirmation.addButton(
                withTitle: "Update and Restart"
            )

            confirmation.addButton(
                withTitle: "Cancel"
            )

            guard confirmation.runModal() ==
                    .alertFirstButtonReturn else {

                macboxUpdateProgressIndicator.isHidden = true
                macboxUpdateButton.isHidden = false
                return
            }

            // Launch the independent updater.
            // It will wait for this MacBox process to exit.
            let updater = Process()
            updater.executableURL = helper

            updater.arguments = [
                "--install-production",
                String(ProcessInfo.processInfo.processIdentifier),
                stagedApplication.path,
                destination.path
            ]

            try updater.run()

            NSLog(
                "MacBox: External production updater launched."
            )

            // The helper now owns installation and relaunch.
            NSApp.terminate(nil)

        } catch {

            macboxUpdateProgressIndicator.isHidden = true
            macboxUpdateButton.isHidden = false

            NSLog(
                "MacBox: Self-update preparation failed: %@",
                error.localizedDescription
            )

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "MacBox update cancelled"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        #endif
    }

    // Delete a temporary file
    private func deleteTmpFile(url: URL) {
        let filePath = url.path
        do {
            try fileManager.removeItem(at: URL(fileURLWithPath:filePath))
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

// ------------------------------------
// IBActions
// ------------------------------------

    // 86Box update button action
    @IBAction func emulatorUpdateButtonAction(_ sender: NSButton) {
        guard updaterPermitted(.emulator) else { return }

        emulatorUpdateButton.isHidden = true
        emulatorUpdateProgressIndicator.isHidden = false
        fetchEmulatorUpdateBinary()
    }

    // 86Box ROMs update button action
    @IBAction func romsUpdateButtonAction(_ sender: NSButton) {
        #if MACBOX_RELEASE_TEST
        let expectedDestination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("MacBox-ReleaseTest/ROMs-Lab/roms", isDirectory: true)
            .standardizedFileURL

        do {
            let actualDestination = try managedRomsDestination().standardizedFileURL

            guard actualDestination == expectedDestination else {
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "ROM laboratory destination mismatch"
                alert.informativeText = """
                Expected:
                \(expectedDestination.path)

                Actual:
                \(actualDestination.path)

                The update has been cancelled.
                """
                alert.runModal()
                return
            }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Release-Test ROM installation"
            alert.informativeText = """
            ROMs will be installed into the isolated test laboratory:

            \(actualDestination.path)

            Your normal ROM installation will not be modified.
            """
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "ROM destination validation failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        #endif

        romsUpdateButton.isHidden = true
        romsUpdateProgressIndicator.isHidden = false

        // Download the exact ROM revision identified by the update check.
        fetchRomsUpdateFile()
    }

    // MacBox update button action
    @IBAction func macboxUpdateButtonAction(_ sender: NSButton) {
        guard updaterPermitted(.macbox) else { return }

        macboxUpdateButton.isHidden = true
        macboxUpdateProgressIndicator.isHidden = false
        fetchMacBoxUpdateBinary()
    }

}

// ------------------------------------
// URLSessionDownload Delegate
// ------------------------------------

extension VersionManagerViewController: URLSessionDownloadDelegate {

    // Handle files download
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let info = downloadTasks.first(where: {
            $0.downloadTask == downloadTask
        }) else {
            return
        }

        if info.type == .emulator {
            let response = downloadTask.response as? HTTPURLResponse
            let statusCode = response?.statusCode ?? 0
            let contentType = response?
                .value(forHTTPHeaderField: "Content-Type") ?? "Unknown"

            // Check the actual ZIP signature, not the filename.
            let signature: Data? = {
                guard let handle = try? FileHandle(forReadingFrom: location)
                else {
                    return nil
                }

                defer { handle.closeFile() }
                return handle.readData(ofLength: 4)
            }()

            let validZip = signature == Data([0x50, 0x4B, 0x03, 0x04])

            guard statusCode == 200 && validZip else {
                NSLog(
                    "MacBox: Invalid emulator download. HTTP %d, type: %@",
                    statusCode,
                    contentType
                )

                info.progressIndicator.isHidden = true
                info.updateButton.isHidden = false

                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "86Box download failed"
                alert.informativeText = """
                The update server did not return a valid ZIP archive.

                HTTP status: \(statusCode)
                Content type: \(contentType)

                The existing 86Box installation has not been changed.
                """
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }

            updateEmulatorBinary(location: location)

        } else if info.type == .roms {
            updateRomsFile(location: location)

        } else if info.type == .macbox {

            do {
                let statusCode = (
                    downloadTask.response as? HTTPURLResponse
                )?.statusCode ?? 0

                guard statusCode == 200 else {
                    throw NSError(
                        domain: "MacBox.Download",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Download returned HTTP \(statusCode)."
                        ]
                    )
                }

                guard let expectedSHA256 = downloadTask.taskDescription,
                      expectedSHA256.range(
                        of: "^[0-9a-f]{64}$",
                        options: .regularExpression
                      ) != nil else {

                    throw NSError(
                        domain: "MacBox.Download",
                        code: 3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Expected SHA-256 digest is missing."
                        ]
                    )
                }

                let actualSHA256 = try macBoxDownloadSHA256(
                    at: location
                )

                guard actualSHA256 == expectedSHA256 else {
                    throw NSError(
                        domain: "MacBox.Download",
                        code: 4,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "MacBox download checksum mismatch. " +
                                "The package has been rejected."
                        ]
                    )
                }

                let handle = try FileHandle(
                    forReadingFrom: location
                )

                let signature = handle.readData(ofLength: 4)
                handle.closeFile()

                guard signature ==
                    Data([0x50, 0x4B, 0x03, 0x04]) else {

                    throw NSError(
                        domain: "MacBox.Download",
                        code: 5,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "The download is not a valid ZIP package."
                        ]
                    )
                }

                // Verify archive contents after the SHA-256 check.
                // Reject malformed archives before installation.
                try validateMacBoxUpdateArchive(at: location)

                NSLog(
                    "MacBox: Release checksum and archive structure verified."
                )

                // Preserve the verified download before URLSession
                // removes its temporary file.
                let stagedUpdate = try stageVerifiedMacBoxDownload(
                    from: location,
                    expectedSHA256: expectedSHA256
                )

                // Production installation remains disabled until
                // the authenticated external helper is connected.
                updateMacBoxBinary(location: stagedUpdate)

            } catch {

                macboxUpdateProgressIndicator.isHidden = true
                macboxUpdateButton.isHidden = false

                NSLog(
                    "MacBox: Download verification failed: %@",
                    error.localizedDescription
                )

                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "MacBox download rejected"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }

    }

    // Handle download progress
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let info = downloadTasks.first(where: { $0.downloadTask == downloadTask }) {
            var progress: Float = 0
            if totalBytesExpectedToWrite > 0 {
                // Known file size
                progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
            }
            else {
                // Unknown file size (Usually, it's the ROMs github zip file); set 50MB by default
                progress = Float(totalBytesWritten) / Float(52428800)
            }

            DispatchQueue.main.async {
                info.progressIndicator.doubleValue = Double(progress * 100.0)
            }
        }
    }

    // Handle download error
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let info = downloadTasks.first(where: { $0.downloadTask == task }),
              let error = error
        else {
            return
        }

        info.progressIndicator.isHidden = true
        info.updateButton.isHidden = false

        print("Error: \(error.localizedDescription)")
    }
}
