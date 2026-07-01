# codex-repo-structure — area → crate map

Maps the `openai/codex` issue **area labels** (from the corpus) to the code that
owns them, so `codex-saga/implement` can route a fix to the right crate
(`repo_map.lua`). Derived READ-ONLY from the repo layout at
`codex-fork/` + the area labels in `data/corpus_selection.jsonl`; tier/fix-rate
columns come from `data/area_rubric.json` (see `docs/METHODOLOGY.md` §3/§5).

_As of 2026-06-30. Tiers: A_target ▸ B_good ▸ C_only_if_strong_evidence ▸ D_avoid._

## Repo shape

The target repo has three code surfaces:

- **`codex-rs/`** — the Rust workspace (~98 crates); the substance of almost every
  fix. Workspace manifest: `codex-rs/Cargo.toml`. Standards: `AGENTS.md` (root),
  `codex-rs/justfile` (`just fmt` / `just fix` / `just test`).
- **`codex-cli/`** — thin Node/TS launcher (`codex-cli/src`, `package.json`); legacy
  TS agent code (`codex-cli/src/utils/agent/…`) still closes some older issues.
- **`docs/`** + **`codex-rs/docs/`** + **`sdk/`** — documentation & SDK surface.
- _(out of repo)_ **Codex Desktop / Chrome plugin** — the bundled app; `app`,
  `browser`, `extension`, `codex-web` issues often live in that external app, which
  is **not** in this repo (a frequent reason those areas are Tier-D / unfixable here).

## Area → crate(s)

| Area label | Tier | fix-rate | Primary crate(s) / path | Notes |
|---|---|---|---|---|
| `exec` | A | 0.20 | `codex-rs/exec`, `exec-server`, `exec-server-protocol`, `execpolicy` | command execution + policy |
| `regression` | A | 0.20 | _(cross-cutting)_ | bisect to the offending PR; fix lands in the owning crate |
| `documentation` | A | 0.18 | `docs/`, `codex-rs/docs/`, `AGENTS.md` | doc-only PRs; trust-ladder entry point |
| `hooks` | A | 0.15 | `codex-rs/hooks` | lifecycle hooks |
| `TUI` | A | 0.15 | `codex-rs/tui` | terminal UI (largest target by volume) |
| `mcp` | A | 0.15 | `codex-rs/codex-mcp`, `mcp-server`, `rmcp-client` | MCP client/server |
| `custom-model` | A | 0.12 | `codex-rs/model-provider-info`, `model-provider`, `models-manager` | provider config / model selection |
| `config` | B | 0.10 | `codex-rs/config`, `cloud-config` | config parsing / TOML |
| `sandbox` | B | 0.08 | `codex-rs/sandboxing`, `linux-sandbox`, `windows-sandbox-rs`, `bwrap`, `process-hardening` | platform sandboxes |
| `code-review` | B | 0.07 | `codex-rs/core` (+ `tui`/`cli` review surface) | no dedicated crate |
| `subagent` | B | 0.07 | `codex-rs/agent-graph-store`, `agent-identity`, `external-agent-sessions` | sub-agent orchestration |
| `tool-calls` | C | 0.07 | `codex-rs/tools` | tool-call plumbing |
| `skills` | C | 0.07 | `codex-rs/skills`, `core-skills` | skills runtime |
| `azure` | C | 0.06 | `codex-rs/model-provider-info` | Azure provider config |
| `CLI` | C | 0.06 | `codex-rs/cli`, `codex-cli/src` | arg parsing / launcher (Rust + Node) |
| `app-server` | C | 0.06 | `codex-rs/app-server*` (`-client`/`-daemon`/`-protocol`/`-transport`) | app-server protocol |
| `performance` | C | 0.05 | _(cross-cutting)_ | profile the owning crate |
| `session` | C | 0.05 | `codex-rs/thread-store`, `rollout`, `state`, `external-agent-sessions` | session/thread persistence |
| `windows-os` | C | 0.05 | `codex-rs/windows-sandbox-rs`, `terminal-detection`, `process-hardening` | Windows-specific (cross-cutting) |
| `agent` | C | 0.05 | `codex-rs/agent-graph-store`, `agent-identity`, `external-agent-migration` | agent core |
| `remote` | C | 0.03 | `codex-rs/cloud-tasks`, `cloud-tasks-client`, `backend-client` | remote/cloud tasks |
| `context` | D | 0.03 | `codex-rs/context-fragments`, `install-context`, `response-debug-context` | context window mgmt |
| `auth` | D | 0.03 | `codex-rs/login`, `aws-auth`, `keyring-store`, `chatgpt` | auth/login |
| `extension` | D | 0.02 | `codex-cli/`, `sdk/` (+ external Desktop app) | mostly outside this repo |
| `connectivity` | D | 0.02 | `codex-rs/network-proxy`, `backend-client`, `responses-api-proxy` | network/proxy |
| `browser` | D | 0.01 | _(external Codex Desktop / Chrome plugin)_ | not in this repo |
| `codex-web` | D | 0.01 | _(external web app)_ | not in this repo |
| `app` | D | 0.01 | `codex-rs/app-server*` (+ external Desktop app) | most are the external app |
| `rate-limits` | D | 0.005 | `codex-rs/backend-client`, `responses-api-proxy` | upstream/server-side |
| `model-behavior` | D | 0.005 | _(model-side, not code)_ | prompt/model behavior; rarely code-fixable |
| `computer-use` | D | 0.00 | _(external)_ | none fixed |
| `safety-check` | D | 0.00 | — | HARD-DROP (route to security@openai.com) |

## Cross-cutting notes

- `regression` / `performance` / `windows-os` are **not** single crates — they are
  cross-cutting; the fix lands in whichever owning crate the bisect/triage points to.
- Type labels `bug` / `enhancement` carry **no** area routing; they select `type`,
  not a crate (see `corpus_selection.jsonl`).
- Tier-D `app`/`browser`/`extension`/`codex-web`/`computer-use` are dominated by the
  **external Codex Desktop app** (not in `openai/codex`), which is the structural
  reason their in-repo fix-rate is near-zero — avoid unless the issue clearly points
  at an in-repo crate.
- Highest-signal sweet spot for fixes (Tier-A, in-repo, surgical): `exec`, `TUI`,
  `mcp`, `regression`, `hooks`, `config`.
