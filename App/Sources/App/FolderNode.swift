import Foundation

/// One row in the folder tree shown by `FolderWindowController`.
///
/// Reference type, not a value type, because `NSOutlineView` keys
/// expansion state and selection by item *identity* — pointer
/// comparison, not equality. If we rebuilt this from a struct on
/// every FSEvents refresh the outline would lose every expanded
/// disclosure. Using a class lets the controller preserve identity
/// across reloads by reusing nodes whose URL matches.
final class FolderNode {
    /// Absolute file URL. Stable across reloads — used as the
    /// identity key when re-matching nodes after a tree rebuild.
    let url: URL
    let isDirectory: Bool
    let name: String
    /// Modification date for the "modified" column. Nil if the
    /// filesystem couldn't supply one.
    let modificationDate: Date?
    /// Populated only for directories. Empty arrays distinguish
    /// "directory we've walked but is empty" from "file" (which
    /// uses `isDirectory == false`).
    var children: [FolderNode]

    init(url: URL, isDirectory: Bool, name: String, modificationDate: Date?, children: [FolderNode] = []) {
        self.url = url
        self.isDirectory = isDirectory
        self.name = name
        self.modificationDate = modificationDate
        self.children = children
    }
}

/// Builds a `FolderNode` tree rooted at `folder`. Filters to
/// markdown / text files; directories are kept only if they
/// transitively contain at least one matching file (no empty
/// branches in the tree).
///
/// Off-main: the enumeration walks the filesystem and may touch
/// many inodes, so callers should run this from a detached task.
enum FolderTreeBuilder {
    /// File extensions we consider editable in Writ.
    static let acceptedExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]

    static func build(at folder: URL) -> FolderNode {
        let attrs = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
        let root = FolderNode(
            url: folder,
            isDirectory: true,
            name: folder.lastPathComponent,
            modificationDate: attrs?.contentModificationDate
        )
        root.children = enumerateChildren(of: folder)
        return root
    }

    private static func enumerateChildren(of dir: URL) -> [FolderNode] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey, .isHiddenKey, .isPackageKey]
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        var out: [FolderNode] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(keys))
            let isDir = values?.isDirectory ?? false
            let isHidden = values?.isHidden ?? false
            let isPackage = values?.isPackage ?? false
            if isHidden || isPackage { continue }
            let modDate = values?.contentModificationDate
            if isDir {
                let nested = enumerateChildren(of: entry)
                // Skip empty branches — directories with no
                // markdown/text descendant don't earn a row.
                if nested.isEmpty { continue }
                out.append(FolderNode(
                    url: entry,
                    isDirectory: true,
                    name: entry.lastPathComponent,
                    modificationDate: modDate,
                    children: nested
                ))
            } else {
                let ext = entry.pathExtension.lowercased()
                guard acceptedExtensions.contains(ext) else { continue }
                out.append(FolderNode(
                    url: entry,
                    isDirectory: false,
                    name: entry.lastPathComponent,
                    modificationDate: modDate
                ))
            }
        }
        // Finder-like sort: directories first, then files; case-
        // insensitive alpha within each group.
        out.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return out
    }

    /// Returns a filtered copy of `tree` containing only nodes
    /// whose name (or any descendant's name) contains `query`.
    /// Directories appear in the result if any descendant matches,
    /// so the user can see the path to every hit. Match is
    /// case-insensitive, substring.
    static func filter(_ tree: FolderNode, query: String) -> FolderNode? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return tree }
        return prune(tree, query: q)
    }

    private static func prune(_ node: FolderNode, query: String) -> FolderNode? {
        if !node.isDirectory {
            return node.name.lowercased().contains(query) ? node : nil
        }
        var keptChildren: [FolderNode] = []
        for child in node.children {
            if let kept = prune(child, query: query) {
                keptChildren.append(kept)
            }
        }
        if keptChildren.isEmpty {
            // Directory might still match by its own name — but we
            // skip "directory itself matches" because there's
            // nothing actionable inside it. Hit on a leaf only.
            return nil
        }
        return FolderNode(
            url: node.url,
            isDirectory: true,
            name: node.name,
            modificationDate: node.modificationDate,
            children: keptChildren
        )
    }
}
