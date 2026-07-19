# ~~Use local tools for trusted metadata enrichment~~

> **Superseded.** This ADR is no longer applicable. The entire enrichment feature (gh, npm, MCP metadata providers) was removed from SkillSelector on 2026-07-19.

~~Status: Accepted.~~

~~SkillSelector does not configure or call an AI model. It extracts original metadata for existing local Skills through the user's installed `gh` CLI, npm Registry read-only commands, and explicitly enabled read-only MCP tools. Search results are candidates only and require user confirmation before they become an update source.~~

~~The app never installs external tools, runs npm package scripts, provides a Skill marketplace, or generates a description. GitHub authentication remains owned by `gh`; MCP commands that use package runners require an additional exact-command confirmation.~~

~~This replaces the OpenAI-compatible enrichment service in ADR 0004.~~
