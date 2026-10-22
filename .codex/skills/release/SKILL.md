---
name: release
description: Prepare an AsyncSelf source release after checking licensing, validation, versioning, and the manual upstream-core build. Use when asked to release or tag AsyncSelf.
---

# Release

1. Read `LICENSING.md`. Stop unless its release gate is complete and the
   repository has a definitive license boundary, rights holder, and commercial
   contact.
2. Start from fresh `origin/main` in a clean worktree. Never disturb unrelated
   local changes.
3. Pick the requested version. If none is given, use the next patch after the
   latest `vX.Y.Z` tag.
4. Update `elixir/mix.exs` so `version: "X.Y.Z"` matches the intended tag.
   Search the old version and change other files only when they are true
   release-version sources, not examples.
5. Run the Python/Shell workflow and `make -C elixir all`, then commit, push,
   create a PR, and land it.
6. Fetch the merged `main` commit. Verify its `mix.exs` version, then create an
   annotated tag on that exact commit:

   ```sh
   git tag -a vX.Y.Z <merged-commit> -m "AsyncSelf vX.Y.Z"
   git push origin vX.Y.Z
   ```

7. The `upstream-core-build` workflow is manual and produces only the embedded
   Symphony-derived core. Do not present those artifacts as a complete
   AsyncSelf distribution. Create the source release explicitly and describe
   platform/profile limitations in its notes.

Do not tag an uncommitted or unmerged revision. Do not move a published tag
without explicit user approval.
