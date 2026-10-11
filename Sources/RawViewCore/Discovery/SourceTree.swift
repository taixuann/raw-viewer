import Foundation

/// One node in the physical Tree view. Directory ids use the `directory:`
/// prefix and file ids the `source:` prefix, so a directory and a source can
/// never collide even when display names match. `sourceID` is nil exactly for
/// directory (navigation) nodes and carries the project-relative source
/// identity for file nodes; folders are never scientific membership.
public struct SourceTreeNode: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let sourceID: String?
    public let children: [SourceTreeNode]

    public init(id: String, name: String, sourceID: String?, children: [SourceTreeNode]) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.children = children
    }
}

/// A typed partial-inventory failure. `path` is the project-relative path of
/// the affected directory/entry when it can be determined, else the claimed
/// entry name. Enumeration failures keep accessible siblings; metadata
/// failures skip exactly the unreadable entry. Any issue marks the inventory
/// incomplete (CLI completeness fails, the GUI shows partial results).
public enum InventoryIssue: Sendable, Equatable {
    /// The directory's entries could not be enumerated (for example an
    /// unreadable directory); siblings outside it are still inventoried.
    case enumeration(path: String, detail: String)
    /// One entry's metadata could not be read; the entry stays out of the
    /// inventory and its (unclassified) subtree is not descended.
    case metadata(path: String, detail: String)
}

/// Result of one inventory pass: measurement sources, every visited directory
/// (including intermediate and empty ones, as project-relative paths, without
/// the data root itself), and typed issues. Sources and directory paths are
/// sorted for deterministic trees; issues keep encounter order.
public struct SourceInventory: Sendable {
    public let sources: [RawSource]
    public let directoryPaths: [String]
    public let issues: [InventoryIssue]

    /// A complete inventory has no partial I/O issues. Cancellation is not an
    /// issue: it throws instead of returning a partial inventory.
    public var isComplete: Bool { issues.isEmpty }

    public init(sources: [RawSource], directoryPaths: [String], issues: [InventoryIssue]) {
        self.sources = sources
        self.directoryPaths = directoryPaths
        self.issues = issues
    }
}

/// Physical Tree view over one inventory: the configured data root is the
/// root node, directories are navigation nodes and files carry their source
/// identity. Display is relative to the data root; it never redefines identity.
public struct SourceTree: Sendable, Equatable {
    public let root: SourceTreeNode

    public init(inventory: SourceInventory, project: ProjectContext) {
        let configured = project.dataRootRelativePath
        // Parent key for the root's children: "" for a dot root (children are
        // top-level project entries), the configured path otherwise.
        let rootKey = configured == "." ? "" : configured
        let rootName = configured == "."
            ? project.root.lastPathComponent
            : URL(fileURLWithPath: configured).lastPathComponent

        var directoriesByParent: [String: [String]] = [:]
        for path in inventory.directoryPaths {
            directoriesByParent[Self.parent(of: path), default: []].append(path)
        }
        var filesByParent: [String: [RawSource]] = [:]
        for source in inventory.sources {
            filesByParent[Self.parent(of: source.relativePath), default: []].append(source)
        }

        // Siblings share their parent prefix, so a path sort is a name sort.
        // Children whose parent chain does not reach the root (an entry from a
        // partially failed directory, for example) are simply unreachable and
        // never appear; the inventory issues still surface in the UI.
        func makeDirectoryNode(pathKey: String, idPath: String, name: String) -> SourceTreeNode {
            let directories = (directoriesByParent[pathKey] ?? []).sorted()
            let files = (filesByParent[pathKey] ?? []).sorted { $0.relativePath < $1.relativePath }
            let children = directories.map { child -> SourceTreeNode in
                makeDirectoryNode(pathKey: child, idPath: child,
                                  name: URL(fileURLWithPath: child).lastPathComponent)
            } + files.map { source -> SourceTreeNode in
                SourceTreeNode(id: "source:" + source.relativePath, name: source.url.lastPathComponent,
                               sourceID: source.relativePath, children: [])
            }
            return SourceTreeNode(id: "directory:" + idPath, name: name, sourceID: nil, children: children)
        }
        self.root = makeDirectoryNode(pathKey: rootKey, idPath: configured, name: rootName)
    }

    private static func parent(of path: String) -> String {
        guard let cut = path.lastIndex(of: "/") else { return "" }
        return String(path[..<cut])
    }

    /// Filters the tree to retain only sources whose project-relative source
    /// identities are in `sourceIDs`, preserving their directory ancestors
    /// without flattening the hierarchy. If a directory contains no matching
    /// descendants, it is pruned.
    public func filtered(sourceIDs: Set<String>) -> [SourceTreeNode] {
        Self.filterNodes(root.children, sourceIDs: sourceIDs)
    }

    private static func filterNodes(_ nodes: [SourceTreeNode], sourceIDs: Set<String>) -> [SourceTreeNode] {
        var result: [SourceTreeNode] = []
        for node in nodes {
            if let sID = node.sourceID {
                if sourceIDs.contains(sID) {
                    result.append(node)
                }
            } else {
                let matchingChildren = filterNodes(node.children, sourceIDs: sourceIDs)
                if !matchingChildren.isEmpty {
                    result.append(SourceTreeNode(
                        id: node.id,
                        name: node.name,
                        sourceID: nil,
                        children: matchingChildren
                    ))
                }
            }
        }
        return result
    }

    /// Flattens the hierarchical tree into a sequence of top-level items with depth tracking,
    /// traversing only currently expanded directory nodes.
    public func flatten(expandedIDs: Set<String>, activeNodes: [SourceTreeNode]? = nil) -> [FlattenedTreeItem] {
        let nodes = activeNodes ?? root.children
        return Self.flattenNodes(nodes, depth: 0, expandedIDs: expandedIDs)
    }

    public static func flattenNodes(_ nodes: [SourceTreeNode], depth: Int, expandedIDs: Set<String>) -> [FlattenedTreeItem] {
        var result: [FlattenedTreeItem] = []
        for node in nodes {
            result.append(FlattenedTreeItem(id: node.id, node: node, depth: depth))
            if node.sourceID == nil && expandedIDs.contains(node.id) {
                result.append(contentsOf: flattenNodes(node.children, depth: depth + 1, expandedIDs: expandedIDs))
            }
        }
        return result
    }
}

/// An individual item in a flattened tree traversal sequence.
public struct FlattenedTreeItem: Identifiable, Sendable, Equatable {
    public let id: String
    public let node: SourceTreeNode
    public let depth: Int
    public var isDirectory: Bool { node.sourceID == nil }

    public init(id: String, node: SourceTreeNode, depth: Int) {
        self.id = id
        self.node = node
        self.depth = depth
    }
}


/// Pure lifecycle reducer for project/data-root scoped UI state. A data-root
/// change starts a new generation and clears selection and expansion, and
/// `accepts(generation:)` rejects any late async result from the previous
/// root. Native model integration still needs UI verification; this reducer
/// supplies the executable core tests.
public struct ProjectSessionState: Sendable, Equatable {
    public private(set) var generation: Int = 0
    public var selectedSourceIDs: Set<String> = []
    public var expandedDirectoryIDs: Set<String> = []

    public init() {}

    /// Starts a new root generation: every previous discovery/inspection/load
    /// result is superseded, and root-scoped selection and expansion reset.
    /// Returns the new generation token for callers to carry and check.
    public mutating func beginRootChange() -> Int {
        generation += 1
        selectedSourceIDs.removeAll()
        expandedDirectoryIDs.removeAll()
        return generation
    }

    /// Whether `token` is still the current generation; stale tokens are
    /// rejected and their results must not be installed.
    public func accepts(generation token: Int) -> Bool {
        token == generation
    }
}
