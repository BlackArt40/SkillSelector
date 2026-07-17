# Use directory-scoped permissions

Status: Superseded by ADR 0005.

SkillSelector requests access to specific global Agent directories and user-added project folders instead of requesting broad disk access. This keeps the app lightweight and easier to trust while still allowing it to read and manage local Skill files; destructive or structural write operations remain separately confirmed by the user.
