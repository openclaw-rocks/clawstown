# CLAUDE.md

## Project Identity

Clawstown is a Kubernetes-native agent swarm orchestrator built on OpenClaw and the OpenClaw k8s-operator. It coordinates multiple AI agent instances through GitHub (issues, PRs, comments) to work on a codebase collaboratively. Think "Gastown rebuilt on real infrastructure."

This project is maintained by the same team that maintains the [OpenClaw k8s-operator](https://github.com/openclaw-rocks/k8s-operator).

## Repository Structure

```
clawstown/
  clawstown.sh              # Main entry point — deploys a swarm
  manifests/
    mayor.yaml              # OpenClawInstance manifest for the Mayor
    worker.yaml             # OpenClawInstance template for workers
    namespace.yaml          # Namespace + base resources
    secrets.yaml.tpl        # Secret template (never committed with values)
  prompts/
    mayor.md                # Mayor system prompt (coordinator, reviewer)
    worker.md               # Base worker system prompt (developer)
    roles/                  # Optional role-specific prompt additions
      backend.md
      frontend.md
      testing.md
  kind/
    cluster.yaml            # Kind cluster configuration
  scripts/
    deploy-operator.sh      # Helm install of the OpenClaw operator
    create-instances.sh     # Generates and applies instance manifests
    teardown.sh             # Clean shutdown of the swarm
  docs/
    architecture.md         # Detailed architecture documentation
    gastown-comparison.md   # Deep-dive comparison with Gastown
```

## Architecture Decisions

### GitHub as Coordination Layer

We use GitHub Issues and PRs as the coordination backbone. No Beads, no Dolt, no custom databases. Rationale:

- GitHub is the single source of truth for code — making it the source of truth for coordination eliminates state synchronization problems
- Every agent interaction (task creation, assignment, code review, merge) produces a GitHub artifact that humans can inspect
- GitHub's API is stable, well-documented, and universally available
- When agents crash and restart, they recover state by reading GitHub issues — not by querying a local database that may also have crashed
- The failure mode is "GitHub is down" which means you have bigger problems anyway

### OpenClaw + k8s-operator as Runtime

Each agent is an `OpenClawInstance` custom resource managed by the OpenClaw Kubernetes Operator. This gives us:

- Declarative lifecycle management (create/update/delete via kubectl)
- Pod security contexts (non-root, read-only rootfs, dropped capabilities)
- NetworkPolicy isolation between agents
- Resource limits (CPU/memory per agent)
- Health probes and automatic restart
- Persistent storage for agent workspaces
- Observability (Prometheus metrics, ServiceMonitor, Grafana dashboards)
- Self-configuration (agents can install skills via OpenClawSelfConfig)

### Roles: Mayor + Workers

The swarm has two structural roles:

**Mayor**: Coordinator and final reviewer. Never writes production code. Responsibilities:
- Read the project description
- Analyze the target repository
- Decompose work into GitHub issues with clear acceptance criteria
- Assign issues to workers
- Review PRs against issue requirements
- Request changes or approve and merge
- Track overall progress

**Worker**: Developer. Responsibilities:
- Poll for assigned GitHub issues
- Create feature branches
- Implement changes according to issue requirements
- Write tests
- Open PRs with clear descriptions linking back to the issue
- Respond to review comments from the Mayor

Workers can optionally have role hints (backend, frontend, testing) that add domain-specific instructions to their base prompt, but they are structurally identical OpenClaw instances.

### Small Swarm by Default

Default configuration is 1 Mayor + 2 Workers = 3 agents. This is enough to demonstrate coordination while keeping costs manageable. Scale up by increasing `--workers`.

## Development Guidelines

### Shell Scripts

- `clawstown.sh` must be POSIX-compatible where possible, bash where necessary
- All scripts must be idempotent — running twice should not break state
- Use `set -euo pipefail` in all scripts
- Provide clear error messages when prerequisites are missing
- Never hardcode API keys or tokens — always read from flags, env vars, or secrets

### Kubernetes Manifests

- All manifests target the `openclaw.rocks/v1alpha1` API version
- Use the latest conventions from the [k8s-operator README](https://github.com/openclaw-rocks/k8s-operator)
- Secrets are always created from templates — never commit actual values
- Use `envFrom` with `secretRef` for API keys, never inline `env` values
- Default resource requests: 500m CPU, 1Gi memory per agent
- Default resource limits: 2000m CPU, 4Gi memory per agent
- Always enable `storage.persistence` for agent workspaces
- Always enable `security.networkPolicy`

### Prompts

- Prompts live in `prompts/` as Markdown files
- The Mayor prompt must explicitly forbid writing production code
- The Worker prompt must require linking PRs to issues
- All prompts must instruct agents to communicate through GitHub (issues, PR comments)
- Prompts should be model-agnostic where possible (don't rely on Claude-specific features)
- Keep prompts focused — the agent's power comes from OpenClaw's capabilities, not from prompt length

### Coordination Protocol

Agents coordinate through GitHub using these conventions:

**Issue Labels:**
- `clawstown:task` — A work item created by the Mayor
- `clawstown:in-progress` — A worker has started on this issue
- `clawstown:review` — A PR is open and awaiting Mayor review
- `clawstown:blocked` — Work is blocked (comment explains why)
- `clawstown:done` — Issue is complete and PR is merged
- `role:backend`, `role:frontend`, `role:testing` — Role hints for assignment

**Branch Naming:**
- `clawstown/<issue-number>-<short-description>` (e.g., `clawstown/42-add-jwt-auth`)

**PR Convention:**
- Title: Clear, imperative description of the change
- Body: Must reference the issue (`Closes #42`)
- Must include a test plan
- Must not include unrelated changes

**Issue Convention:**
- Title: Clear, actionable description
- Body: Acceptance criteria as a checklist
- Labels: At minimum `clawstown:task`
- Assignee: The worker responsible (or unassigned for any worker to pick up)

### Testing

- `clawstown.sh` should have a `--dry-run` mode that generates manifests without applying them
- Integration tests run against a Kind cluster
- Test the full flow: deploy → Mayor creates issues → Worker opens PR → Mayor reviews
- Mock GitHub API for unit tests of coordination logic

## Key Dependencies

| Dependency | Version | Purpose |
|---|---|---|
| [OpenClaw](https://github.com/openclaw/openclaw) | latest | AI agent runtime |
| [OpenClaw k8s-operator](https://github.com/openclaw-rocks/k8s-operator) | >= v0.10.0 | Kubernetes lifecycle management |
| [kind](https://kind.sigs.k8s.io/) | >= 0.20.0 | Local Kubernetes clusters (optional) |
| [Helm](https://helm.sh/) | >= 3.0.0 | Operator installation |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | >= 1.28.0 | Cluster interaction |

## What This Project is NOT

- **Not a fork of Gastown.** Clawstown is an independent project inspired by Gastown's vision.
- **Not a general-purpose agent framework.** This is specifically about coordinating OpenClaw instances on Kubernetes for collaborative software development.
- **Not a managed service.** This is a tool you run on your own infrastructure (or a Kind cluster on your laptop).
- **Not production-ready yet.** We're building in the open. Early adopters welcome, but expect rough edges.

## Conventions

- Write clear commit messages that explain why, not what
- Keep the README honest — document what exists, not what we wish existed
- Prefer simplicity over cleverness in scripts and manifests
- When in doubt, look at how the [k8s-operator](https://github.com/openclaw-rocks/k8s-operator) does it
