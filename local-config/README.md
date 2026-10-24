# AsyncSelf local configuration

This folder contains machine-local configuration and runtime data.

- `profiles/*.env.example` are distributable GitLab/GitHub templates.
- Copy `secrets.env.example` to `$HOME/.config/asyncself/secrets.env`; keep the
  real file outside the repository and restrict it to the current user.
- Copy the selected `elixir/WORKFLOW*.md` template to
  `$HOME/.config/asyncself/workflows/<profile>.md`, replace all example project
  values, and point the copied profile at that external workflow.
- `profiles/*.env`, `active-profile`, `runtime/`, locks, queues, and all
  secrets stay local and are ignored by Git.
- `DUAL_PLATFORM.md` is the setup, selection, component, merge, and rollback
  guide.

Run `../start_asyncself.sh --profile <gitlab|github> --check` before starting.
Do not source a workflow manually; the launcher applies profile validation and
isolates auxiliary state.

The profile and workflow are both required. Their Linear project, required
label, provider repository, and target branch must describe the same boundary.
Keep machine-specific workflows outside the Git checkout instead of editing the
committed templates in place.

New profiles use `ASYNCSELF_*`. The launcher maps legacy `SYMPHONY_*` names for
existing installations and rejects conflicting values.
