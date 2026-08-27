import Foundation

/// Scans authorized roots for MCP config files and parses their server
/// declarations. Read-only, mirrors `SkillScanner`'s philosophy: only paths
/// inside already-authorized roots are touched, config files are small and
/// read whole, and no probing happens here.
public struct McpScanner: Sendable {
    public init() {}

    /// Upper bound for a single MCP config file read. Mirrors the entry-file
    /// cap the Skill scanner applies (`SkillDocumentReader.maximumRenderBytes`,
    /// audit R3/F-01): a multi-GB `.mcp.json`/`config.toml` inside an
    /// authorized root must not be slurped into memory during a scan (local
    /// DoS). Files over the limit are skipped, exactly like parse failures.
    public static let maximumConfigFileBytes = 1_048_576

    /// Scans the given authorized roots.
    ///
    /// - Parameter homeRoot: the authorized `.home` root (or a system root
    ///   holding user-level configs). Global config paths resolve against it.
    /// - Parameter projectRoots: authorized `.project` roots. Project config
    ///   files (`.mcp.json` etc.) resolve inside each.
    public func scan(
        homeRoot: AuthorizedRootSnapshot?,
        projectRoots: [AuthorizedRootSnapshot]
    ) -> [McpServerDescriptor] {
        var servers: [McpServerDescriptor] = []

        for declaration in McpRegistry.globalDeclarations {
            guard let homeRoot,
                  let url = Self.resolve(globalPath: declaration.globalPath, relativeTo: homeRoot.url) else {
                continue
            }
            servers.append(contentsOf: parse(
                fileURL: url,
                format: declaration.format,
                agentID: declaration.agentID,
                projectRootID: nil
            ))
        }

        for root in projectRoots {
            for declaration in McpRegistry.projectDeclarations {
                guard let projectPath = declaration.projectPath else { continue }
                let url = root.url.appendingPathComponent(projectPath).standardizedFileURL
                servers.append(contentsOf: parse(
                    fileURL: url,
                    format: declaration.format,
                    agentID: declaration.agentID,
                    projectRootID: root.id
                ))
            }
        }

        return servers.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.configFile < rhs.configFile : lhs.name < rhs.name
        }
    }

    private func parse(
        fileURL: URL,
        format: String,
        agentID: String,
        projectRootID: String?
    ) -> [McpServerDescriptor] {
        // Size-check first so an oversized config is rejected before any
        // read (audit R3/F-01 parity): the stat and the read are two steps,
        // but a config that grows in between is bounded by the post-read
        // guard below — either way a huge file never reaches the parser.
        let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let fileSize, fileSize <= Self.maximumConfigFileBytes,
              let data = try? Data(contentsOf: fileURL),
              data.count <= Self.maximumConfigFileBytes else {
            return []
        }
        let parsed: [ParsedMcpServer]
        do {
            parsed = try McpConfigParser.parse(data, format: format)
        } catch {
            return []
        }
        return parsed.filter { $0.command != nil || $0.url != nil }
            .map { server in
                McpServerDescriptor(
                    name: server.name,
                    agentID: agentID,
                    transport: server.transport,
                    command: server.command,
                    arguments: server.arguments,
                    url: server.url,
                    configFile: fileURL.path,
                    projectRootID: projectRootID
                )
            }
    }

    /// Resolves a `~/...` global path against the home root, guarding
    /// against escaping it (e.g. "~/.config/../../etc" style input).
    static func resolve(globalPath: String, relativeTo home: URL) -> URL? {
        let home = home.standardizedFileURL
        guard globalPath.hasPrefix("~/") else { return nil }
        let components = globalPath.dropFirst(2).split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let url = components.reduce(home) { $0.appendingPathComponent($1) }
            .standardizedFileURL
        guard url.isContained(in: home) else { return nil }
        return url
    }
}