# Clawstown

**Gastown, rebuilt on OpenClaw. A Kubernetes-native agent swarm.**

Clawstown is an opinionated orchestration layer that turns [OpenClaw](https://github.com/openclaw/openclaw) instances on Kubernetes into a coordinated development swarm. Inspired by Steve Yegge's [Gastown](https://github.com/steveyegge/gastown) — the pioneering multi-agent system that showed the world what 20 coding agents working in parallel looks like — Clawstown asks: what if we built that on infrastructure designed for exactly this problem?

Gastown proved the concept. Clawstown makes it production-grade.

## The Problem Gastown Exposed

Gastown demonstrated something remarkable: a single developer can orchestrate dozens of AI coding agents working on the same codebase simultaneously. But it also revealed the operational reality of running agent swarms:

- **Beads + Dolt dependency**: Coordination relies on [Beads](https://github.com/steveyegge/beads), a custom Git-backed graph tracker, backed by [Dolt](https://github.com/dolthub/dolt), a versioned SQL database. Two bespoke systems that every operator must install, configure, and maintain.
- **Local-only execution**: Agents run as tmux sessions on a single machine. One machine dies, the entire swarm dies.
- **Manual recovery**: When the Refinery crashes or the Deacon goes rogue, you're SSH'ing in and running `git push --force` to recover state.
- **Operational chaos at scale**: Agents fix the same bug twice, designs go missing, and the merge queue becomes a bottleneck that one component (the Refinery) must serialize through.
- **Cost opacity**: At ~$100/hour in API tokens across 12-30 agents, there's no built-in resource governance or cost controls.

These aren't criticisms — they're the natural growing pains of a system that was, by its creator's admission, "100% vibe coded" in 17 days. Gastown is a brilliant proof of concept. Clawstown is what happens when you build on the shoulders of that proof.

## What Clawstown Does Differently

### GitHub is Dead, Long Live GitHub

Gastown coordinates through Beads and Dolt. Clawstown coordinates through **GitHub**.

Issues are work items. Pull requests are completed work. Comments are inter-agent communication. Labels are status and priority. The GitHub API is the coordination backbone. No custom databases. No bespoke graph trackers. Just the platform that already hosts your code.

This is not a limitation — it's a feature. Every interaction between agents is visible in your repository's issue tracker. Every decision is auditable. Every piece of work produces a PR that humans can review alongside the AI agents. When something goes wrong, you don't need to understand Beads semantics or query Dolt tables — you read GitHub issues.

### Kubernetes-Native, Not Kubernetes-Inspired

Gastown calls itself "Kubernetes for AI coding agents." Clawstown actually runs on Kubernetes.

Each agent is an [OpenClaw](https://github.com/openclaw/openclaw) instance managed by the [OpenClaw Kubernetes Operator](https://github.com/openclaw-rocks/k8s-operator). This means:

- **Self-healing**: Agents that crash get restarted automatically. No Deacon watching a Boot watching a Witness — just Kubernetes doing what Kubernetes does.
- **Network isolation**: Each agent runs in its own security context with default-deny NetworkPolicies. Agent A cannot access Agent B's secrets.
- **Resource governance**: CPU and memory limits per agent. No single rogue agent can starve the swarm.
- **Declarative state**: The entire swarm is described in YAML. `kubectl apply` and you have a town. `kubectl delete` and it's gone. No orphaned tmux sessions.
- **Multi-node**: The swarm can span multiple machines. Lose a node, Kubernetes reschedules the agents. The town survives.
- **Observability built in**: Prometheus metrics, Grafana dashboards, structured logging. Know exactly what your swarm is doing and what it costs.

### Self-Organizing, Not Top-Down

Gastown has a Mayor that plans all work upfront. Clawstown agents **self-organize**.

Every agent is identical. The first agent to start reads `SWARM.md` from the repository, analyzes the codebase, and creates GitHub issues. Other agents claim unclaimed issues, implement changes, and review each other's PRs. After merging, agents run the test suite and create new issues from any failures. When goals from SWARM.md are met, they stop.

No single point of failure. No coordinator bottleneck. No role assignments at deploy time. The swarm figures it out.

### A Small Swarm is Still a Swarm

Gastown targets 20-30 agents. Clawstown starts at **2**. This is intentional.

Running 30 agents at $100/hour is a bold statement. Running 2-5 agents that coordinate cleanly, produce reviewable PRs, and never lose state is a useful tool. You can scale up when you need to — the operator handles it — but the default is a small, focused swarm that a single developer can steer.

## Architecture

```
                    +-----------+
                    |  You      |
                    |  (Human)  |
                    +-----+-----+
                          |
                    SWARM.md in repo
                    (goals & focus)
                          |
                          v
          +---------+--+  +--+---------+
          |  Agent 0   |  |  Agent 1   |        ... Agent N
          |  (OpenClaw |  |  (OpenClaw |        (scales via
          |  Instance) |  |  Instance) |         operator)
          |            |  |            |
          | - Reads    |  | - Reads    |
          |   PROJECT  |  |   PROJECT  |
          | - Creates  |  | - Claims   |
          |   issues   |  |   issues   |
          | - Codes    |  | - Codes    |
          | - Reviews  |  | - Reviews  |
          |   peers    |  |   peers    |
          | - Runs     |  | - Runs     |
          |   tests    |  |   tests    |
          +-----+------+  +------+-----+
                |                 |
                +--------+--------+
                         |
                    GitHub Repo
                  (coordination
                   backbone)
                         |
                   +-----+-----+
                   | SWARM.md |
                   | (the spec) |
                   +------------+
```

### How It Works

All agents are structurally identical OpenClaw instances. They self-organize through a shared protocol:

1. **Human** creates `SWARM.md` in the target repository describing goals for the swarm
2. **Human** runs `clawstown.sh` with `--repo` pointing to the repository
3. **clawstown.sh** deploys the operator and creates N agent instances on Kubernetes
4. **First agent** clones the repo, reads SWARM.md, analyzes the codebase, and creates GitHub issues
5. **All agents** claim unclaimed issues, create branches, implement changes, and open PRs
6. **Agents** review each other's PRs — at least one non-author approval required before merge
7. **After merging**, agents pull latest main and run the test suite
8. **If tests fail**, agents create new `clawstown:failing` issues from the failures
9. **Agents** continuously check SWARM.md goals against the current state of the codebase
10. **Human** steers the swarm by updating SWARM.md — agents pick up changes on their next pull

### Why GitHub for Coordination

| | Gastown (Beads + Dolt) | Clawstown (GitHub) |
|---|---|---|
| **Persistence** | Dolt database (versioned SQL) | GitHub API (managed SaaS) |
| **Work items** | Beads (custom hash-ID format) | GitHub Issues |
| **Completed work** | Merge requests via Refinery | Pull Requests |
| **Agent communication** | Nudges (periodic pings) | Issue/PR comments |
| **Status tracking** | Hook + Convoy state machine | Labels + Project boards |
| **Auditability** | Query Dolt tables | Read the issue tracker |
| **Setup cost** | Install Dolt + Beads + Gas Town CLI | Have a GitHub account |
| **Failure recovery** | Seance (context recovery from dead sessions) | K8s restarts pod, agent reads issue state from GitHub |
| **Merge serialization** | Refinery (single-threaded queue) | GitHub branch protection + peer review |

## Quick Start

### Prerequisites

- A GitHub repository with a `SWARM.md` file describing your goals
- An Anthropic API key
- A GitHub personal access token (with `repo` scope)
- Either: [kind](https://kind.sigs.k8s.io/) installed (for local clusters) or an existing kubeconfig

### Deploy

```bash
# Clone Clawstown
git clone https://github.com/openclaw-rocks/clawstown.git
cd clawstown

# Start a local swarm with 2 agents (default)
./clawstown.sh \
  --repo https://github.com/your-org/your-project \
  --anthropic-api-key $ANTHROPIC_API_KEY \
  --github-token $GITHUB_TOKEN

# Scale up to 4 agents on an existing cluster
./clawstown.sh \
  --repo https://github.com/your-org/your-project \
  --anthropic-api-key $ANTHROPIC_API_KEY \
  --github-token $GITHUB_TOKEN \
  --kubeconfig ~/.kube/config \
  --agents 4
```

### What Happens

1. A Kind cluster spins up (or the provided kubeconfig is used)
2. The [OpenClaw Operator](https://github.com/openclaw-rocks/k8s-operator) is installed via Helm
3. API keys and GitHub tokens are stored as Kubernetes Secrets
4. Agent instances are deployed with the self-organizing prompt (`AGENTS.md`), `gh-issues` skill, and GitHub access
5. The first agent reads SWARM.md from the repo and creates issues
6. Agents start claiming issues, coding, opening PRs, and reviewing each other
7. After each merge, agents run tests and create issues from any failures

### Steering the Swarm

The human steers by editing `SWARM.md` in the target repo:

```markdown
# SWARM.md

## Goals
- Add user authentication with JWT tokens
- Implement role-based access control
- Write integration tests for all auth endpoints

## Focus
Start with the JWT middleware — everything else depends on it.
```

Push a change to SWARM.md and the agents pick it up on their next pull. No redeployment needed.

### Monitor

```bash
# Watch the swarm
kubectl get openclawinstances -n clawstown

# Follow an agent's logs
kubectl logs -f -n clawstown sts/clawstown-agent-0 -c openclaw

# Or just check GitHub — that's where all the real action is
```

## Configuration

### clawstown.sh Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--repo` | Yes | — | GitHub repository URL (must contain SWARM.md) |
| `--anthropic-api-key` | Yes | `$ANTHROPIC_API_KEY` | Anthropic API key |
| `--github-token` | Yes | `$GITHUB_TOKEN` | GitHub PAT with `repo` scope |
| `--agents` | No | `2` | Number of agents |
| `--model` | No | `anthropic/claude-sonnet-4-20250514` | Model for all agents |
| `--kubeconfig` | No | — | Path to kubeconfig (skips Kind cluster creation) |
| `--namespace` | No | `clawstown` | Kubernetes namespace |
| `--cluster-name` | No | `clawstown` | Kind cluster name (when creating a new cluster) |

### Customizing Agent Behavior

The agent prompt is a single Markdown file, injected as `AGENTS.md` (which OpenClaw auto-loads into context on startup):

```
prompts/
  agent.md       # System prompt for all agents (deployed as AGENTS.md)
```

Edit this to change how agents think, plan, and collaborate. The prompt is the soul of the swarm.

Agents are deployed with the `gh-issues` skill for GitHub interaction (issues, PRs, reviews) via the REST API. No `gh` CLI installation needed.

## Comparison with Gastown

Clawstown does not aim to replace Gastown. It aims to show that the same idea — a coordinated swarm of AI coding agents — can be built on standard infrastructure with fewer moving parts.

| Aspect | Gastown | Clawstown |
|---|---|---|
| **Created by** | Steve Yegge | openclaw-rocks community |
| **Runtime** | Local machine (tmux) | Kubernetes (any cluster) |
| **Agent framework** | Claude Code CLI (+ others) | OpenClaw |
| **Coordination** | Beads + Dolt | GitHub Issues + PRs |
| **Agent count** | 20-30 | 2-5 (scalable) |
| **Organization** | Hierarchical (Mayor plans) | Self-organizing (agents coordinate as peers) |
| **Recovery** | Manual (git push --force) | Automatic (K8s self-healing) |
| **Isolation** | Git worktrees | K8s pods + NetworkPolicies |
| **Observability** | Logs | Prometheus + Grafana |
| **Setup** | Go + Dolt + Beads + tmux | `./clawstown.sh` |
| **Merge strategy** | Refinery (serialized) | GitHub branch protection + peer review |
| **Cost control** | None built-in | K8s resource limits + metrics |
| **State after crash** | Beads in Git | GitHub Issues (external) |
| **Human steering** | Rewrite project description | Update SWARM.md in repo |

## Project Status

Clawstown is in its earliest stage. The vision is clear; the implementation is beginning. Contributions, ideas, and feedback are welcome.

## License

Apache-2.0

## Acknowledgments

- [Steve Yegge](https://github.com/steveyegge) for Gastown — the project that proved AI agent swarms are not science fiction
- [Peter Steinberger](https://github.com/steipete) for OpenClaw — the agent platform that makes this possible
- The [OpenClaw.rocks](https://openclaw.rocks) community for the Kubernetes operator that ties it all together
