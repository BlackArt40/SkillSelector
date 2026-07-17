# Identify Skill installations by path

Status: Accepted.

SkillSelector stores one record per absolute installation path and associates that record with every Agent that discovers it. This prevents shared `.agents/skills` directories from producing duplicate rows while keeping copied directories and symbolic links distinct. A symbolic-link record also stores its resolved target so destructive operations and updates can disclose their actual effect.
