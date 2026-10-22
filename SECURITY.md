# Security policy

AsyncSelf launches coding agents, writes to Linear, pushes branches, and can merge after an explicit
human state transition. Run it only with repositories, workspaces, prompts, and credentials you
trust.

## Safe deployment baseline

- keep tokens outside the checkout in `$HOME/.config/asyncself/secrets.env` with mode `600`;
- use separate, least-privilege, revocable tokens for Linear and the selected code host;
- restrict the active label and Linear project to intended tasks;
- require a dedicated non-`main` target branch and repository branch protection;
- keep source clones, generated workspaces, and runtime paths separate;
- review workflow hooks and repository-local Codex skills before running them;
- keep the dashboard bound to a trusted local network and do not expose it unauthenticated;
- inspect generated specs so issue text never carries credentials or private runtime data.

The launcher detects several project-boundary and configuration mistakes, but it is not a security
sandbox around untrusted repository code. Package scripts, tests, workflow hooks, and coding agents
can execute code within the permissions granted to the worker process.

## Reporting a vulnerability

Do not include tokens, private repository content, Linear issue data, or exploit details in a public
issue. Contact the repository owner through the private contact method listed on the GitHub profile
until a dedicated security address is published.
