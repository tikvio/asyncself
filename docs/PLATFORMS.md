# Platform notes

## WSL2 on Windows

WSL2 is the recommended Windows setup. It provides the Unix process model and tools expected by the
launcher while preserving access to Windows applications.

Keep the AsyncSelf checkout, target source clone, and worker workspaces in the WSL Linux filesystem,
for example `/home/you/code`. Active concurrent work under `/mnt/c` is slower and can produce less
predictable permissions, file watching, executable bits, symlinks, and lock behavior.

Run Bash, Git, Codex, Python, mise, Elixir, `gh`, and AsyncSelf inside the same WSL distribution.
Open `http://localhost:4000` from Windows when the dashboard is running.

## Linux

Linux is the primary runtime target. Ensure `flock` is installed and the service user owns the
source/workspace/runtime paths. Long-running use is best placed under a user-level supervisor after
the foreground command has been validated.

## macOS

The GitLab profile has been run on macOS. Install GNU-compatible dependencies where needed and keep
all active paths on the local filesystem. The published first snapshot does not claim a clean-machine
macOS GitHub-profile validation.

## Native Windows

Native Windows is not a supported launcher target. WSL2 avoids rewriting Bash supervision, file
locking, permissions, and workspace hooks into a second platform-specific implementation.
