import AppKit
import CryptoKit
import Darwin
import Foundation

struct UpdateInfo {
    let remoteVersion: String
    let isNewer: Bool
    let error: String?
}

private struct NumericVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: NumericVersion, rhs: NumericVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

private enum UpdateError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

private final class OneShotRequest: NSObject, URLSessionDataDelegate {
    private let output: FileHandle?
    private let maximumBytes: Int64
    private var receivedBytes: Int64 = 0
    private var response: HTTPURLResponse?
    private var responseIsRedirect = false
    private var storedError: Error?
    private var continuation: CheckedContinuation<(HTTPURLResponse, Data), Error>?
    private var session: URLSession?
    private var body = Data()

    init(output: FileHandle?, maximumBytes: Int64) {
        self.output = output
        self.maximumBytes = maximumBytes
    }

    func run(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            storedError = UpdateError.message("The update server returned an invalid response.")
            completionHandler(.cancel)
            return
        }

        self.response = httpResponse
        responseIsRedirect = UpdateChecker.isRedirect(httpResponse.statusCode)
        if !responseIsRedirect,
           response.expectedContentLength > maximumBytes {
            storedError = UpdateError.message("The update download was unexpectedly large.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !responseIsRedirect, storedError == nil else { return }
        receivedBytes += Int64(data.count)
        guard receivedBytes <= maximumBytes else {
            storedError = UpdateError.message("The update download was unexpectedly large.")
            dataTask.cancel()
            return
        }

        do {
            if let output {
                try output.write(contentsOf: data)
            } else {
                body.append(data)
            }
        } catch {
            storedError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            continuation = nil
        }

        if let storedError {
            continuation?.resume(throwing: storedError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response {
            continuation?.resume(returning: (response, body))
        } else {
            continuation?.resume(throwing: UpdateError.message("The update server returned no response."))
        }
    }
}

enum UpdateChecker {
    private static let workerVersionURL =
        "https://wipeout-update-pings.andy-s-account-376.workers.dev/version.txt"
    private static let fallbackVersionURL =
        "https://github.com/arostad/Wipeout/releases/download/latest/version.txt"
    private static let zipURL =
        "https://github.com/arostad/Wipeout/releases/download/latest/Wipeout.app.zip"
    private static let checksumURL =
        "https://github.com/arostad/Wipeout/releases/download/latest/Wipeout.app.zip.sha256"
    private static let zipFileName = "Wipeout.app.zip"
    private static let minimumZipBytes: Int64 = 100_000
    private static let maximumZipBytes: Int64 = 500_000_000
    private static let maximumSmallResponseBytes: Int64 = 1_024
    private static let maximumRedirects = 5
    private static let trustedHosts: Set<String> = [
        "wipeout-update-pings.andy-s-account-376.workers.dev",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    static func check() async -> UpdateInfo {
        let current = NumericVersion(BuildInfo.version)
        var lastRemoteText = ""
        var lastError = "Could not read the latest version."

        for url in [workerVersionURL, fallbackVersionURL] {
            do {
                let body = try await getSmall(url)
                guard let text = String(data: body, encoding: .utf8) else {
                    throw UpdateError.message("Latest version string was not readable.")
                }
                let firstLine = text.prefix { !$0.isNewline }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lastRemoteText = firstLine
                guard !firstLine.isEmpty,
                      let remote = NumericVersion(firstLine),
                      let current else {
                    throw UpdateError.message("Latest version string was not readable.")
                }
                return UpdateInfo(
                    remoteVersion: firstLine,
                    isNewer: remote > current,
                    error: nil
                )
            } catch {
                lastError = error.localizedDescription
            }
        }

        return UpdateInfo(remoteVersion: lastRemoteText, isNewer: false, error: lastError)
    }

    static func downloadAndRestart() async throws {
        let target = Bundle.main.bundleURL.standardizedFileURL
        guard target.pathExtension.lowercased() == "app" else {
            throw UpdateError.message("Could not resolve the running app bundle.")
        }

        let parent = target.deletingLastPathComponent()
        let identifier = UUID().uuidString.lowercased()
        let (zip, expectedHash) = try await downloadVerifiedZip(to: parent)
        let pendingRoot = parent.appendingPathComponent(".Wipeout-update-\(identifier).new", isDirectory: true)
        let candidate = pendingRoot.appendingPathComponent("Wipeout.app", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: pendingRoot,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try extract(zip: zip, to: pendingRoot)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw UpdateError.message("The downloaded update did not contain Wipeout.app.")
            }

            try startReplacementHelper(
                zip: zip,
                expectedHash: expectedHash,
                pendingRoot: pendingRoot,
                candidate: candidate,
                target: target,
                identifier: identifier
            )
        } catch {
            try? FileManager.default.removeItem(at: pendingRoot)
            try? FileManager.default.removeItem(at: zip)
            throw error
        }
    }

    fileprivate static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    private static func freshURL(_ value: String) throws -> URL {
        guard var components = URLComponents(string: value) else {
            throw UpdateError.message("The update URL was invalid.")
        }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(
            name: "t",
            value: String(Int64(Date().timeIntervalSince1970 * 1_000))
        ))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw UpdateError.message("The update URL was invalid.")
        }
        return url
    }

    private static func ensureTrusted(_ url: URL) throws {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              trustedHosts.contains(host),
              components?.user == nil,
              components?.password == nil else {
            throw UpdateError.message("The download was redirected to an untrusted location.")
        }
    }

    private static func request(for url: URL) -> URLRequest {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 60
        )
        request.httpShouldHandleCookies = false
        request.setValue("Wipeout", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

    private static func getSmall(_ value: String) async throws -> Data {
        var current = try freshURL(value)
        for redirectCount in 0...maximumRedirects {
            try ensureTrusted(current)
            let oneShot = OneShotRequest(output: nil, maximumBytes: maximumSmallResponseBytes)
            let (response, body) = try await oneShot.run(request(for: current))

            if isRedirect(response.statusCode) {
                guard redirectCount < maximumRedirects else {
                    throw UpdateError.message("The download used too many redirects.")
                }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw UpdateError.message("The download redirect had no destination.")
                }
                try ensureTrusted(next)
                current = next
                continue
            }

            guard (200...299).contains(response.statusCode) else {
                throw UpdateError.message("The update server returned HTTP \(response.statusCode).")
            }
            return body
        }
        throw UpdateError.message("The download used too many redirects.")
    }

    private static func download(
        _ value: String,
        to output: FileHandle
    ) async throws -> Int64 {
        var current = try freshURL(value)
        for redirectCount in 0...maximumRedirects {
            try ensureTrusted(current)
            let startingOffset = try output.offset()
            let oneShot = OneShotRequest(output: output, maximumBytes: maximumZipBytes)
            let (response, _) = try await oneShot.run(request(for: current))

            if isRedirect(response.statusCode) {
                guard redirectCount < maximumRedirects else {
                    throw UpdateError.message("The download used too many redirects.")
                }
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw UpdateError.message("The download redirect had no destination.")
                }
                try ensureTrusted(next)
                current = next
                continue
            }

            guard (200...299).contains(response.statusCode) else {
                throw UpdateError.message("The update server returned HTTP \(response.statusCode).")
            }
            return Int64(try output.offset() - startingOffset)
        }
        throw UpdateError.message("The download used too many redirects.")
    }

    private static func readChecksum() async throws -> String {
        let data = try await getSmall(checksumURL)
        guard let text = String(data: data, encoding: .ascii) else {
            throw UpdateError.message("The update checksum was not readable.")
        }
        let pattern = #"^([0-9a-fA-F]{64})(?:(?:  | \*)Wipeout\.app\.zip)?\s*$"#
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: range),
              match.range == range,
              let hashRange = Range(match.range(at: 1), in: text) else {
            throw UpdateError.message("The update checksum was not readable.")
        }
        return String(text[hashRange]).lowercased()
    }

    private static func createNewFile(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func downloadVerifiedZip(to directory: URL) async throws -> (URL, String) {
        for attempt in 0..<2 {
            let expectedHash = try await readChecksum()
            let pending = directory.appendingPathComponent(
                ".\(zipFileName).\(UUID().uuidString.lowercased()).new"
            )

            do {
                let output = try createNewFile(at: pending)
                let count: Int64
                do {
                    count = try await download(zipURL, to: output)
                    try output.synchronize()
                    try output.close()
                } catch {
                    try? output.close()
                    throw error
                }

                guard count >= minimumZipBytes else {
                    throw UpdateError.message("Download failed.")
                }
                let actualHash = try sha256(of: pending)
                if actualHash.caseInsensitiveCompare(expectedHash) == .orderedSame {
                    return (pending, expectedHash)
                }

                try? FileManager.default.removeItem(at: pending)
                if attempt == 1 {
                    throw UpdateError.message("The downloaded update failed its integrity check.")
                }
            } catch {
                try? FileManager.default.removeItem(at: pending)
                throw error
            }
        }

        throw UpdateError.message("The downloaded update failed its integrity check.")
    }

    private static func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(zip: URL, to directory: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, directory.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.message(
                detail?.isEmpty == false ? detail! : "The downloaded update could not be unpacked."
            )
        }
    }

    private static func startReplacementHelper(
        zip: URL,
        expectedHash: String,
        pendingRoot: URL,
        candidate: URL,
        target: URL,
        identifier: String
    ) throws {
        let parent = target.deletingLastPathComponent()
        let helper = parent.appendingPathComponent(".Wipeout-update-\(identifier).sh")
        let backup = parent.appendingPathComponent(".Wipeout-backup-\(identifier).app")
        let errorFile = parent.appendingPathComponent("Wipeout-update-error.txt")
        let script = """
        #!/bin/sh
        set -u

        fail_update() {
          message="$1"
          printf 'Update failed: %s\\n' "$message" > "$WIPEOUT_ERROR" 2>/dev/null || true
          if [ ! -e "$WIPEOUT_TARGET" ] && [ -e "$WIPEOUT_BACKUP" ]; then
            /bin/mv "$WIPEOUT_BACKUP" "$WIPEOUT_TARGET" 2>/dev/null || true
          fi
          if [ -e "$WIPEOUT_TARGET" ]; then
            /usr/bin/open "$WIPEOUT_TARGET" >/dev/null 2>&1 || true
          fi
          /bin/rm -rf "$WIPEOUT_PENDING_ROOT" 2>/dev/null || true
          /bin/rm -f "$WIPEOUT_ZIP" 2>/dev/null || true
          /bin/rm -f "$0" 2>/dev/null || true
          exit 1
        }

        while /bin/kill -0 "$WIPEOUT_PID" 2>/dev/null; do
          /bin/sleep 1
        done

        actual_hash=$(/usr/bin/shasum -a 256 "$WIPEOUT_ZIP" 2>/dev/null | /usr/bin/awk '{print tolower($1)}')
        [ "$actual_hash" = "$WIPEOUT_SHA256" ] || fail_update "The downloaded update failed its integrity check."
        [ -d "$WIPEOUT_CANDIDATE" ] || fail_update "The unpacked application is missing."
        [ -d "$WIPEOUT_TARGET" ] || fail_update "The installed application is missing."

        /bin/mv "$WIPEOUT_TARGET" "$WIPEOUT_BACKUP" 2>/dev/null ||
          fail_update "The installed application could not be moved."
        if ! /bin/mv "$WIPEOUT_CANDIDATE" "$WIPEOUT_TARGET" 2>/dev/null; then
          /bin/mv "$WIPEOUT_BACKUP" "$WIPEOUT_TARGET" 2>/dev/null || true
          fail_update "The new application could not be installed."
        fi

        if ! /usr/bin/open "$WIPEOUT_TARGET" >/dev/null 2>&1; then
          /bin/rm -rf "$WIPEOUT_TARGET" 2>/dev/null || true
          /bin/mv "$WIPEOUT_BACKUP" "$WIPEOUT_TARGET" 2>/dev/null || true
          fail_update "The updated application could not be opened."
        fi

        /bin/rm -rf "$WIPEOUT_BACKUP" "$WIPEOUT_PENDING_ROOT" 2>/dev/null || true
        /bin/rm -f "$WIPEOUT_ZIP" "$WIPEOUT_ERROR" 2>/dev/null || true
        /bin/rm -f "$0" 2>/dev/null || true
        exit 0
        """

        let output = try createNewFile(at: helper)
        do {
            try output.write(contentsOf: Data(script.utf8))
            try output.synchronize()
            try output.close()
            guard Darwin.chmod(helper.path, mode_t(0o700)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: helper)
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path]
        var environment = ProcessInfo.processInfo.environment
        environment["WIPEOUT_UPDATE_PENDING"] = zip.path
        environment["WIPEOUT_ZIP"] = zip.path
        environment["WIPEOUT_SHA256"] = expectedHash.lowercased()
        environment["WIPEOUT_PENDING_ROOT"] = pendingRoot.path
        environment["WIPEOUT_CANDIDATE"] = candidate.path
        environment["WIPEOUT_TARGET"] = target.path
        environment["WIPEOUT_BACKUP"] = backup.path
        environment["WIPEOUT_ERROR"] = errorFile.path
        environment["WIPEOUT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: helper)
            throw error
        }
    }
}
