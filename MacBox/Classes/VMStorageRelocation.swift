import Foundation
import CryptoKit
import Darwin

struct VMStorageRelocationPlan {

    struct Item {
        let source: URL
        let destination: URL
    }

    let source: URL
    let destination: URL
    let items: [Item]
    let updatedVMs: [VM]

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "MacBox.StorageRelocation",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: message
            ]
        )
    }

    // Use complete path components, not string prefixes.
    // Case-insensitive comparison deliberately errs on
    // the side of caution on case-sensitive volumes.
    private static func contains(
        _ root: URL,
        _ candidate: URL
    ) -> Bool {

        let parent = root.pathComponents
        let child = candidate.pathComponents

        guard child.count >= parent.count else {
            return false
        }

        return zip(parent, child).allSatisfy {
            $0.0.caseInsensitiveCompare($0.1) == .orderedSame
        }
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

            throw failure(
                "Missing or unsafe directory: \(url.path)"
            )
        }
    }

    // Construct a relocation plan without modifying any files.
    static func make(
        source: URL,
        destination: URL,
        vms: [VM]
    ) throws -> VMStorageRelocationPlan {

        let fm = FileManager.default

        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL

        try requireDirectory(source)
        try requireDirectory(destination)

        guard !contains(source, destination),
              !contains(destination, source) else {

            throw failure(
                "The storage locations must be separate directories."
            )
        }

        let destinationNames = try fm.contentsOfDirectory(
            atPath: destination.path
        )

        var reservedNames = Set(
            destinationNames.map { $0.lowercased() }
        )

        // Never overwrite another MacBox configuration.
        guard !reservedNames.contains("config") else {
            throw failure(
                "The destination already contains a Config file."
            )
        }

        reservedNames.insert("config")

        var items: [Item] = []
        var updatedVMs = vms
        var sourceNames = Set<String>()

        let retained = try retainedDirectoryNames(
            in: destination
        )

        for index in vms.indices {

            guard let path = vms[index].path,
                  path.hasPrefix("/") else {

                throw failure(
                    "A registered VM has an invalid storage path."
                )
            }

            let vmURL = URL(
                fileURLWithPath: path,
                isDirectory: true
            ).standardizedFileURL

            // External VMs remain registered but are not moved.
            if !contains(source, vmURL) {

                // Reject an apparently external path that
                // resolves through a link into managed storage.
                guard !contains(
                    source,
                    vmURL.resolvingSymlinksInPath()
                ) else {

                    throw failure(
                        "A VM uses an ambiguous storage path."
                    )
                }

                continue
            }

            // Only registered, direct-child VM directories
            // are eligible for relocation.
            guard vmURL.deletingLastPathComponent().path ==
                    source.path else {

                throw failure(
                    "Unsupported nested or ambiguous VM path: \(path)"
                )
            }

            try requireDirectory(vmURL)

            let configuration = vmURL.appendingPathComponent(
                "86box.cfg"
            )

            guard configuration.path ==
                    configuration.resolvingSymlinksInPath().path,
                  let attributes = try? fm.attributesOfItem(
                    atPath: configuration.path
                  ),
                  attributes[.type] as? FileAttributeType ==
                    .typeRegular else {

                throw failure(
                    "Registered VM configuration missing or unsafe: \(path)"
                )
            }

            let name = vmURL.lastPathComponent
            let collisionKey = name.lowercased()

            guard sourceNames.insert(collisionKey).inserted else {
                throw failure("Duplicate registered VM: \(name)")
            }

            var destinationName = name

            if reservedNames.contains(collisionKey) {

                // Only recorded recovery directories qualify
                // for alternative naming.
                guard retained.contains(name) else {

                    throw failure(
                        "Destination conflict: \(name)"
                    )
                }

                var number = 1

                repeat {
                    destinationName =
                        "\(name) (Relocated \(number))"
                    number += 1

                } while reservedNames.contains(
                    destinationName.lowercased()
                )
            }

            reservedNames.insert(
                destinationName.lowercased()
            )

            let newURL = destination.appendingPathComponent(
                destinationName,
                isDirectory: true
            )

            items.append(
                Item(
                    source: vmURL,
                    destination: newURL
                )
            )

            updatedVMs[index].path = newURL.path
        }

        return VMStorageRelocationPlan(
            source: source,
            destination: destination,
            items: items,
            updatedVMs: updatedVMs
        )
    }
}

extension VMStorageRelocationPlan {

    struct PreparedRelocation {
        let plan: VMStorageRelocationPlan
        let workspace: URL
    }

    // Prepare verified destination copies without modifying
    // the original VM library or its configuration.
    func prepareRelocation() throws -> PreparedRelocation {

        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.StorageRelocation",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let originalConfig = source.appendingPathComponent("Config")

        guard originalConfig.path ==
                originalConfig.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: originalConfig.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular else {
            throw fail("The original MacBox configuration is missing or unsafe.")
        }

        // Ensure that the saved configuration is readable before
        // preparing any replacement files.
        let configData = try Data(contentsOf: originalConfig)

        let originalVMs = try JSONDecoder().decode(
            [VM].self,
            from: configData
        )

        // Rebuild the plan from the saved configuration.
        // This detects changes since the original plan was created.
        let freshPlan = try Self.make(
            source: source,
            destination: destination,
            vms: originalVMs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        guard try encoder.encode(freshPlan.updatedVMs) ==
                    encoder.encode(updatedVMs),
              freshPlan.items.map({ $0.source.path }) ==
                    items.map({ $0.source.path }) else {

            throw fail(
                "The VM configuration has changed. Please retry relocation."
            )
        }

        let workspace = destination.appendingPathComponent(
            ".MacBox-Relocation-\(UUID().uuidString)",
            isDirectory: true
        )

        try fm.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {

            // External VMs remain in their existing locations.
            // Abort if their media depends on relocated VM data.
            for vm in originalVMs {

                guard let path = vm.path else {
                    continue
                }

                let vmURL = URL(
                    fileURLWithPath: path,
                    isDirectory: true
                ).standardizedFileURL

                if items.contains(where: {
                    $0.source.path == vmURL.path
                }) {
                    continue
                }

                let config = vmURL.appendingPathComponent(
                    "86box.cfg"
                )

                let text = try String(
                    contentsOf: config,
                    encoding: .utf8
                )

                _ = try rewriteMediaReferences(
                    in: text,
                    originalVM: vmURL,
                    relocatedVM: nil
                )
            }

            for item in items {

                let staged = workspace.appendingPathComponent(
                    item.destination.lastPathComponent,
                    isDirectory: true
                )

                let before = try Self.storageSnapshot(item.source)

                try fm.copyItem(at: item.source, to: staged)

                let copied = try Self.storageSnapshot(staged)
                let after = try Self.storageSnapshot(item.source)

                guard before == copied,
                      before == after else {

                    throw fail(
                        "VM copy verification failed: " +
                        item.source.lastPathComponent
                    )
                }

                // Only rewrite the verified destination copy.
                let stagedConfig = staged.appendingPathComponent(
                    "86box.cfg"
                )

                let originalText = try String(
                    contentsOf: stagedConfig,
                    encoding: .utf8
                )

                let updatedText = try rewriteMediaReferences(
                    in: originalText,
                    originalVM: item.source,
                    relocatedVM: item.destination
                )

                if updatedText != originalText {

                    try Data(updatedText.utf8).write(
                        to: stagedConfig,
                        options: .atomic
                    )

                    guard try String(
                        contentsOf: stagedConfig,
                        encoding: .utf8
                    ) == updatedText else {

                        throw fail(
                            "Updated VM media references could not be verified."
                        )
                    }
                }

            }

            guard try Data(contentsOf: originalConfig) ==
                        configData else {
                throw fail("The original configuration changed during relocation.")
            }

            let newConfig = workspace.appendingPathComponent("Config")

            try encoder.encode(updatedVMs).write(
                to: newConfig,
                options: .atomic
            )

            let decoded = try JSONDecoder().decode(
                [VM].self,
                from: Data(contentsOf: newConfig)
            )

            guard try encoder.encode(decoded) ==
                        encoder.encode(updatedVMs) else {
                throw fail("Replacement configuration verification failed.")
            }

            return PreparedRelocation(
                plan: self,
                workspace: workspace
            )

        } catch {

            // Only discard the private workspace created
            // by this preparation attempt.
            try? fm.removeItem(at: workspace)

            throw error
        }
    }

    private struct StorageEntry: Equatable {
        let isDirectory: Bool
        let digest: String
    }

    // Compare file contents without loading entire virtual
    // hard disk images into memory.
    private static func storageSnapshot(
        _ root: URL
    ) throws -> [String: StorageEntry] {

        let fm = FileManager.default

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.StorageRelocation",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        guard root.path ==
                root.resolvingSymlinksInPath().path,
              let rootAttributes = try? fm.attributesOfItem(
                atPath: root.path
              ),
              rootAttributes[.type] as? FileAttributeType ==
                .typeDirectory else {
            throw fail("Unsafe VM directory.")
        }

        var enumerationError: Error?

        guard let entries = fm.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw fail("Cannot inspect VM directory.")
        }

        var result: [String: StorageEntry] = [:]

        for case let entry as URL in entries {

            let entry = entry.standardizedFileURL
            let relative = entry.pathComponents
                .dropFirst(root.pathComponents.count)
                .joined(separator: "/")

            let attributes = try fm.attributesOfItem(
                atPath: entry.path
            )

            let type = attributes[.type] as? FileAttributeType

            guard !relative.isEmpty,
                  result[relative] == nil,
                  entry.path ==
                    entry.resolvingSymlinksInPath().path else {
                throw fail("Unsafe entry: \(entry.path)")
            }

            if type == .typeDirectory {

                result[relative] = StorageEntry(
                    isDirectory: true,
                    digest: ""
                )

            } else if type == .typeRegular {

                let handle = try FileHandle(
                    forReadingFrom: entry
                )

                defer {
                    try? handle.close()
                }

                var hasher = SHA256()

                while let data = try handle.read(
                    upToCount: 1024 * 1024
                ), !data.isEmpty {

                    hasher.update(data: data)
                }

                let digest = hasher.finalize()
                    .map { String(format: "%02x", $0) }
                    .joined()

                result[relative] = StorageEntry(
                    isDirectory: false,
                    digest: digest
                )

            } else {

                throw fail(
                    "Unsupported file or symbolic link: \(entry.path)"
                )
            }
        }

        if let error = enumerationError {
            throw error
        }

        return result
    }
}

extension VMStorageRelocationPlan {

    // Rewrite recognised 86Box media references without
    // changing unrelated settings or configuration sections.
    func rewriteMediaReferences(
        in configuration: String,
        originalVM: URL,
        relocatedVM: URL?
    ) throws -> String {

        func fail(_ message: String) -> NSError {
            NSError(
                domain: "MacBox.StorageRelocation",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let originalVM = originalVM.standardizedFileURL

        let expression = try NSRegularExpression(
            pattern: #"(?m)^[ \t]*(?:hdd_[0-9]+_fn|fdd_[0-9]+_fn|cdrom_[0-9]+_image_path|(?:fdd|cdrom)_[0-9]+_image_history_[0-9]+)[ \t]*=[ \t]*([^\r\n]*)"#,
            options: [.caseInsensitive]
        )

        let original = configuration as NSString
        let result = NSMutableString(string: configuration)

        let matches = expression.matches(
            in: configuration,
            range: NSRange(
                location: 0,
                length: original.length
            )
        )

        // Process backwards so earlier character ranges
        // remain valid after replacements.
        for match in matches.reversed() {

            let range = match.range(at: 1)

            let existingValue = original.substring(
                with: range
            )

            var value = existingValue.trimmingCharacters(
                in: .whitespaces
            )

            guard !value.isEmpty else {
                continue
            }

            // Preserve the 86Box write-protection prefix.
            var prefix = ""

            if value.hasPrefix("wp://") {
                prefix = "wp://"
                value = String(value.dropFirst(5))
            }

            // These references are independent of the VM's
            // storage location.
            if value.hasPrefix("<exe_path>/") ||
                value.hasPrefix("ioctl://") {
                continue
            }

            guard !value.isEmpty,
                  !value.contains("://"),
                  !value.contains("\\"),
                  !value.hasPrefix("~"),
                  !value.hasPrefix("\""),
                  !value.hasSuffix("\""),
                  value.range(
                    of: #"^[A-Za-z]:"#,
                    options: .regularExpression
                  ) == nil else {

                throw fail(
                    "Unsupported media reference: \(value)"
                )
            }

            let isAbsolute = value.hasPrefix("/")

            let originalTarget = URL(
                fileURLWithPath: isAbsolute
                    ? value
                    : originalVM.path + "/" + value
            ).standardizedFileURL

            // Check whether this media belongs to any VM
            // participating in the relocation.
            let matchingItem = items.first {
                Self.contains($0.source, originalTarget)
            }

            let resolvedTarget =
                originalTarget.resolvingSymlinksInPath()

            if matchingItem == nil &&
                items.contains(where: {
                    Self.contains($0.source, resolvedTarget)
                }) {

                throw fail(
                    "Media references relocated storage through a symbolic link."
                )
            }

            // An external VM must not silently lose access
            // to media inside a relocated VM directory.
            if relocatedVM == nil {

                if matchingItem != nil {
                    throw fail(
                        "An external VM references media inside a VM being relocated."
                    )
                }

                continue
            }

            let replacement: String

            if let item = matchingItem {

                let sourceComponents =
                    item.source.pathComponents

                let targetComponents =
                    originalTarget.pathComponents

                guard targetComponents.count >
                        sourceComponents.count,
                      Array(
                        targetComponents.prefix(
                            sourceComponents.count
                        )
                      ) == sourceComponents,
                      originalTarget.path ==
                        resolvedTarget.path else {

                    throw fail(
                        "Ambiguous managed media reference: \(value)"
                    )
                }

                let suffix = targetComponents
                    .dropFirst(sourceComponents.count)
                    .joined(separator: "/")

                if !isAbsolute &&
                    item.source.path == originalVM.path {

                    // Media inside its own VM remains relative.
                    replacement = suffix

                } else {

                    // Absolute internal paths and references
                    // between relocated VMs follow their data.
                    replacement = item.destination
                        .appendingPathComponent(suffix)
                        .path
                }

            } else if isAbsolute {

                // External absolute paths remain unchanged.
                continue

            } else {

                // Relative external paths must continue
                // pointing to their original location.
                replacement = originalTarget.path
            }

            let finalValue = prefix + replacement

            guard finalValue.utf8.count <= 500 else {
                throw fail(
                    "Relocated media path is too long for safe use."
                )
            }

            if finalValue != existingValue {
                result.replaceCharacters(
                    in: range,
                    with: finalValue
                )
            }
        }

        return result as String
    }
}

extension VMStorageRelocationPlan {

    private struct PublicationIdentity: Codable, Equatable {
        let device: Int64
        let inode: UInt64
    }

    private struct PublicationEntry: Codable, Equatable {
        let name: String
        let identity: PublicationIdentity
    }

    private struct RetirementRecord: Codable, Equatable {
        let source: String
        let configIdentity: PublicationIdentity
        let configDigest: String
        let directories: [PublicationEntry]
    }

    private struct PublicationJournal: Codable {
        let source: String
        let destination: String
        let entries: [PublicationEntry]
        let retirement: RetirementRecord
    }

    private static func publicationFailure(
        _ message: String
    ) -> NSError {

        NSError(
            domain: "MacBox.StorageRelocation",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func publicationIdentity(
        _ url: URL
    ) throws -> PublicationIdentity {

        var information = stat()

        guard url.path.withCString({
            Darwin.lstat($0, &information)
        }) == 0 else {

            throw publicationFailure(
                "Cannot identify relocation item: \(url.path)"
            )
        }

        return PublicationIdentity(
            device: Int64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    // Publish an item without ever overwriting an
    // existing destination file or directory.
    private static func exclusiveRename(
        from source: URL,
        to destination: URL
    ) throws {

        let result = source.path.withCString { oldPath in
            destination.path.withCString { newPath in

                renamex_np(
                    oldPath,
                    newPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }

        if result != 0 {

            let errorCode = errno

            throw publicationFailure(
                "Cannot relocate \(source.lastPathComponent): " +
                String(cString: strerror(errorCode))
            )
        }
    }

    // Publish the prepared library. The original library
    // remains untouched until a later transaction stage.
    //
    // The optional callback is used by our acceptance tests
    // to simulate a failure during publication.
    static func publish(
        _ prepared: PreparedRelocation,
        beforeMove: ((Int) throws -> Void)? = nil
    ) throws {

        let plan = prepared.plan
        let workspace = prepared.workspace

        try requireDirectory(plan.source)
        try requireDirectory(plan.destination)
        try requireDirectory(workspace)

        guard workspace.deletingLastPathComponent().path ==
                plan.destination.path,
              workspace.lastPathComponent.hasPrefix(
                ".MacBox-Relocation-"
              ) else {

            throw publicationFailure(
                "Invalid relocation workspace."
            )
        }

        let originalConfig = plan.source
            .appendingPathComponent("Config")

        let originalData = try Data(
            contentsOf: originalConfig
        )

        let originalVMs = try JSONDecoder().decode(
            [VM].self,
            from: originalData
        )

        // Recheck destination conflicts and configuration
        // changes before publishing anything.
        let freshPlan = try make(
            source: plan.source,
            destination: plan.destination,
            vms: originalVMs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let expectedConfig = try encoder.encode(
            plan.updatedVMs
        )

        guard try encoder.encode(freshPlan.updatedVMs) ==
                    expectedConfig,
              freshPlan.items.map({ $0.source.path }) ==
                    plan.items.map({ $0.source.path }) else {

            throw publicationFailure(
                "The original VM configuration has changed."
            )
        }

        // Revalidate the prepared VM data and rewritten
        // configurations before making them visible.
        for item in plan.items {

            let staged = workspace.appendingPathComponent(
                item.destination.lastPathComponent
            )

            var originalSnapshot = try storageSnapshot(
                item.source
            )

            var stagedSnapshot = try storageSnapshot(
                staged
            )

            originalSnapshot.removeValue(
                forKey: "86box.cfg"
            )

            stagedSnapshot.removeValue(
                forKey: "86box.cfg"
            )

            guard originalSnapshot == stagedSnapshot else {

                throw publicationFailure(
                    "VM data changed during preparation: " +
                    item.source.lastPathComponent
                )
            }

            let originalText = try String(
                contentsOf: item.source.appendingPathComponent(
                    "86box.cfg"
                ),
                encoding: .utf8
            )

            let expectedText = try plan.rewriteMediaReferences(
                in: originalText,
                originalVM: item.source,
                relocatedVM: item.destination
            )

            let stagedText = try String(
                contentsOf: staged.appendingPathComponent(
                    "86box.cfg"
                ),
                encoding: .utf8
            )

            guard expectedText == stagedText else {

                throw publicationFailure(
                    "Prepared VM configuration has changed."
                )
            }
        }

        let stagedConfig = workspace
            .appendingPathComponent("Config")

        let decodedConfig = try JSONDecoder().decode(
            [VM].self,
            from: Data(contentsOf: stagedConfig)
        )

        guard try encoder.encode(decodedConfig) ==
                    expectedConfig else {

            throw publicationFailure(
                "Prepared library configuration is invalid."
            )
        }

        guard try Data(contentsOf: originalConfig) ==
                    originalData else {

            throw publicationFailure(
                "Original configuration changed during verification."
            )
        }

        // Config is always published last.
        let names = plan.items.map {
            $0.destination.lastPathComponent
        } + ["Config"]

        let entries = try names.map { name in

            PublicationEntry(
                name: name,
                identity: try publicationIdentity(
                    workspace.appendingPathComponent(name)
                )
            )
        }

        // Record the intended transaction before publishing
        // any item. Retain this information for recovery.
        let journalURL = workspace.appendingPathComponent(
            ".MacBox-Publication.json"
        )

        let retirement = RetirementRecord(
            source: plan.source.path,
            configIdentity: try publicationIdentity(originalConfig),
            configDigest: sha256(originalData),
            directories: try plan.items.map { item in
                PublicationEntry(
                    name: item.source.lastPathComponent,
                    identity: try publicationIdentity(item.source)
                )
            }
        )

        let journal = PublicationJournal(
            source: plan.source.path,
            destination: plan.destination.path,
            entries: entries,
            retirement: retirement
        )

        try encoder.encode(journal).write(
            to: journalURL,
            options: .withoutOverwriting
        )

        var published: [PublicationEntry] = []

        do {

            for (index, entry) in entries.enumerated() {

                try beforeMove?(index)

                let staged = workspace.appendingPathComponent(
                    entry.name
                )

                let final = plan.destination
                    .appendingPathComponent(entry.name)

                guard try publicationIdentity(staged) ==
                            entry.identity else {

                    throw publicationFailure(
                        "Prepared relocation item has changed."
                    )
                }

                try exclusiveRename(
                    from: staged,
                    to: final
                )

                published.append(entry)
            }

        } catch {

            let publicationError = error

            // Reverse only moves performed by this
            // transaction. Never delete destination data.
            do {

                for entry in published.reversed() {

                    let final = plan.destination
                        .appendingPathComponent(entry.name)

                    let staged = workspace
                        .appendingPathComponent(entry.name)

                    guard try publicationIdentity(final) ==
                                entry.identity else {

                        throw publicationFailure(
                            "Published item changed during rollback."
                        )
                    }

                    try exclusiveRename(
                        from: final,
                        to: staged
                    )
                }

            } catch {

                throw publicationFailure(
                    "Relocation publication and rollback failed. " +
                    "The original library has been retained. " +
                    "Recovery workspace: \(workspace.path). " +
                    error.localizedDescription
                )
            }

            throw publicationError
        }
    }
}

extension VMStorageRelocationPlan {

    private struct PendingActivation: Codable {
        let source: String
        let destination: String
        let workspace: String
    }

    // Unlike fileExists(), this also detects dangling
    // symbolic links and propagates unexpected errors.
    private static func identityIfPresent(
        _ url: URL
    ) throws -> PublicationIdentity? {

        var information = stat()

        let result = url.path.withCString {
            Darwin.lstat($0, &information)
        }

        if result != 0 {

            if errno == ENOENT {
                return nil
            }

            throw publicationFailure(
                "Cannot inspect relocation path: \(url.path)"
            )
        }

        return PublicationIdentity(
            device: Int64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    // Record a pending storage change before publishing
    // any destination files.
    static func beginActivation(
        _ prepared: PreparedRelocation,
        recordURL: URL
    ) throws {

        let fm = FileManager.default
        let plan = prepared.plan
        let workspace = prepared.workspace

        try requireDirectory(plan.source)
        try requireDirectory(plan.destination)
        try requireDirectory(workspace)
        try requireDirectory(
            recordURL.deletingLastPathComponent()
        )

        guard workspace.deletingLastPathComponent().path ==
                plan.destination.path,
              workspace.lastPathComponent.hasPrefix(
                ".MacBox-Relocation-"
              ),
              try identityIfPresent(recordURL) == nil,
              try identityIfPresent(
                workspace.appendingPathComponent(
                    ".MacBox-Publication.json"
                )
              ) == nil else {

            throw publicationFailure(
                "An existing relocation requires recovery."
            )
        }

        let pending = PendingActivation(
            source: plan.source.path,
            destination: plan.destination.path,
            workspace: workspace.path
        )

        let temporary = recordURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".MacBox-Pending-\(UUID().uuidString)"
            )

        defer {
            try? fm.removeItem(at: temporary)
        }

        try JSONEncoder().encode(pending).write(
            to: temporary,
            options: .withoutOverwriting
        )

        try fm.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )

        try exclusiveRename(
            from: temporary,
            to: recordURL
        )
    }

    // Recover according to the currently selected
    // storage location.
    //
    // Returns true if a pending activation was handled.
    @discardableResult
    static func recoverPendingActivation(
        recordURL: URL,
        activeStorage: URL
    ) throws -> Bool {

        let fm = FileManager.default

        guard try identityIfPresent(recordURL) != nil else {
            return false
        }

        guard recordURL.path ==
                recordURL.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: recordURL.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular else {

            throw publicationFailure(
                "Unsafe pending relocation record."
            )
        }

        let pending = try JSONDecoder().decode(
            PendingActivation.self,
            from: Data(contentsOf: recordURL)
        )

        let source = URL(
            fileURLWithPath: pending.source,
            isDirectory: true
        ).standardizedFileURL

        let destination = URL(
            fileURLWithPath: pending.destination,
            isDirectory: true
        ).standardizedFileURL

        let workspace = URL(
            fileURLWithPath: pending.workspace,
            isDirectory: true
        ).standardizedFileURL

        let active = activeStorage.standardizedFileURL

        try requireDirectory(source)
        try requireDirectory(destination)
        try requireDirectory(workspace)

        guard !contains(source, destination),
              !contains(destination, source),
              workspace.deletingLastPathComponent().path ==
                destination.path,
              workspace.lastPathComponent.hasPrefix(
                ".MacBox-Relocation-"
              ),
              active.path == source.path ||
                active.path == destination.path else {

            throw publicationFailure(
                "The pending relocation paths are inconsistent."
            )
        }

        let journalURL = workspace.appendingPathComponent(
            ".MacBox-Publication.json"
        )

        // If publication never began, nothing was moved.
        if try identityIfPresent(journalURL) == nil {

            guard active.path == source.path else {
                throw publicationFailure(
                    "Active relocation has no publication journal."
                )
            }

            try fm.removeItem(at: recordURL)

            return true
        }

        guard journalURL.path ==
                journalURL.resolvingSymlinksInPath().path,
              let journalAttributes = try? fm.attributesOfItem(
                atPath: journalURL.path
              ),
              journalAttributes[.type] as? FileAttributeType ==
                .typeRegular else {

            throw publicationFailure(
                "Unsafe relocation journal."
            )
        }

        let journal = try JSONDecoder().decode(
            PublicationJournal.self,
            from: Data(contentsOf: journalURL)
        )

        let names = journal.entries.map { $0.name }

        guard journal.source == source.path,
              journal.destination == destination.path,
              names.last == "Config",
              Set(names.map { $0.lowercased() }).count ==
                names.count,
              names.allSatisfy({
                !$0.isEmpty &&
                $0 != "." &&
                $0 != ".." &&
                !$0.contains("/") &&
                !$0.contains("\0")
              }) else {

            throw publicationFailure(
                "Invalid relocation publication journal."
            )
        }

        // If the destination is already active, the
        // storage switch must not be reversed.
        if active.path == destination.path {

            for entry in journal.entries {

                let final = destination
                    .appendingPathComponent(entry.name)

                let staged = workspace
                    .appendingPathComponent(entry.name)

                guard try identityIfPresent(final) ==
                            entry.identity,
                      try identityIfPresent(staged) == nil else {

                    throw publicationFailure(
                        "Activated relocation is incomplete: " +
                        entry.name
                    )
                }
            }

            try retireOriginalLibrary(
                journal.retirement,
                workspace: workspace,
                source: source
            )

            try fm.removeItem(at: recordURL)

            return true
        }

        // The original library is still active.
        // Identify exactly which publication moves
        // require reversal before changing anything.
        var restore: [PublicationEntry] = []

        for entry in journal.entries.reversed() {

            let final = destination
                .appendingPathComponent(entry.name)

            let staged = workspace
                .appendingPathComponent(entry.name)

            let stagedIdentity =
                try identityIfPresent(staged)

            let finalIdentity =
                try identityIfPresent(final)

            if stagedIdentity == entry.identity {

                // This item was never published or has
                // already been rolled back.
                guard finalIdentity != entry.identity else {

                    throw publicationFailure(
                        "Ambiguous recovery item: " +
                        entry.name
                    )
                }

                continue
            }

            guard stagedIdentity == nil,
                  finalIdentity == entry.identity else {

                throw publicationFailure(
                    "Cannot safely recover: " +
                    entry.name
                )
            }

            restore.append(entry)
        }

        // Reverse only this transaction's own moves.
        for entry in restore {

            let final = destination
                .appendingPathComponent(entry.name)

            let staged = workspace
                .appendingPathComponent(entry.name)

            guard try identityIfPresent(final) ==
                        entry.identity else {

                throw publicationFailure(
                    "Recovery item changed: " +
                    entry.name
                )
            }

            try exclusiveRename(
                from: final,
                to: staged
            )
        }

        try fm.removeItem(at: recordURL)

        return true
    }
}


extension VMStorageRelocationPlan {

    private static func sha256(_ data: Data) -> String {

        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func retireOriginalLibrary(
        _ retirement: RetirementRecord,
        workspace: URL,
        source: URL
    ) throws {

        let fm = FileManager.default

        guard retirement.source == source.path else {
            throw publicationFailure(
                "Invalid retirement source."
            )
        }

        let identifier = String(
            workspace.lastPathComponent.dropFirst(
                ".MacBox-Relocation-".count
            )
        )

        guard UUID(uuidString: identifier) != nil else {
            throw publicationFailure(
                "Invalid relocation transaction identifier."
            )
        }

        let archive = source.appendingPathComponent(
            ".MacBox-Retired-\(identifier)",
            isDirectory: true
        )

        let metadata = archive.appendingPathComponent(
            "Retirement.json"
        )

        let original = source.appendingPathComponent(
            "Config"
        )

        let archived = archive.appendingPathComponent(
            "Config"
        )

        // This directory contains recovery metadata and
        // the previous Config, never the original VM disks.
        if try identityIfPresent(archive) == nil {

            try fm.createDirectory(
                at: archive,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }

        try requireDirectory(archive)

        if try identityIfPresent(metadata) == nil {

            try JSONEncoder().encode(retirement).write(
                to: metadata,
                options: .atomic
            )

        } else {

            guard metadata.path ==
                    metadata.resolvingSymlinksInPath().path,
                  let attributes = try? fm.attributesOfItem(
                    atPath: metadata.path
                  ),
                  attributes[.type] as? FileAttributeType ==
                    .typeRegular,
                  try JSONDecoder().decode(
                    RetirementRecord.self,
                    from: Data(contentsOf: metadata)
                  ) == retirement else {

                throw publicationFailure(
                    "Retirement metadata conflict."
                )
            }
        }

        // Recovery is idempotent if the application
        // stopped after archiving the original Config.
        if try identityIfPresent(archived) != nil {

            guard try identityIfPresent(archived) ==
                        retirement.configIdentity,
                  try identityIfPresent(original) == nil,
                  archived.path ==
                    archived.resolvingSymlinksInPath().path,
                  sha256(try Data(contentsOf: archived)) ==
                    retirement.configDigest else {

                throw publicationFailure(
                    "Archived configuration is inconsistent."
                )
            }

            return
        }

        guard try identityIfPresent(original) ==
                    retirement.configIdentity,
              original.path ==
                original.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: original.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeRegular,
              sha256(try Data(contentsOf: original)) ==
                retirement.configDigest else {

            throw publicationFailure(
                "Original configuration changed before retirement."
            )
        }

        try exclusiveRename(
            from: original,
            to: archived
        )
    }

    // A directory is recognised as a retained VM copy
    // only when its retirement record and identity match.
    private static func retainedDirectoryNames(
        in directory: URL
    ) throws -> Set<String> {

        let fm = FileManager.default

        try requireDirectory(directory)

        // Enumerate names rather than URLs to preserve
        // the validated parent directory's path representation.
        let children = try fm.contentsOfDirectory(
            atPath: directory.path
        )

        var result = Set<String>()

        for name in children {

            let archive = directory.appendingPathComponent(
                name,
                isDirectory: true
            )

            let prefix = ".MacBox-Retired-"

            guard archive.lastPathComponent.hasPrefix(prefix),
                  UUID(
                    uuidString: String(
                        archive.lastPathComponent.dropFirst(
                            prefix.count
                        )
                    )
                  ) != nil,
                  (try? requireDirectory(archive)) != nil else {

                continue
            }

            let metadata = archive
                .appendingPathComponent("Retirement.json")

            let config = archive
                .appendingPathComponent("Config")

            guard metadata.path ==
                    metadata.resolvingSymlinksInPath().path,
                  config.path ==
                    config.resolvingSymlinksInPath().path,
                  let metadataAttributes =
                    try? fm.attributesOfItem(
                        atPath: metadata.path
                    ),
                  metadataAttributes[.type]
                    as? FileAttributeType == .typeRegular,
                  let configAttributes =
                    try? fm.attributesOfItem(
                        atPath: config.path
                    ),
                  configAttributes[.type]
                    as? FileAttributeType == .typeRegular,
                  let data = try? Data(contentsOf: metadata),
                  let retirement = try? JSONDecoder().decode(
                    RetirementRecord.self,
                    from: data
                  ),
                  retirement.source == directory.path,
                  let archivedData = try? Data(contentsOf: config),
                  sha256(archivedData) ==
                    retirement.configDigest,
                  (try? identityIfPresent(config)) ==
                    retirement.configIdentity else {

                continue
            }

            for entry in retirement.directories {

                guard !entry.name.isEmpty,
                      entry.name != ".",
                      entry.name != "..",
                      !entry.name.contains("/"),
                      !entry.name.contains("\0") else {

                    continue
                }

                let candidate = directory
                    .appendingPathComponent(entry.name)

                guard (try? requireDirectory(candidate)) != nil,
                      (try? identityIfPresent(candidate)) ==
                        entry.identity else {

                    continue
                }

                result.insert(entry.name)
            }
        }

        return result
    }
}
