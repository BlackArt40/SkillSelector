# Update single Skill packages atomically

Status: Accepted.

SkillSelector treats a repository subdirectory containing its own `SKILL.md` as an independently updateable package. It downloads the package to a temporary directory, validates it, compares its contents, and shows the file-level change summary before confirmation. On approval, the old directory moves to Trash and the validated directory replaces it as one operation.

Source binding requires explicit provenance: embedded metadata, a containing Git remote and relative path, a previously recorded source, or user confirmation. Name similarity alone never authorizes an update.
