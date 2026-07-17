# Use allowlisted access under a user-authorized home directory

Status: Accepted.

SkillSelector asks the user to authorize their home directory once so it can automatically detect supported Agent directories. The app remains sandboxed and only accesses global Skill paths declared by the bundled Agent type registry; it does not recursively scan unrelated home-directory content. Project folders and system-level Skill directories require separate authorization.

This replaces the per-Agent authorization flow in ADR 0001. The broader OS grant is accepted to make automatic environment detection practical, while the application-level allowlist preserves a narrow behavioral scope.
