# CLAUDE.md

## Project Identity

Clawstown is a Kubernetes-native agent swarm orchestrator built on OpenClaw and the OpenClaw k8s-operator. It coordinates multiple AI agent instances through GitHub (issues, PRs, comments) to work on a codebase collaboratively. Think "Gastown rebuilt on real infrastructure."

This project is maintained by the same team that maintains the [OpenClaw k8s-operator](https://github.com/openclaw-rocks/k8s-operator).

## Repository Structure

```
clawstown/
  clawstown.sh              # Main entry point — deploys a swarm
  manifests/
    namespace.yaml          # Namespace + base resources
    secrets.yaml.tpl        # Secret template (never committed with values)
  prompts/
    agent.md                # Agent system prompt (self-organizing developer)
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

### SWARM.md as the Spec

The target repository must contain a `SWARM.md` file that describes what the swarm should accomplish. This file is maintained by the human, never modified by agents. The human can update it at any time — agents re-read it from the repo and adjust.

This means:
- `--repo` is the only required argument (besides auth)
- No `--description` flag needed — the spec lives in the repo
- The human can steer the swarm mid-flight by pushing changes to SWARM.md
- The repo's README describes what the project *is*; SWARM.md describes what the swarm should *do*

### Self-Organizing Agents (No Mayor)

All agents are structurally identical. There is no central coordinator. Agents self-organize through GitHub:

- The first agent to start bootstraps by reading SWARM.md and creating issues
- Agents claim issues by self-assigning and adding the `clawstown:in-progress` label
- Agents review each other's PRs (any non-author agent can review)
- A PR needs at least one peer approval before merge
- After merging, agents run the test suite and create issues from any failures
- When no work remains, agents check SWARM.md for unmet goals and create new issues

This eliminates the Mayor as a single point of failure and bottleneck. The tradeoff is that initial work decomposition may be less coordinated, but the continuous feedback loop (test, verify, create issues) compensates.

### Small Swarm by Default

Default configuration is 2 agents. This is enough to demonstrate coordination (one implements, one reviews) while keeping costs manageable. Scale up by increasing `--agents`.

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

- The agent prompt lives in `prompts/agent.md` and is injected as `AGENTS.md` into the workspace (OpenClaw auto-loads this file into the agent's context on startup)
- The prompt must instruct agents to read SWARM.md from the target repo
- The prompt must instruct agents to communicate through GitHub (issues, PR comments)
- The prompt must require peer review before merging PRs
- The prompt must instruct agents to run tests after merging and create issues from failures
- Prompts should be model-agnostic where possible (don't rely on Claude-specific features)
- Keep prompts focused — the agent's power comes from OpenClaw's capabilities, not from prompt length

### Skills

- Agents are deployed with the `gh-issues` skill, which provides GitHub interaction via `curl` + REST API (no `gh` CLI required)
- The `gh-issues` skill uses the `GH_TOKEN` environment variable for authentication (injected via the `clawstown-github` secret)
- Do not depend on `gh` CLI being available — it is not installed in the OpenClaw container images

### Coordination Protocol

Agents coordinate through GitHub using these conventions:

**Issue Labels:**
- `clawstown:task` — A work item
- `clawstown:in-progress` — An agent is working on this issue
- `clawstown:review` — A PR is open and awaiting peer review
- `clawstown:blocked` — Work is blocked (comment explains why)
- `clawstown:done` — Issue is complete and PR is merged
- `clawstown:failing` — Tests are failing after a merge

**Branch Naming:**
- `clawstown/<issue-number>-<short-description>` (e.g., `clawstown/42-add-jwt-auth`)

**PR Convention:**
- Title: Clear, imperative description of the change
- Body: Must reference the issue (`Closes #42`)
- Must include a test plan
- Must not include unrelated changes
- Must have at least one peer approval before merge

**Issue Convention:**
- Title: Clear, actionable description
- Body: Acceptance criteria as a checklist
- Labels: At minimum `clawstown:task`
- Assignee: The agent working on it (or unassigned for any agent to pick up)

### Testing

- `clawstown.sh` should have a `--dry-run` mode that generates manifests without applying them
- Integration tests run against a Kind cluster
- Test the full flow: deploy → agent creates issues → another agent reviews PR
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
