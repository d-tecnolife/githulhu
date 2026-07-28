# Codex workflow

## Branching

- Never commit or push directly to `main`.
- Treat `main` as the reviewed production branch.
- Start every feature from the latest `main` on a branch named `codex/<short-feature-name>`.
- The `codex` branch is an optional integration/staging branch; do not use it for unrelated concurrent features.
- Push feature branches with `git push -u origin codex/<short-feature-name>`.

## Required delivery sequence

1. Implement only the requested feature and run the relevant checks.
2. Commit the feature with a clear conventional-style message.
3. Push the feature branch; do not merge it into `main`.
4. Use an independent Codex reviewer (one that did not author the implementation) to review the final diff for correctness, security, tests, and UI/accessibility where relevant.
5. Address all actionable review findings, rerun checks, and have the reviewer confirm the final diff.
6. Open or update a pull request targeting `main`. Only merge after that review is complete and required checks pass.

## Agent roles

- Lead: plans, coordinates specialists, and integrates work.
- UI agent: owns visual behavior, responsiveness, and accessibility.
- Backend agent: owns API, data, and domain changes.
- Reviewer: read-only by default; reports findings and must be independent of the author.
- Test agent: validates the final branch and reports failures without changing scope.

When parallelizing, give each implementation agent a separate worktree and a distinct `codex/<feature>` branch. Do not let agents make overlapping edits in one checkout.
