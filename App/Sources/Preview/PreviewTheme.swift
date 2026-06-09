import Foundation

/// User-selectable preview theme (issue #19). Each value maps to a CSS
/// overlay file in `Resources/preview/themes/`. The `.custom` case is
/// the bridge to issue #6 (custom CSS) — `.github` is the default look,
/// the other three are curated alternates.
///
/// The Swift name is the lowercase identifier; the JS bridge accepts
/// the same string in `window.Writ.setTheme(name)`.
enum PreviewTheme: String, CaseIterable, Sendable {
    case github
    case serif
    case mono
    case sans

    var displayName: String {
        switch self {
        case .github: return "GitHub (default)"
        case .serif:  return "Serif (academic)"
        case .mono:   return "Mono (typewriter)"
        case .sans:   return "Sans Modern"
        }
    }
}

/// User preferences governing the preview's appearance. Persisted in
/// UserDefaults and broadcast via a notification so live preview panes
/// re-apply on change.
@MainActor
enum PreviewAppearance {
    // MARK: Theme

    static let themeDefaultsKey = "WritPreviewTheme"

    static var theme: PreviewTheme {
        get {
            let raw = UserDefaults.standard.string(forKey: themeDefaultsKey) ?? PreviewTheme.github.rawValue
            return PreviewTheme(rawValue: raw) ?? .github
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: themeDefaultsKey)
            NotificationCenter.default.post(name: PreviewAppearance.didChange, object: nil)
        }
    }

    // MARK: Custom CSS (issue #6)

    /// Bookmark for the user's custom CSS file (so it survives sandbox
    /// restarts). When set, the preview loads this file as an additional
    /// overlay on top of the active theme. Empty string == disabled.
    static let customCSSBookmarkDefaultsKey = "WritPreviewCustomCSSBookmark"

    static var customCSSURL: URL? {
        get {
            guard let data = UserDefaults.standard.data(forKey: customCSSBookmarkDefaultsKey) else { return nil }
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                return url
            } catch {
                return nil
            }
        }
    }

    /// Store (or clear) the custom CSS URL. Pass `nil` to disable.
    /// Persists as a security-scoped bookmark so we can read the file
    /// across launches inside the app sandbox.
    static func setCustomCSSURL(_ url: URL?) {
        if let url {
            do {
                let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: customCSSBookmarkDefaultsKey)
            } catch {
                UserDefaults.standard.removeObject(forKey: customCSSBookmarkDefaultsKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: customCSSBookmarkDefaultsKey)
        }
        NotificationCenter.default.post(name: PreviewAppearance.didChange, object: nil)
    }

    /// Posted whenever the theme or custom-CSS preference changes.
    /// `PreviewViewController` observes this and re-applies via the
    /// JS bridge so the open preview pane reflects the new look
    /// without requiring a document reload.
    static let didChange = Notification.Name("org.ceesaxp.Writ.PreviewAppearance.didChange")
}
