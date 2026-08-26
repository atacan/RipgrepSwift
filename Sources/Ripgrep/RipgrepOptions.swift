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

    public init(
        includeHidden: Bool = false,
        followSymbolicLinks: Bool = false,
        respectGitIgnore: Bool = true,
        caseInsensitive: Bool = false
    ) {
        self.includeHidden = includeHidden
        self.followSymbolicLinks = followSymbolicLinks
        self.respectGitIgnore = respectGitIgnore
        self.caseInsensitive = caseInsensitive
    }
}
