/// Configuration for a ripgrep-style search.
///
/// Defaults mirror the `rg` command line: hidden files are skipped,
/// symbolic links are not followed, and ignore files (`.gitignore`,
/// `.ignore`, global and `.git/info/exclude`) are respected.
public struct RipgrepOptions: Sendable {
    /// Include hidden files and directories (dotfiles).
    public var includeHidden: Bool

    /// Traverse into directories reached through symbolic links.
    public var followSymbolicLinks: Bool

    /// Respect `.gitignore`, `.ignore`, global, and exclude files.
    public var respectGitIgnore: Bool

    /// Match the pattern case-insensitively.
    public var caseInsensitive: Bool

    /// Case-sensitive gitignore-style globs selecting eligible files (ORed).
    /// Empty means all files. Relative to the root, or its parent for a file
    /// root. Does not override ignore files or hidden-file handling.
    public var includeGlobs: [String]

    /// Case-sensitive globs excluding files/directories (ORed). Excludes win
    /// over includes; matching directories are pruned before descent. Use a
    /// trailing `/` to match directories only. Negation/comments/blank globs
    /// are invalid; syntax errors throw `RipgrepError.invalidGlob` on iteration.
    public var excludeGlobs: [String]

    public init(
        includeHidden: Bool = false,
        followSymbolicLinks: Bool = false,
        respectGitIgnore: Bool = true,
        caseInsensitive: Bool = false,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.includeHidden = includeHidden
        self.followSymbolicLinks = followSymbolicLinks
        self.respectGitIgnore = respectGitIgnore
        self.caseInsensitive = caseInsensitive
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }
}
