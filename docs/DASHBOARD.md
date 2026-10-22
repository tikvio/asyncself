# Dashboard and merge controls

The dashboard is an operational view of the selected Linear project and active workers. It shows
project issues, agent status, workspace information, and provider data available to the profile.

The GitHub profile can associate pull requests with Linear issues and display PR state, checks, and
changed files. Its `In Review -> Merging` action records a human decision; Gatekeeper performs the
actual validation and merge outside the web request.

Status wording is intentionally conservative:

- `Waiting Gatekeeper` means a merge request is queued or being evaluated.
- `PR merged` means GitHub has confirmed the PR's merged state.
- passing checks or a mergeable PR never move `In Review` to `Merging` by themselves.

The GitLab profile has reduced MR presentation and control compared with GitHub. Use GitLab itself
for the complete review view, while the watcher reconciles MR and Linear state.

The dashboard is designed for a trusted local environment. Do not expose port 4000 directly to the
public internet. Put authentication and a secure reverse proxy in front of it if remote access is
ever required.
