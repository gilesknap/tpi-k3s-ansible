# PR Squash

Create a clean PR by grouping the current branch's commits into logical squashed
commits on a new branch, then opening a pull request.

## Instructions

1. **Determine the base branch.** Use `$ARGUMENTS` if provided, otherwise detect
   the repo's default branch (`main` or `master`) via `gh repo view --json
   defaultBranchRef -q .defaultBranchRef.name`.

2. **Collect the commit history.** Run:
   ```
   git log --oneline --reverse <base>..<current-branch>
   ```
   These are the commits to be grouped.

3. **Analyse and group the commits.** Read the diffs for each commit
   (`git show --stat <sha>` and `git show <sha>` for ambiguous cases).
   Group commits into logical units:
   - Each group should represent one cohesive change (a feature, a fix, a
     refactor, a config change, etc.).
   - Iterative fix-up commits ("fix typo", "try again", "wip") belong with the
     feature they relate to.
   - Keep genuinely independent changes in separate groups.
   - Preserve chronological order between groups where possible.

4. **Decide: one PR or multiple PRs.** If the groups fall into distinct,
   unrelated topics (e.g. "developer tooling" vs "production feature"), plan
   to create **separate PRs** — one per topic. Each PR gets its own squash
   branch (`<current-branch>-squash-1`, `-squash-2`, etc.) and contains only
   the groups for that topic. Groups that are closely related (e.g. a feature
   and its config) stay in the same PR as separate squashed commits.

   Rule of thumb: if a reviewer would reasonably want to merge one topic
   without the other, they belong in separate PRs.

5. **Present the grouping plan.** Show the user a numbered list like:
   ```
   PR 1: "Devcontainer hardening and tooling"
     Group 1: "harden devcontainer and add Just task runner"
       - abc1234 add security settings
       - def5678 replace tox with just

   PR 2: "Add Dex OIDC authentication"
     Group 2: "configure Dex and argocd-monitor"
       - jkl3456 add Dex config
       - mno7890 fix client secret
       - pqr1234 fix audience mismatch
   ```
   If all groups are closely related, show a single PR with multiple groups.
   Ask the user to confirm or adjust before proceeding.

6. **Create squash branch(es).** Once approved, for each PR:
   ```
   git checkout -b <branch-name> <base>
   ```
   Use `<current-branch>-squash` for a single PR, or
   `<current-branch>-squash-<N>` (or a short descriptive suffix) for multiple.

7. **Cherry-pick and squash each group.** For each group in the PR:
   ```
   git cherry-pick --no-commit <sha1> <sha2> ...
   git commit -m "<group message>"
   ```
   Use a well-written conventional commit message for each group. Include a
   short body if the group contains non-obvious changes. Preserve any
   `Co-Authored-By` trailers from the original commits.

8. **Push and create the PR(s).**
   ```
   git push -u origin <branch-name>
   ```
   Create each PR with `gh pr create` targeting the base branch. The PR body
   should summarise its squashed commit group(s).

9. **Switch back** to the original branch so the user's working state is
   unchanged.

## Edge cases
- If there are fewer than 3 commits, suggest the user just squash-merge
  directly instead — but proceed if they insist.
- If cherry-pick conflicts arise, stop and inform the user rather than
  auto-resolving.
- Never force-push or modify the original branch.
- If a `-squash` branch already exists, ask the user before overwriting.
