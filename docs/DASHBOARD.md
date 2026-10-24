# Dashboard and merge controls

The dashboard is an operational view of the selected Linear project and active workers. It shows
project issues, agent status, workspace information, and provider data available to the profile.

The GitHub profile can associate pull requests with Linear issues and display PR state, checks, and
changed files. Its `In Review -> Merging` action records a human decision; Gatekeeper performs the
actual validation and merge outside the web request.

## Enable the intended Dashboard features

The web page, project-wide reads, and Linear writes have separate switches. A practical GitHub
workflow starts with:

```yaml
dashboard:
  # Change to true only after the profile and workflow pass `--check`.
  linear_actions_enabled: false
observability:
  dashboard_enabled: true
  refresh_ms: 1000
  dashboard_aggregation_enabled: true
  dashboard_aggregation_refresh_ms: 60000
```

`dashboard_enabled` serves the UI and active-worker data. `dashboard_aggregation_enabled` is also
required for the Project Issues list, Linear project reads, and provider details. If aggregation is
false, **Refresh project data** remains disabled by policy; clicking it cannot enable the feature.

For a GitHub profile, set `linear_actions_enabled: true` only when the Dashboard should be allowed
to move an issue from `In Review` to `Merging`. That write changes Linear first. Gatekeeper then
revalidates and performs the GitHub squash merge asynchronously; the web request itself never
claims that the PR merged.

Status wording is intentionally conservative:

- `Waiting Gatekeeper` means a merge request is queued or being evaluated.
- `PR merged` means GitHub has confirmed the PR's merged state.
- passing checks or a mergeable PR never move `In Review` to `Merging` by themselves.

The GitLab profile has reduced MR presentation and control compared with GitHub. Use GitLab itself
for the complete review view, while the watcher reconciles MR and Linear state.

The dashboard is designed for a trusted local environment. Do not expose port 4000 directly to the
public internet. Put authentication and a secure reverse proxy in front of it if remote access is
ever required.
