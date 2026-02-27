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

### A Small Swarm is Still a Swarm

Gastown targets 20-30 agents. Clawstown starts at **3**: one Mayor and two workers. This is intentional.

Running 30 agents at $100/hour is a bold statement. Running 3-5 agents that coordinate cleanly, produce reviewable PRs, and never lose state is a useful tool. You can scale up when you need to — the operator handles it — but the default is a small, focused swarm that a single developer can steer.

## Architecture

```
                    +-----------+
                    |  You      |
                    |  (Human)  |
                    +-----+-----+
                          |
                    project description
                    + GitHub repo
                          |
                          v
               +----------+----------+
               |       Mayor         |
               |  (OpenClaw Instance)|
               |                     |
               |  - Decomposes work  |
               |  - Creates issues   |
               |  - Reviews PRs      |
               |  - Final quality    |
               |    gate             |
               +----+--------+------+
                    |        |
             assigns issues  reviews PRs
                    |        |
          +---------+--+  +--+---------+
          |  Worker 1  |  |  Worker 2  |        ... Worker N
          |  (OpenClaw |  |  (OpenClaw |        (scales via
          |  Instance) |  |  Instance) |         operator)
          |            |  |            |
          | - Picks up |  | - Picks up |
          |   issues   |  |   issues   |
          | - Codes in |  | - Codes in |
          |   branches |  |   branches |
          | - Opens    |  | - Opens    |
          |   PRs      |  |   PRs      |
          +-----+------+  +------+-----+
                |                 |
                +--------+--------+
                         |
                    GitHub Repo
                  (coordination
                     backbone)
```

### Roles

**Mayor** — The coordinator. Receives the project description, decomposes it into GitHub issues, assigns work to workers, and reviews every PR before merge. The Mayor never writes production code. It thinks, plans, and judges. It is the final reviewer.

**Worker** — The builder. Each worker picks up assigned GitHub issues, creates a feature branch, implements the change, writes tests, and opens a PR. Workers can be given specialized roles through their OpenClaw configuration (e.g., "you are a backend specialist" or "you focus on testing"), but structurally they are identical OpenClaw instances.

### Coordination Flow

1. **Human** provides a project description and target GitHub repository to `clawstown.sh`
2. **clawstown.sh** deploys the operator and creates the Mayor + Worker instances on Kubernetes
3. **Mayor** reads the project description, analyzes the repository, and creates GitHub issues with clear acceptance criteria
4. **Mayor** assigns issues to workers via GitHub labels or assignees
5. **Workers** poll for assigned issues, create branches, implement changes, and open PRs
6. **Mayor** reviews PRs against the original issue requirements, requests changes or approves
7. **Mayor** merges approved PRs and updates the project status
8. **Human** monitors progress through GitHub's native UI — issues, PRs, and the project board

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
| **Merge serialization** | Refinery (single-threaded queue) | GitHub branch protection + Mayor review |

## Quick Start

### Prerequisites

- A GitHub repository to work on
- An Anthropic API key
- A GitHub personal access token (with `repo` scope)
- Either: [kind](https://kind.sigs.k8s.io/) installed (for local clusters) or an existing kubeconfig

### Deploy

```bash
# Clone Clawstown
git clone https://github.com/openclaw-rocks/clawstown.git
cd clawstown

# Start a local swarm with 2 workers
./clawstown.sh \
  --repo https://github.com/your-org/your-project \
  --description "Add user authentication with JWT tokens and role-based access control" \
  --anthropic-api-key $ANTHROPIC_API_KEY \
  --github-token $GITHUB_TOKEN \
  --workers 2

# Or use an existing cluster
./clawstown.sh \
  --repo https://github.com/your-org/your-project \
  --description "Refactor the payment module to support Stripe and PayPal" \
  --anthropic-api-key $ANTHROPIC_API_KEY \
  --github-token $GITHUB_TOKEN \
  --kubeconfig ~/.kube/config \
  --namespace clawstown \
  --workers 4
```

### What Happens

1. A Kind cluster spins up (or the provided kubeconfig is used)
2. The [OpenClaw Operator](https://github.com/openclaw-rocks/k8s-operator) is installed via Helm
3. API keys and GitHub tokens are stored as Kubernetes Secrets
4. The **Mayor** instance is deployed with the project description and coordinator prompt
5. **Worker** instances are deployed with developer prompts and GitHub access
6. The Mayor begins decomposing work and creating issues
7. Workers start picking up issues and opening PRs

### Monitor

```bash
# Watch the swarm
kubectl get openclawinstances -n clawstown

# Follow the Mayor's logs
kubectl logs -f -n clawstown sts/clawstown-mayor -c openclaw

# Follow a worker's logs
kubectl logs -f -n clawstown sts/clawstown-worker-0 -c openclaw

# Or just check GitHub — that's where all the real action is
```

## Configuration

### clawstown.sh Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `--repo` | Yes | — | GitHub repository URL (https or ssh) |
| `--description` | Yes | — | Project description / goal for the swarm |
| `--anthropic-api-key` | Yes | `$ANTHROPIC_API_KEY` | Anthropic API key |
| `--github-token` | Yes | `$GITHUB_TOKEN` | GitHub PAT with `repo` scope |
| `--workers` | No | `2` | Number of worker agents |
| `--kubeconfig` | No | — | Path to kubeconfig (skips Kind cluster creation) |
| `--namespace` | No | `clawstown` | Kubernetes namespace |
| `--mayor-model` | No | `anthropic/claude-sonnet-4-20250514` | Model for the Mayor |
| `--worker-model` | No | `anthropic/claude-sonnet-4-20250514` | Model for workers |
| `--worker-roles` | No | — | Comma-separated role hints (e.g., `backend,frontend,testing`) |
| `--cluster-name` | No | `clawstown` | Kind cluster name (when creating a new cluster) |

### Customizing Agent Behavior

The Mayor and worker prompts are Markdown files in `prompts/`:

```
prompts/
  mayor.md       # System prompt for the Mayor
  worker.md      # Base system prompt for all workers
  roles/
    backend.md   # Additional instructions for backend-focused workers
    frontend.md  # Additional instructions for frontend-focused workers
    testing.md   # Additional instructions for testing-focused workers
```

Edit these to change how agents think, plan, and collaborate. The prompts are the soul of the swarm.

## Comparison with Gastown

Clawstown does not aim to replace Gastown. It aims to show that the same idea — a coordinated swarm of AI coding agents — can be built on standard infrastructure with fewer moving parts.

| Aspect | Gastown | Clawstown |
|---|---|---|
| **Created by** | Steve Yegge | openclaw-rocks community |
| **Runtime** | Local machine (tmux) | Kubernetes (any cluster) |
| **Agent framework** | Claude Code CLI (+ others) | OpenClaw |
| **Coordination** | Beads + Dolt | GitHub Issues + PRs |
| **Agent count** | 20-30 | 3-5 (scalable) |
| **Recovery** | Manual (git push --force) | Automatic (K8s self-healing) |
| **Isolation** | Git worktrees | K8s pods + NetworkPolicies |
| **Observability** | Logs | Prometheus + Grafana |
| **Setup** | Go + Dolt + Beads + tmux | `./clawstown.sh` |
| **Merge strategy** | Refinery (serialized) | GitHub branch protection |
| **Cost control** | None built-in | K8s resource limits + metrics |
| **State after crash** | Beads in Git | GitHub Issues (external) |

## Project Status

Clawstown is in its earliest stage. The vision is clear; the implementation is beginning. Contributions, ideas, and feedback are welcome.

## License

Apache-2.0

## Acknowledgments

- [Steve Yegge](https://github.com/steveyegge) for Gastown — the project that proved AI agent swarms are not science fiction
- [Peter Steinberger](https://github.com/steipete) for OpenClaw — the agent platform that makes this possible
- The [OpenClaw.rocks](https://openclaw.rocks) community for the Kubernetes operator that ties it all together
