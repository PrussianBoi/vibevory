import AppKit
import Foundation

/// Artha updates itself from the fork's GitHub releases: every master build of the Mac workflow is
/// published as `build-<n>` with `Artha-mac.zip`, and the app carries its own number as `ArthaBuild`.
/// A newer release is offered in Settings; installing downloads it, swaps the app in place once
/// Artha has quit, and opens the new one.
@MainActor @Observable
final class ArthaUpdater {
    static let shared = ArthaUpdater()

    struct Release: Equatable {
        var build: Int
        var notes: String
        var zip: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case failed(String)
    }

    private(set) var available: Release?
    private(set) var state: State = .idle
    private(set) var lastChecked: Date?

    /// This app's build; 0 for a build CI did not number (a local or screenshot build).
    let currentBuild: Int = (Bundle.main.object(forInfoDictionaryKey: "ArthaBuild") as? Int) ?? 0

    private static let latestURL = URL(string: "https://api.github.com/repos/PrussianBoi/vibevory/releases/latest")!
    private var started = false

    /// At launch, then every six hours while the app runs.
    func start() {
        guard !started else { return }
        started = true
        Task {
            while true {
                await check()
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    func check() async {
        if state == .downloading { return }
        if state == .installing { return }
        state = .checking
        defer { if state == .checking { state = .idle } }
        do {
            var req = URLRequest(url: Self.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 20
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, tag.hasPrefix("build-"),
                  let build = Int(tag.dropFirst("build-".count)),
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String) == "Artha-mac.zip" }),
                  let link = asset["browser_download_url"] as? String, let zip = URL(string: link)
            else { lastChecked = .now; return }
            lastChecked = .now
            let notes = ((json["body"] as? String) ?? "")
                .components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            available = build > currentBuild ? Release(build: build, notes: notes, zip: zip) : nil
        } catch {
            // Offline or rate-limited: try again at the next check, quietly.
            lastChecked = .now
        }
    }

    /// Downloads the release, then quits; a small script swaps the app in and opens it again.
    func install() {
        guard let release = available else { return }
        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard !dest.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed("Move Artha into Applications first, then update.")
            return
        }
        state = .downloading
        Task {
            do {
                let work = FileManager.default.temporaryDirectory.appendingPathComponent("artha-update-\(release.build)", isDirectory: true)
                try? FileManager.default.removeItem(at: work)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("Artha-mac.zip")
                try await download(release.zip, to: zip)
                state = .installing
                try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
                let fresh = work.appendingPathComponent("Artha.app")
                guard FileManager.default.fileExists(atPath: fresh.appendingPathComponent("Contents/MacOS").path) else {
                    throw UpdateError("The download had no Artha.app in it.")
                }
                try swapAndRelaunch(fresh: fresh, dest: dest, work: work)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func download(_ url: URL, to file: URL) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub did not hand over the build.") }
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: tmp, to: file)
    }

    /// Waits for this process to end, moves the new app over the old one, clears quarantine, opens it.
    private func swapAndRelaunch(fresh: URL, dest: URL, work: URL) throws {
        let script = work.appendingPathComponent("swap.sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        let body = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        DEST=\(shellQuote(dest.path))
        NEW=\(shellQuote(fresh.path))
        rm -rf "$DEST.old"
        mv "$DEST" "$DEST.old" && mv "$NEW" "$DEST" && rm -rf "$DEST.old" || { [ -d "$DEST.old" ] && [ ! -d "$DEST" ] && mv "$DEST.old" "$DEST"; }
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Could not unpack the build (\(tool) \(p.terminationStatus)).") }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct UpdateError: LocalizedError {
    var message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
