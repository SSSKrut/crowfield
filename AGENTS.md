# Crowfield working agreements

## Game art

- Use existing artist-authored art for player-facing assets. Source models for soldiers, weapons, vehicles, buildings, and vegetation with commercial redistribution rights.
- Do not create replacement art from scratch, generate artwork, or assemble substitute models out of primitives. Adapt the sourced art with rigging, retargeting, material edits, faction colors, or optimization as needed for the game.
- Record the original asset, author, source URL, license, and changes. Include required attribution in distributed builds.

## GitHub workflow

- Fetch the current `origin/main` before starting a branch or updating an integration PR. Work in a separate Linux worktree and land changes through a PR.
- Link each PR to the issue it advances and record what passed and what still needs verification. Use closing keywords when the PR satisfies the linked issue.
- Reconcile issues and PRs when work is integrated or superseded. Close redundant drafts with a link to the replacement. Close completed experiments with their result, even if the experiment stays out of the game. Keep issues open when a fix or its acceptance checks are pending.
