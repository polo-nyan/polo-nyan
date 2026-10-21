<!--
  GENERATED FILE — do not edit AI-STATS.md by hand.
  Source: scripts/templates/AI-STATS.template.md, rendered daily by
  scripts/build-ai-stats.sh from ai-stats.json (scripts/collect-ai-stats.mjs).
-->

# AI pair-programming statistics

How much of my code is written together with an AI assistant, and whether that changes how the work flows. Everything on this page is computed from the GitHub API over the last 12 months of my own commits and merged pull requests, public and private; private repositories appear only as one aggregated row.

<!-- GEN:headline -->

## Share of AI-assisted commits over time

<!-- GEN:monthly -->

<!-- GEN:weekly -->

## Per repository

<!-- GEN:repos -->

## Pull requests: with and without AI commits

<!-- GEN:prs -->

## Lines changed

<!-- GEN:lines -->

## How this is measured

- **AI-assisted commit**: a commit authored by me on the default branch whose message carries at least one `Co-authored-by:` trailer naming an AI assistant (Anthropic e-mail domain or a known assistant name). Commits without a trailer count as human-only, even if an assistant was consulted. Bot commits (for example the daily stats update) are not mine and are not counted.
- **Window**: commits with a committed date in the last 365 days, across every repository I own or am a member of in the `smol-kitten` organisation that received a push in that window.
- **Share**: AI-assisted commits divided by all my commits in the same period.
- **Pull requests**: the most recent merged PRs per repository (capped, see the PR section), excluding PRs opened by bots such as Dependabot. A PR is "with AI" if any of its commits is AI-assisted. Merge time is `mergedAt − createdAt`; the median is reported because a few long-lived PRs dominate the mean. CI pass rate uses the status-check rollup of the PR's head commit; PRs without checks are left out of the rate.
- **Lines changed**: additions + deletions as reported by GitHub for each commit; generated files and lockfiles are not excluded, so single large commits can move the per-commit figure.
- **What this cannot tell you**: whether the AI-assisted code is better or worse, how much of a commit the assistant wrote, or anything about work that never became a commit.

Numbers are rebuilt daily by [`update-stats.yml`](.github/workflows/update-stats.yml); the collector is [`scripts/collect-ai-stats.mjs`](scripts/collect-ai-stats.mjs) and the renderer [`scripts/build-ai-stats.sh`](scripts/build-ai-stats.sh). Back to the [profile](README.md).

<!-- GEN:updated -->
