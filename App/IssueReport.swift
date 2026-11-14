import AppKit

/// The "Report an Issue…" link: a new GitHub issue with the versions filled in.
///
/// Nothing about the open document goes into it, not even its name. The
/// reader's browser shows the draft before anything is sent.
enum IssueReport {
    static let newIssue = "https://github.com/underveil-stacks/gloss/issues/new"

    static func url(appVersion: String, build: String, system: String) -> URL {
        let body = """
            **What happened**


            **What you expected**


            **Steps to see it**


            ---
            Gloss \(appVersion) (\(build)) · macOS \(system)
            """
        var components = URLComponents(string: newIssue)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url!
    }

    static var url: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return url(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            system: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
        )
    }

    static func open() {
        NSWorkspace.shared.open(url)
    }
}
