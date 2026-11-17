
import Foundation

enum EmulatorIntegrity {

    struct VerifiedApplication {
        let url: URL
        let version: String
        let build: String
        let bundleVersion: String
    }

    enum VerificationError: LocalizedError {
        case unsafeApplication
        case invalidMetadata
        case invalidExecutable
        case invalidSignature
        case incompatibleArchitecture

        var errorDescription: String? {
            switch self {
            case .unsafeApplication:
                return "The 86Box application path is missing or unsafe."
            case .invalidMetadata:
                return "The 86Box application metadata is invalid."
            case .invalidExecutable:
                return "The 86Box executable is missing or unsafe."
            case .invalidSignature:
                return "The 86Box application failed code-signature verification."
            case .incompatibleArchitecture:
                return "The 86Box executable does not support this Mac's architecture."
            }
        }
    }

    static func verify(_ applicationURL: URL) throws -> VerifiedApplication {
        let fm = FileManager.default
        let app = applicationURL.standardizedFileURL

        guard app.isFileURL,
              app.path == app.resolvingSymlinksInPath().path,
              let attributes = try? fm.attributesOfItem(
                atPath: app.path
              ),
              attributes[.type] as? FileAttributeType ==
                .typeDirectory else {
            throw VerificationError.unsafeApplication
        }

        // Read metadata directly from disk, avoiding Bundle caching.
        let plistURL = app.appendingPathComponent(
            "Contents/Info.plist"
        )

        guard plistURL.path ==
                plistURL.resolvingSymlinksInPath().path,
              let data = try? Data(contentsOf: plistURL),
              let object = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ),
              let plist = object as? [String: Any],
              plist["CFBundleIdentifier"] as? String ==
                "net.86Box.86Box",
              plist["CFBundleExecutable"] as? String == "86Box",
              let version =
                plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty,
              let fullBuild = plist["CFBundleVersion"] as? String,
              let build = fullBuild.split(separator: ".").last,
              !build.isEmpty else {
            throw VerificationError.invalidMetadata
        }

        let executable = app.appendingPathComponent(
            "Contents/MacOS/86Box"
        )

        guard executable.path ==
                executable.resolvingSymlinksInPath().path,
              fm.isExecutableFile(atPath: executable.path) else {
            throw VerificationError.invalidExecutable
        }

        // Verify the complete application bundle.
        guard try run(
            "/usr/bin/codesign",
            arguments: [
                "--verify", "--deep", "--strict", app.path
            ]
        ) else {
            throw VerificationError.invalidSignature
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        throw VerificationError.incompatibleArchitecture
        #endif

        guard try run(
            "/usr/bin/lipo",
            arguments: [
                "-verify_arch", architecture, executable.path
            ]
        ) else {
            throw VerificationError.incompatibleArchitecture
        }

        return VerifiedApplication(
            url: app,
            version: version,
            build: String(build),
            bundleVersion: fullBuild
        )
    }

    private static func run(
        _ executable: String,
        arguments: [String]
    ) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        return process.terminationReason == .exit &&
               process.terminationStatus == 0
    }
}
