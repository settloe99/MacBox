//
//  VersionManagerViewController.swift
//  MacBox
//
//  Created by Moonif on 1/15/24.
//

import Cocoa
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
                romsUpdateButton.isEnabled = false
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

    // Populate MacBox update info
    private func populateMacBoxUpdateInfo() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        dateFormatter.dateFormat = dateInputFormatString
        let date: Date? = dateFormatter.date(from: versionInfoObject.macboxUpdateObject?.published_at ?? "")
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

        macboxUpdateDateTextField.stringValue = relativeDate
        macboxUpdateDateTextField.toolTip = formattedDate

        macboxReleaseNoteTextView.string = versionInfoObject.macboxUpdateObject?.body ?? "-"
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

        // Set button label if 86Box is not installed
        if versionInfoObject.emulatorAutoUrl == nil && versionInfoObject.emulatorCustomUrl == nil {
            emulatorUpdateButton.title = NSLocalizedString("Install", comment: "")
        }
        else {
            emulatorUpdateButton.title = NSLocalizedString("Update", comment: "")
        }

        // Compare 86Box ROMs version
        if let romsShaVersion = versionInfoObject.romsUpdateObject?.sha {
            if let localShaVersion = userDefaults.string(forKey: "romsShaVersion") {
                if localShaVersion == String(romsShaVersion) && !versionInfoObject.romsUrls.isEmpty {
                    romsUpdateButton.isHidden = true
                    romsUpdateCheckImageView.isHidden = false
                }
            }
        }

        // Set button label if 86Box ROMs are not installed
        if versionInfoObject.romsUrls.isEmpty {
            romsUpdateButton.title = NSLocalizedString("Install", comment: "")
        }
        else {
            romsUpdateButton.title = NSLocalizedString("Update", comment: "")
        }

        // Compare MacBox version
        if let macboxOnlineVersion = versionInfoObject.macboxUpdateObject?.tag_name {
            let localBuildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? String(macboxOnlineVersion)

            if localBuildVersion == String(macboxOnlineVersion) {
                macboxUpdateButton.isHidden = true
                macboxUpdateCheckImageView.isHidden = false
            }
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

            // Validate metadata, Apple Silicon compatibility and signature.
            func verify(_ app: URL) throws -> (String, String) {
                try requireRealDirectory(app)

                let plistURL = app.appendingPathComponent(
                    "Contents/Info.plist"
                )
                let data = try Data(contentsOf: plistURL)
                guard let info = try PropertyListSerialization.propertyList(
                    from: data, format: nil
                ) as? [String: Any],
                    info["CFBundleIdentifier"] as? String == "net.86Box.86Box",
                    let version = info["CFBundleShortVersionString"] as? String,
                    let fullBuild = info["CFBundleVersion"] as? String,
                    let build = fullBuild.split(separator: ".").last
                else {
                    throw fail("Invalid 86Box application metadata.")
                }

                let executable = app.appendingPathComponent(
                    "Contents/MacOS/86Box"
                )

                for (tool, arguments) in [
                    ("/usr/bin/codesign", ["--verify", app.path]),
                    ("/usr/bin/lipo", [
                        "-verify_arch", "arm64", executable.path
                    ])
                ] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: tool)
                    process.arguments = arguments
                    try process.run()
                    process.waitUntilExit()

                    guard process.terminationStatus == 0 else {
                        throw fail("Verification failed: \(tool)")
                    }
                }

                return (version, String(build))
            }

            // Never trust an application preference for this destination.
            try requireRealDirectory(root)

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
                    if fm.fileExists(atPath: installed.path) {
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

    // Fetch 86Box ROMs file
    private func fetchRomsUpdateFile() {
        if let url = URL(string: "https://api.github.com/repos/86Box/roms/zipball/master") {
            downloadRomsFile(url: url)
        }
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

    // Update 86Box ROMs with the new version
    private func updateRomsFile(location: URL) {
        #if DEBUG || MACBOX_RELEASE_TEST
        NSLog("MacBoxDev: ROM installation blocked.")
        return
        #endif

        var versionInfoObject = MainViewController.instance.versionInfoObject

        var tempURL = homeDirURL
        tempURL.appendPathComponent("tmp")

        var fileURL = tempURL
        fileURL.appendPathComponent(location.lastPathComponent + ".zip")

        var unzippedRomsFileURL = tempURL
        unzippedRomsFileURL.appendPathComponent("roms")

        do {
            // Create the tmp directory
            try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
            // Move the downloaded file into the tmp directory
            try fileManager.moveItem(at: location, to: URL(fileURLWithPath: fileURL.path))
            // Unzip the file
            try fileManager.unzipItem(at: fileURL, to: unzippedRomsFileURL)
            // Get the unzipped folder
            let unzippedItems = try fileManager.contentsOfDirectory(atPath: unzippedRomsFileURL.path)
            for item in unzippedItems {
                if item.hasPrefix("86Box-roms") {
                    var unzippedRomsFolderURL = unzippedRomsFileURL
                    unzippedRomsFolderURL.appendPathComponent(item)

                    if versionInfoObject.romsUrls.isEmpty {
                        // 86Box ROMs are not installed; install them in the user application support directory
                        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: [.userDomainMask])
                        if var romsDirPath = appSupportDir.first {
                            romsDirPath.appendPathComponent("net.86box.86Box/roms")
                            // Create the 86Box ROMs directory
                            try fileManager.createDirectory(at: romsDirPath, withIntermediateDirectories: true, attributes: nil)
                            // Move the updated ROMs directory to the user's application support
                            let _ = try fileManager.replaceItemAt(romsDirPath, withItemAt: unzippedRomsFolderURL)
                            // Set user defaults
                            if let romsSha = versionInfoObject.romsUpdateObject?.sha {
                                userDefaults.set(romsSha, forKey: "romsShaVersion")
                            }
                            // Update version info
                            versionInfoObject.romsUrls.append(romsDirPath)
                        }
                    }
                    else {
                        // Replace the ROMs directory with the updated one
                        for romsURL in versionInfoObject.romsUrls {
                            let _ = try fileManager.replaceItemAt(romsURL, withItemAt: unzippedRomsFolderURL)
                            // Set user defaults
                            if let romsSha = versionInfoObject.romsUpdateObject?.sha {
                                userDefaults.set(romsSha, forKey: "romsShaVersion")
                            }
                        }
                    }

                    // Delete temporary file
                    deleteTmpFile(url: fileURL)

                    // Update version info
                    MainViewController.instance.checkFor86Box(url: emulatorUpdatedURL, appVer: emulatorUpdatedAppVer, buildVer: emulatorUpdatedBuildVer)

                    break
                }
            }

            // Update buttons status
            romsUpdateProgressIndicator.isHidden = true
            romsUpdateButton.isHidden = true
            romsUpdateCheckImageView.isHidden = false
        } catch {
            print("Error: \(error.localizedDescription)")

            romsUpdateProgressIndicator.isHidden = true
            romsUpdateButton.isHidden = false
        }
    }

    // Fetch MacBox updated macOS binary
    private func fetchMacBoxUpdateBinary() {
        let versionInfoObject = MainViewController.instance.versionInfoObject

        for asset in versionInfoObject.macboxUpdateObject?.assets ?? [] {
            guard let downloadURL = asset.browser_download_url,
                  let url = URL(string: downloadURL) else {
                continue
            }
            downloadMacBoxBinary(url: url)
        }
    }

    // Download MacBox binary
    private func downloadMacBoxBinary(url: URL) {
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: OperationQueue.main)

        let downloadTask = session.downloadTask(with: url)

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

    // Update MacBox binary with the new version
    private func updateMacBoxBinary(location: URL) {
        #if DEBUG || MACBOX_RELEASE_TEST
        NSLog("MacBoxDev: application self-update blocked.")
        return
        #endif

        var tempURL = homeDirURL
        tempURL.appendPathComponent("tmp")

        var fileURL = tempURL
        fileURL.appendPathComponent(location.lastPathComponent + ".zip")

        var unzippedMacBoxFileURL = tempURL
        unzippedMacBoxFileURL.appendPathComponent("MacBox.app")

        do {
            // Create the tmp directory
            try fileManager.createDirectory(at: tempURL, withIntermediateDirectories: true, attributes: nil)
            // Move the downloaded file into the tmp directory
            try fileManager.moveItem(at: location, to: URL(fileURLWithPath: fileURL.path))
            // Unzip the file
            try fileManager.unzipItem(at: fileURL, to: tempURL)

            let macboxAppURL = Bundle.main.bundleURL
            let _ = try fileManager.replaceItemAt(macboxAppURL, withItemAt: unzippedMacBoxFileURL)

            // Delete temporary file
            deleteTmpFile(url: fileURL)

            // Update buttons status
            macboxUpdateProgressIndicator.isHidden = true
            macboxUpdateButton.isHidden = true
            macboxUpdateCheckImageView.isHidden = false

            // Prompt the user to restart the app
            let alert = NSAlert()

            alert.messageText = NSLocalizedString("MacBox will now restart in order to apply the update", comment: "")
            alert.alertStyle = .critical
            alert.addButton(withTitle: NSLocalizedString("Restart", comment: ""))

            // Show the alert
            let alertResult = alert.runModal()
            let taskLaunchPath = "/usr/bin/open"

            if alertResult == .alertFirstButtonReturn {
                let macboxAppPath = Bundle.main.bundlePath
                let task = Process()
                task.launchPath = taskLaunchPath
                task.arguments = [macboxAppPath]
                task.launch()
                exit(0)
            }
        } catch {
            print("Error: \(error.localizedDescription)")

            macboxUpdateProgressIndicator.isHidden = true
            macboxUpdateButton.isHidden = false
        }
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
        guard updaterPermitted(.roms) else { return }

        romsUpdateButton.isHidden = true
        romsUpdateProgressIndicator.isHidden = false
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

        } else {
            updateMacBoxBinary(location: location)
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
