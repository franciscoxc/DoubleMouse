import AppKit

/// Asks GitHub for the latest release and installs it. It is the video compressor's updater, which
/// is Cardinal's in Swift, pointed at GitHub as Cardinal's is: the disk image lives only in GitHub
/// Releases. It runs only when asked from the menu, because the app makes no network requests on
/// its own, and that has to stay true.
enum Updater {
    struct Release: Equatable {
        let version: String
        let notes: String
        let diskImage: URL?
        let size: Int64?
    }

    // Ephemeral: the shared session kept every answer, and a second copy of the disk image, in a
    // cache of its own under Library/Caches.
    private static let session = URLSession(configuration: .ephemeral)

    static let latestRelease = URL(string: "https://api.github.com/repos/franciscoxc/DoubleMouse/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/franciscoxc/DoubleMouse/releases/latest")!
    /// How much of the release notes fits in the dialog before it points at the page.
    static let notesBudget = 1200

    /// The team that signs every release: the installer demands this signature, not just any.
    // ponytail-keep: codesign --verify alone only says the bundle arrived whole, which anyone's
    // ad-hoc signature also passes, and what URLSession downloads carries no quarantine, so
    // Gatekeeper never looks at it either. The selftest compares it with the app's own signature
    // so the two cannot drift apart.
    static let team = "993439K8XB"

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // ponytail-keep: one run at a time. Between accepting the download and the next dialog
    // nothing is on screen and the menu is still there: in Cardinal a second run downloaded the
    // same image over the one the first was still writing, then mounted whatever was left.
    @MainActor private static var busy = false

    /// From the menu: always says how it went.
    @MainActor
    static func check() async {
        guard !busy else {
            return
        }
        busy = true
        defer { busy = false }
        NSApp.activate(ignoringOtherApps: true)

        let release: Release?
        do {
            release = try await latest()
        } catch {
            // Offline, or GitHub down or rate limited: say so and offer the page.
            if ask("Couldn't Check for Updates", "DoubleMouse couldn't reach GitHub. Check your connection, or open the releases page in your browser.",
                   yes: "Open Releases Page", no: "Not Now") {
                NSWorkspace.shared.open(releasesPage)
            }
            return
        }
        guard let release else {
            return tell("You're Up to Date", "DoubleMouse \(current) is the latest version.")
        }
        await offer(release)
    }

    /// The latest release, if it is newer than this one; nil if this is the latest.
    static func latest() async throws -> Release? {
        var request = URLRequest(url: latestRelease, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = release["tag_name"] as? String, !tag.isEmpty else {
            throw UpdateError("GitHub did not give the latest version")
        }
        // Without the leading v, or the button would say "Update to v1.3.0".
        let version = tag.replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
        guard compareVersions(version, current) > 0 else {
            return nil
        }
        let assets = release["assets"] as? [[String: Any]] ?? []
        let image = assets.first { ($0["browser_download_url"] as? String)?.hasSuffix(".dmg") == true }
        // A link from anywhere else is treated as no link: the releases page is what always works.
        let url = (image?["browser_download_url"] as? String).flatMap(URL.init(string:)).flatMap { isFromThisRepo($0) ? $0 : nil }
        let size = (image?["size"] as? NSNumber)?.int64Value
        return Release(version: version, notes: plainNotes(release["body"] as? String ?? ""), diskImage: url, size: size.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Shows the notes of the new version and, if accepted, downloads and installs it.
    @MainActor
    private static func offer(_ release: Release) async {
        let headline = "DoubleMouse \(release.version) is out. You have \(current)."
        // Nothing appears between the click and the end of the download, so the button says how
        // much it is about to fetch. A dialog cannot show progress; this at least sets the wait.
        var download = "Download"
        if let size = release.size {
            download = "Download (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
        }
        guard ask("A New Version Is Available", release.notes.isEmpty ? headline : "\(headline)\n\n\(release.notes)",
                  yes: release.diskImage == nil ? "Open Releases Page" : download, no: "Not Now") else {
            return
        }
        guard let image = release.diskImage else {
            NSWorkspace.shared.open(releasesPage)
            return
        }

        let volume: String
        do {
            volume = try await downloadAndMount(image)
        } catch {
            // Downloading it here is a convenience; the browser is what always works.
            if ask("Couldn't Download the Update", "DoubleMouse couldn't download the update. You can download it with your browser and drag it to Applications.",
                   yes: "Download with Browser", no: "Not Now") {
                NSWorkspace.shared.open(image)
            }
            return
        }

        // ponytail-keep: quitting is part of installing, not a courtesy. macOS does not let the
        // new app replace the one that is running, so the installer runs once this one is gone,
        // and the button says what it does instead of "OK".
        if ask("DoubleMouse \(release.version) Is Ready", "Install it now and DoubleMouse relaunches, or quit and drag it to Applications yourself.",
               yes: "Install and Relaunch", no: "Quit and Do It Myself") {
            do {
                try install(from: volume)
            } catch {
                // ponytail-keep: a dialog of its own, with the way out that does work. In
                // Cardinal, a folder the app could not write to (Applications, on an account that
                // is not an administrator) fell into the failed-download dialog and sent people to
                // the page. The download is fine: mounted and open in Finder, which can ask for
                // the password.
                guard ask("Couldn't Install the Update", "DoubleMouse can't replace itself in the folder it is in. The new version is open in Finder: quit DoubleMouse and drag it to Applications.",
                          yes: "Quit and Do It Myself", no: "Not Now") else {
                    return
                }
            }
        }
        NSApp.terminate(nil)
    }

    /// Negative when a is older, positive when newer, zero when it is the same version.
    // No pre-release suffixes (0.3.0-beta.1): they would need rules of their own, and DoubleMouse
    // does not publish them.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ version: String) -> [Int] {
            version.replacingOccurrences(of: #"^[vV]"#, with: "", options: .regularExpression)
                .split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let (left, right) = (parts(a), parts(b))
        for index in 0..<max(left.count, right.count) {
            let difference = (index < left.count ? left[index] : 0) - (index < right.count ? right[index] : 0)
            if difference != 0 {
                return difference
            }
        }
        return 0
    }

    /// Release notes as a dialog can show them: it takes text, not Markdown.
    static func plainNotes(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r", with: "")
        for (pattern, replacement) in [(#"(?m)^#{1,6}\s+"#, ""), (#"!\[[^\]]*\]\([^)]*\)"#, ""), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
                                       (#"\*\*([^*]+)\*\*"#, "$1"), (#"`([^`]+)`"#, "$1"),
                                       // Spaces and tabs, not \s: \s includes the newline, and a
                                       // bullet after a blank line swallowed the blank line.
                                       (#"(?m)^[ \t]*[-*][ \t]+"#, "• "), (#"\n{3,}"#, "\n\n")] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > notesBudget else {
            return text
        }
        // Cut at a line break rather than mid-sentence, so it does not read like a bug.
        let limit = text.index(text.startIndex, offsetBy: notesBudget)
        let cut = text[..<limit].lastIndex(of: "\n") ?? limit
        return text[..<cut].trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
    }

    // ponytail-keep: only this repository's release downloads. The link arrives in GitHub's
    // answer, and an answer that was tampered with must not be able to send the download, or the
    // browser, anywhere else.
    static func isFromThisRepo(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host?.lowercased() == "github.com", url.user == nil, url.port == nil else {
            return false
        }
        let parts = url.pathComponents
        return parts.count == 7 && Array(parts[1...4]) == ["franciscoxc", "DoubleMouse", "releases", "download"]
            && parts.allSatisfy { $0 != ".." && $0 != "." }
    }

    /// Downloads the disk image and mounts it. Returns where it was mounted.
    @MainActor
    private static func downloadAndMount(_ url: URL) async throws -> String {
        guard isFromThisRepo(url), url.lastPathComponent.hasSuffix(".dmg") else {
            throw UpdateError("unexpected download location")
        }
        // In Caches and not Downloads, so no folder permission is needed. It stays there until the
        // next update, in case the new version goes wrong and has to be installed again.
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "DoubleMouse")
            .appendingPathComponent("update")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        let (downloaded, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("the download failed")
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)

        // Without -nobrowse: the volume has to show, because the fallback is dragging the app from it.
        let output = try await Task.detached { try run(["/usr/bin/hdiutil", "attach", destination.path]) }.value
        // hdiutil prints tab-separated columns, and the mount point is the last one, on the line
        // that was actually mounted: the lines before it are the partitions, which have none.
        guard let volume = output.split(separator: "\n")
            .compactMap({ $0.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("/Volumes/") }) else {
            throw UpdateError("hdiutil did not say where it mounted the image")
        }
        // ponytail-keep: mounting is not showing. hdiutil attach makes the volume available but
        // opens nothing, and the window to drag the app from never appeared; opening it does that.
        NSWorkspace.shared.open(URL(fileURLWithPath: volume))
        return volume
    }

    /// Leaves a script running that replaces this app with the one on the volume and opens it.
    // The script does the copying because macOS does not let an open app replace itself: the
    // process has to be gone, and by then nobody is left to copy. So it is written, started on its
    // own, and the app quits; the script waits for it to go.
    private static func install(from volume: String) throws {
        guard volume.hasPrefix("/Volumes/") else {
            throw UpdateError("unexpected volume")
        }
        // The running app, not a fixed path: replacing the wrong copy would be worse than not updating.
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else {
            throw UpdateError("not running from an app bundle")
        }
        // By bundle identifier and not by name, so a renamed app is still found.
        let contents = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: volume), includingPropertiesForKeys: nil)) ?? []
        guard let source = contents.first(where: { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier }) else {
            throw UpdateError("the disk image does not contain DoubleMouse")
        }
        // ponytail-keep: tested here, before quitting, because afterwards nobody is left to say it
        // failed. In a folder that cannot be written to (Applications on an account that is not
        // an administrator, or the app opened straight from the disk image), Cardinal's script died
        // at its first step and the app never came back. Asked by doing it: permissions alone do
        // not see ACLs or read-only volumes.
        let probe = installed.deletingLastPathComponent().appendingPathComponent(".update-\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        } catch {
            throw UpdateError("cannot write next to the app")
        }
        try? FileManager.default.removeItem(at: probe)

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("doublemouse-install.sh")
        try installer(source: source.path, destination: installed.path, volume: volume, pid: ProcessInfo.processInfo.processIdentifier)
            .write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        try process.run()
    }

    /// The installer script: copies the app from the volume next to the installed one, checks it,
    /// and swaps them.
    // ponytail-keep: ditto to a separate copy and two renames; neither cp over the old app nor
    // rm -rf of it first. Copying over leaves files the new version no longer has, mixing two
    // versions; deleting the old one before the new one is in place is worse, because an rm -rf
    // that fails halfway leaves no app at all. A rename does not depend on the contents, does not
    // stop halfway and can be undone, so at every step there is a whole app where it gets opened.
    // It is Cardinal's installer.
    static func installer(source: String, destination: String, volume: String, pid: Int32) -> String {
        // Single quotes, with any quote inside doubled up: the paths come from disk and can hold anything.
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        // Apple's root and a certificate of this team: someone else's signature, or an ad-hoc one,
        // does not meet it. The leading = tells codesign this is the requirement text, not a file.
        let signedByUs = quote("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        return """
            #!/bin/sh
            # Waits for DoubleMouse to quit. If it somehow does not, gives up rather than replace an open app.
            for _ in $(seq 1 100); do
              kill -0 \(pid) 2>/dev/null || break
              sleep 0.2
            done
            if kill -0 \(pid) 2>/dev/null; then exit 1; fi

            NEW=\(quote(destination + ".new"))
            # The process number keeps the name free: a leftover from an earlier run that could not be
            # deleted cannot turn the mv below into a move into a folder.
            OLD=\(quote(destination + ".old")).$$

            # Every failing step ends here, with the previous app in its place: the update is
            # abandoned and the app comes back. The disk image stays mounted, to do it by hand.
            give_up() {
              rm -rf "$NEW"
              open \(quote(destination))
              rm -f "$0"
              exit 1
            }

            rm -rf "$NEW" || give_up
            ditto \(quote(source)) "$NEW" || give_up
            # Checked before anything moves: a copy that arrived damaged, or that someone else
            # signed, does not replace one that works.
            codesign --verify --deep --strict -R=\(signedByUs) "$NEW" || give_up

            # The swap, by renames: the old app steps aside whole and is deleted only once the new
            # one is in place; if the second rename fails, the first is undone.
            mv \(quote(destination)) "$OLD" || give_up
            if ! mv "$NEW" \(quote(destination)); then
              mv "$OLD" \(quote(destination))
              give_up
            fi
            rm -rf "$OLD" || true

            hdiutil detach \(quote(volume)) -quiet || true
            open \(quote(destination))
            rm -f "$0"
            """
    }

    /// Runs a tool and returns what it printed, standard error included.
    static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(arguments[0]) exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func selfTest() -> [String] {
        var problems: [String] = []
        if !(compareVersions("v1.10.0", "1.9.3") > 0 && compareVersions("1.2", "1.2.0") == 0 && compareVersions("1.0.0-beta.1", "1.0.1") < 0) {
            problems.append("version comparison")
        }
        let notes = plainNotes("## What's new\r\n\r\n- **Faster**\r\n\r\n* See [the page](https://x)")
        if notes != "What's new\n\n• Faster\n\n• See the page" {
            problems.append("release notes: \(notes.debugDescription)")
        }

        // With spaces and a quote in the paths, which real ones can have.
        let script = installer(source: "/Volumes/Double Mouse/DoubleMouse.app", destination: "/Users/x/Fran's Apps/DoubleMouse.app",
                               volume: "/Volumes/Double Mouse", pid: 42)
        if let verify = script.range(of: "codesign --verify"),
           let move = script.range(of: #"mv '/Users/x/Fran'\''s Apps/DoubleMouse.app' "$OLD""#),
           verify.lowerBound < move.lowerBound, script.contains("leaf[subject.OU] = \"\(team)\"") {
        } else {
            problems.append("the installer moves the app before verifying the copy, or does not demand the team's signature")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("doublemouse-selftest-install.sh")
        try? script.write(to: file, atomically: true, encoding: .utf8)
        if (try? run(["/bin/sh", "-n", file.path])) == nil {
            problems.append("the installer is not a valid shell script")
        }
        try? FileManager.default.removeItem(at: file)

        // The constant and the real signature cannot drift apart: with another team no update would
        // ever install. Ad-hoc builds (TeamIdentifier=not set) and swift run have nothing to compare.
        if Bundle.main.bundleURL.pathExtension == "app",
           let signature = try? run(["/usr/bin/codesign", "-dv", Bundle.main.bundlePath]),
           let line = signature.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }),
           line != "TeamIdentifier=not set", line != "TeamIdentifier=\(team)" {
            problems.append("the app is signed with \(line), but the updater demands \(team)")
        }

        let good = ["https://github.com/franciscoxc/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg"]
        let bad = ["http://github.com/franciscoxc/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg",
                   "https://github.com.example.com/franciscoxc/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg",
                   "https://github.com@example.com/franciscoxc/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg",
                   "https://example.com/franciscoxc/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg",
                   "https://github.com/someone/DoubleMouse/releases/download/v1.3.0/DoubleMouse-1.3.0.dmg",
                   "https://github.com/franciscoxc/DoubleMouse/releases/download/../../../someone/x.dmg",
                   "https://github.com/franciscoxc/DoubleMouse/releases/download/%2E%2E/x.dmg"]
        if !good.allSatisfy({ isFromThisRepo(URL(string: $0)!) }) || bad.contains(where: { isFromThisRepo(URL(string: $0)!) }) {
            problems.append("the updater would download from somewhere other than this repository's releases")
        }
        return problems
    }

    @MainActor
    private static func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    @MainActor
    private static func ask(_ title: String, _ text: String, yes: String, no: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
