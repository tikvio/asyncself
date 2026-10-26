# Dual CLI deployment compatibility

The implementation has completed A0-A4 local validation and awaits the separately authorized A5 real delivery loop. The exact installed `dsh` version in this environment is
`0.2.1-rc.2`. Its account module writes model-discovery diagnostics through `console.info`, while
ACP writes JSON-RPC directly to `process.stdout`. The repository therefore supplies an ACP-only
Node preload (`priv/acp/console_to_stderr.cjs`) which is passed with `node --require` solely to the
dsh ACP launcher process. It never sets `NODE_OPTIONS`, does not alter JSON-RPC output, and does
not hide any other malformed stdout frame: the decoder still fails closed.

Evidence, reproduction commands, and the A0-A6 acceptance matrix are maintained in the external
implementation plan at `asyncself改造计划/01-双CLI部署级兼容/05-问题记录.md` and `03-验收标准.md`.
Do not enable `agent.backend: deepseek` for production dispatch until the exact version, wrapper,
session lifecycle, restricted Linear MCP, full quality gates, and a real Linear/SCM delivery loop have passed. The authorized ACP
profile file was backed up before validation and its SHA-256 remained unchanged. `--check` performs
configuration/version/ACP startup validation without a model prompt; `--check-live` explicitly sends
one minimal model prompt in a temporary workspace and cleans it afterward. The issue-bound MCP
Escript starts only its HTTP client dependency and has a real read-only Linear proof; neither it
nor either preflight command proves a Linear or SCM delivery loop.
