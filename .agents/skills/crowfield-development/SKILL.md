---
name: crowfield-development
description: Develop Crowfield on the Linux host, build and verify standalone exports, and manage Crowfield issues and pull requests. Use for implementation, branch integration, release packaging, and GitHub triage.
---

Use `ssh butvinm-work` and the checkout at `/home/butvinm/Dev/crowfield`. Keep builds and imports on Linux. Deliver a standalone app to the user's Mac. Use [runtime commands](references/runtime.md) for imports, tests, exports, and multiplayer.

## GitHub

- Fetch `origin/main` before branching or integrating. Start from the current main revision in a separate issue worktree. If work depends on a draft, record that dependency and verify the combined change against the current main before review.
- Search open issues and PRs before creating either. Reuse the issue that owns the outcome. Use subagents for bounded implementation or independent review. Share the parent issue and agree which PR will carry their work before opening additional drafts.
- Push the issue branch and link the PR to its issue. Keep one reviewable PR for a single integration. Close incorporated or superseded drafts once the replacement is published and verified. Preserve their branches and link the replacement in each closure.
- Put current status and durable test evidence in GitHub. Record the exact build, pass or fail, outstanding checks, and the next action on the issue or linked PR. Keep a draft while a required check is pending. Use closing keywords only for issues fully addressed by the eventual merge. Close a completed experiment with its result, even if the experiment stays out of the game.
- At delivery, check the real open issue and PR states. Land work through a PR. Keep existing edits in local checkouts when updating main.


Follow the sourced-art rule in [AGENTS.md](../../../AGENTS.md). Adapt assets through rigging, retargeting, material edits, faction colors, and optimization. Keep the creator, source URL, license, and changes with the asset and include required credits in the export.
