---
name: crowfield-development
description: Develop Crowfield on the Linux host, build and verify standalone exports, and manage Crowfield issues and pull requests. Use for implementation, branch integration, release packaging, and GitHub triage.
---

Use `ssh butvinm-work` and the checkout at `/home/butvinm/Dev/crowfield`. Keep builds and imports on Linux. Deliver a standalone app to the user's Mac. Use [runtime commands](references/runtime.md) for imports, tests, exports, and multiplayer.

## Project board

Use the [Crowfield GitHub Project](https://github.com/users/butvinm/projects/11). Keep one issue per independently verifiable outcome. Give each issue a short outcome and brief acceptance criteria. Link dependency issues and implementation PRs. One PR can deliver several issues.

- **Ideas** holds proposals that need agreement.
- **Todo** holds agreed work that is waiting to start.
- **In Progress** holds work a named subagent is actively carrying through delivery. Record one owner on the issue when work starts. Use the subagent's name in the project Owner field or the issue body if it has no GitHub account.
- **Done** means the outcome was verified and delivered. Record the evidence and close the issue when it has been fulfilled.

Flag blockers on the issue and state what will unblock them. Keep board status and ownership current as work starts, pauses, resumes, or finishes.

## Team lead

The lead communicates with the user, coordinates agents, and manages GitHub. Give each task one owner and let the owner implement and verify it through delivery. Run independent tasks in parallel with separate worktrees. Follow each issue through verification and delivery. Interrupt an owner for a concrete blocker or conflicting decision. Task owners make the code changes.

## GitHub

- Fetch `origin/main` before branching or integrating. Start from current main in a separate issue worktree. If work depends on a draft, link that dependency and verify the combined change against current main before review.
- Search open issues and PRs first. Reuse the issue that owns the outcome. Agree which PR will carry the work before opening additional drafts.
- Push the issue branch and link each issue advanced by the PR. Keep one reviewable PR per integration and close superseded drafts with a link to the verified replacement. Preserve their branches.
- Record the exact build, test result, outstanding checks, and next action on the issue or linked PR. Keep a draft while a required check is pending. Use closing keywords for each issue fully addressed by the eventual merge. Close completed experiments with their findings.
- Land changes through a PR. At delivery, verify the issue and PR states, update the board, and preserve existing edits in local checkouts when updating main.

Follow the sourced-art rule in [AGENTS.md](../../../AGENTS.md). Adapt assets through rigging, retargeting, material edits, faction colors, and optimization. Keep the creator, source URL, license, and changes with the asset and include required credits in the export.
