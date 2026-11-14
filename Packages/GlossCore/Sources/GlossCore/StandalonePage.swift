import Foundation

/// A page that needs nothing but itself: styles inline, no scripts, nothing
/// loaded from anywhere. Used where there is no scheme handler to serve
/// files, such as a Quick Look preview.
public enum StandalonePage {
    /// - Parameters:
    ///   - darkCSS: The theme for the dark appearance.
    ///   - lightCSS: The theme for the light appearance. It is applied when the
    ///     system is in light mode; the page cannot be told its appearance, so
    ///     it follows the system's.
    public static func html(
        for document: RenderedDocument, title: String, baseCSS: String, darkCSS: String, lightCSS: String
    ) -> String {
        // No network, no scripts, no files: only inline styles and inline images.
        let policy = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
        return """
            <!doctype html>
            <html data-appearance="\(marker)" data-theme="standalone">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="\(policy)">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="dark light">
            <title>\(HTMLPage.escape(title))</title>
            <style>
            @media (prefers-color-scheme: dark) {
            \(inline(retarget(baseCSS, from: "dark")))
            \(inline(retarget(darkCSS, from: "dark")))
            }
            @media (prefers-color-scheme: light) {
            \(inline(retarget(baseCSS, from: "light")))
            \(inline(retarget(lightCSS, from: "light")))
            }
            </style>
            </head>
            <body>
            \(HTMLPage.frontMatterHTML(document))
            \(HTMLPage.articleHTML(document))
            </body>
            </html>
            """
    }

    /// The page cannot be told its appearance and cannot change an attribute
    /// without a script, so it carries a fixed marker instead of `light` or
    /// `dark`. Each stylesheet is included once per system appearance, with
    /// the rules written for that appearance pointed at the marker; rules for
    /// the other appearance then match nothing.
    private static let marker = "system"

    private static func retarget(_ css: String, from appearance: String) -> String {
        var result = css
        for quote in ["\"", "'", ""] {
            result = result.replacingOccurrences(
                of: "[data-appearance=\(quote)\(appearance)\(quote)]", with: "[data-appearance=\"\(marker)\"]")
        }
        return result
    }

    /// A stylesheet cannot be allowed to close the `<style>` element it sits in.
    private static func inline(_ css: String) -> String {
        css.replacingOccurrences(of: "</", with: "<\\/")
    }
}
