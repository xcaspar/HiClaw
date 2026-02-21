---
name: worker-management
description: Manage the full lifecycle of Worker Agents (create, configure, monitor, reset). Use when the human admin requests creating a new worker or resetting a worker.
---

# Worker Management

## Overview

This skill allows you to manage the full lifecycle of Worker Agents: creation, configuration, monitoring, and reset. Workers are lightweight containers that connect to the Manager via Matrix and use the centralized file system.

## Create a Worker

### Step 1: Write SOUL.md

Write the Worker's identity file based on the human admin's description:

```bash
mkdir -p ~/hiclaw-fs/agents/<WORKER_NAME>
cat > ~/hiclaw-fs/agents/<WORKER_NAME>/SOUL.md << 'EOF'
# Worker Agent - <WORKER_NAME>
... (role, skills, communication rules, security rules, etc.)
EOF
```

### Step 1.5: Determine skills based on worker role

**This step is mandatory before running the create script.** The available skills grow over time — never rely on memory. Always re-scan the skill definitions and read each one's assignment condition fresh.

1. List all available skills:
   ```bash
   ls ~/manager-workspace/worker-skills/
   ```

2. Read the YAML frontmatter at the top of each skill's `SKILL.md` to get its `assign_when` condition:
   ```bash
   head -8 ~/manager-workspace/worker-skills/<skill-name>/SKILL.md
   ```
   Each `SKILL.md` starts with:
   ```yaml
   ---
   name: <skill-name>
   description: <one-line summary of what this skill does>
   assign_when: <description of what role/responsibility warrants this skill>
   ---
   ```

3. Match each skill's `assign_when` against the Worker's role description and SOUL.md content. If it fits, include the skill.

4. Collect all matched skills. `file-sync` does not need to be specified — the script adds it automatically.

**When in doubt, assign more rather than fewer** — a missing skill blocks the Worker from completing tasks and can only be fixed later, while an extra skill causes no harm.

Pass the matched skills as a comma-separated string to `--skills`, e.g. `file-sync,github-operations`

### Step 2: Run create-worker script

The script handles everything: Matrix registration, room creation, Higress consumer, AI/MCP authorization, config generation, MinIO sync, skills push, and container startup.

```bash
bash /opt/hiclaw/agent/skills/worker-management/scripts/create-worker.sh --name <WORKER_NAME> [--model <MODEL_ID>] [--mcp-servers s1,s2] [--skills s1,s2] [--remote]
```

**Parameters**:
- `--name` (required): Worker name
- `--model`: optional, bare model name (e.g. `qwen3.5-plus`). Defaults to `${HICLAW_DEFAULT_MODEL}`
- `--mcp-servers`: optional, comma-separated MCP server names. Defaults to all existing MCP servers
- `--skills`: comma-separated skill names determined in Step 1.5 (e.g. `file-sync,github-operations`). Defaults to `file-sync` if omitted. `file-sync` is always included automatically
- `--remote`: force output install command instead of starting container locally

**Deployment behavior** (without `--remote`):
- If container socket is available: auto-starts Worker container locally
- If no socket: falls back to outputting install command

The script outputs a JSON result after `---RESULT---`:

```json
{
  "worker_name": "xiaozhang",
  "matrix_user_id": "@xiaozhang:matrix-local.hiclaw.io:8080",
  "room_id": "!abc:matrix-local.hiclaw.io:8080",
  "consumer": "worker-xiaozhang",
  "skills": ["file-sync", "github-operations"],
  "mode": "local",
  "container_id": "abc123...",
  "status": "started"
}
```

Report the result to the human admin. If `status` is `"pending_install"`, provide the `install_cmd` from the JSON output. Also remind the admin that for remote deployment, the Worker machine must be able to resolve these domains to the Manager's IP (via DNS or `/etc/hosts`):

- `${HICLAW_MATRIX_DOMAIN}` (Matrix homeserver, e.g. `matrix-local.hiclaw.io`)
- `${HICLAW_AI_GATEWAY_DOMAIN}` (AI Gateway, e.g. `llm-local.hiclaw.io`)
- `${HICLAW_FS_DOMAIN}` (MinIO file system, e.g. `fs-local.hiclaw.io`)

For local deployment these are auto-resolved via container ExtraHosts.

### Post-creation verification

After a local deployment (`mode: "local"`), verify the Worker is running:

```bash
bash -c 'source /opt/hiclaw/scripts/lib/container-api.sh && container_status_worker "<WORKER_NAME>"'
bash -c 'source /opt/hiclaw/scripts/lib/container-api.sh && container_logs_worker "<WORKER_NAME>" 20'
```

## Monitor Workers

### Heartbeat Check (automated every 15 minutes)

The heartbeat prompt triggers automatically. When it fires:

1. Scan `~/hiclaw-fs/shared/tasks/*/meta.json` to find all tasks with `"status": "assigned"`
2. For each in-progress task, read `assigned_to` and `room_id` from its meta.json
3. Ask the assigned Worker for status in their Room
4. If a Worker confirms completion, update the task's meta.json: `"status": "completed"`, fill in `completed_at`
5. Assess capacity vs pending tasks (count `"status": "assigned"` tasks vs idle Workers)

### Manual Status Check

```bash
# List all in-progress tasks with their assigned Workers:
for meta in ~/hiclaw-fs/shared/tasks/*/meta.json; do
  jq -r '[.task_id, .assigned_to, .status] | @tsv' "$meta"
done

# Check a Worker's Room for recent activity:
curl -s "http://127.0.0.1:6167/_matrix/client/v3/rooms/<ROOM_ID>/messages?dir=b&limit=5" \
  -H "Authorization: Bearer <MANAGER_TOKEN>" | jq '.chunk[].content.body'
```

## Worker Lifecycle Management

The Manager automatically detects idle Workers during Heartbeat and stops their containers; when assigning tasks it automatically wakes up stopped containers. All state is persisted in `~/manager-workspace/worker-lifecycle.json` (local only, never synced to MinIO).

### worker-lifecycle.json Structure

```json
{
  "version": 1,
  "idle_timeout_minutes": 30,
  "updated_at": "2026-02-21T10:00:00Z",
  "workers": {
    "alice": {
      "container_status": "stopped",
      "idle_since": "2026-02-21T10:00:00Z",
      "auto_stopped_at": "2026-02-21T10:31:00Z",
      "last_started_at": "2026-02-21T08:00:00Z"
    }
  }
}
```

Fields:
- `container_status`: actual status synced from the Docker API (`running` / `stopped` / `not_found` / `remote`)
- `idle_since`: timestamp when the Worker last had no active finite tasks; set to null when a finite task is active
- `auto_stopped_at`: when the Manager auto-stopped the container (audit trail)
- `last_started_at`: when the Manager last started/woke the container

`container_status = "remote"` means the Worker is remotely deployed (no container API access) and is excluded from automatic lifecycle management.

### Manual Commands

```bash
# Sync all Worker container statuses into the lifecycle file
bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action sync-status

# Check for idle Workers and auto-stop those that have exceeded the timeout
bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action check-idle

# Manually stop a Worker container
bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action stop --worker <name>

# Manually wake up (start) a stopped Worker container
bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action start --worker <name>
```

### Changing the Idle Timeout

Edit `~/manager-workspace/worker-lifecycle.json` directly and update the `idle_timeout_minutes` field (default: 30):

```bash
# Example: change to 60 minutes
jq '.idle_timeout_minutes = 60' ~/manager-workspace/worker-lifecycle.json > /tmp/lc.json && mv /tmp/lc.json ~/manager-workspace/worker-lifecycle.json
```

### start vs create

| Situation | Command | Notes |
|-----------|---------|-------|
| Container is stopped | `lifecycle-worker.sh --action start` | Restarts the existing container, preserving all config and mounts |
| Container does not exist (`not_found`) | `create-worker.sh` | Rebuilds from image; full registration flow required |
| Worker needs reset or config update | `create-worker.sh` (removes old container first) | Full rebuild; Matrix account is reused |

## Reset a Worker

1. Revoke the Worker's Higress Consumer (or update credentials)
2. Remove Worker from AI route auth configs (`/v1/ai/routes` — GET, remove from allowedConsumers, PUT)
3. Remove Worker from MCP Server consumer lists (`/v1/mcpServer/consumers`)
4. Delete Worker's config directory: `rm -rf ~/hiclaw-fs/agents/<WORKER_NAME>/`
5. Re-create: write a new SOUL.md and run `create-worker.sh` again (the script handles re-registration gracefully)

## Manage Worker Skills

Manager centrally manages all Worker skills. The canonical skill definitions live in `~/manager-workspace/worker-skills/`. Worker skill assignments are tracked in `~/manager-workspace/workers-registry.json`.

### workers-registry.json

Location: `~/manager-workspace/workers-registry.json`

Format:
```json
{
  "version": 1,
  "updated_at": "2026-01-01T00:00:00Z",
  "workers": {
    "<worker-name>": {
      "matrix_user_id": "@<name>:<domain>",
      "room_id": "!xxx:<domain>",
      "skills": ["file-sync", "github-operations"],
      "created_at": "2026-01-01T00:00:00Z",
      "skills_updated_at": "2026-01-01T00:00:00Z"
    }
  }
}
```

`file-sync` is the bootstrap skill (image-managed) and is always included.

### worker-skills/ Directory Structure

```
~/manager-workspace/worker-skills/
├── README.md
└── github-operations/
    └── SKILL.md
```

To add a new skill, create a new subdirectory here with a `SKILL.md` (with `assign_when` frontmatter) and optional `scripts/`.

### push-worker-skills.sh

```bash
# Push all skills for a specific worker
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh --worker <name>

# Push a skill to all workers that have it (e.g., after updating the skill definition)
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh --skill <skill-name>

# Add a new skill to a worker and push it
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh --worker <name> --add-skill <skill-name>

# Remove a skill from a worker (updates registry; skill files remain in MinIO until manually removed)
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh --worker <name> --remove-skill <skill-name>

# Skip Matrix notification (e.g., when worker is not yet running)
bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh --worker <name> --no-notify
```

After pushing skills, the script notifies the affected Worker(s) via Matrix @mention to run `hiclaw-sync`. Workers' periodic 5-minute sync also serves as a fallback.

### How to Add a New Custom Skill

1. Create the skill directory under `~/manager-workspace/worker-skills/<skill-name>/` and write its files (`SKILL.md` must include `name`, `description`, and `assign_when` frontmatter; place any scripts under `scripts/`). The manager workspace is local only — use `push-worker-skills.sh` to distribute skills to workers.

2. Assign to Worker：
   ```bash
   bash /opt/hiclaw/agent/skills/worker-management/scripts/push-worker-skills.sh \
     --worker <name> --add-skill <skill-name>
   ```

## Important Notes

- Workers are **stateless containers** -- all state is in MinIO. Resetting a Worker just means recreating its config files
- Worker Matrix accounts persist in Tuwunel (cannot be deleted via API). Reuse same username on reset
- OpenClaw config hot-reload: file-watch (~300ms) or `config.patch` API
- **File sync**: after writing any file that a Worker (or another Worker) needs to read, always notify the target Worker via Matrix to run `hiclaw-sync`. This applies to config updates, task briefs, shared data, and cross-Worker collaboration artifacts. Workers have a `file-sync` skill for this. Background periodic sync (every 5 minutes) serves as fallback only
- **Skills are Manager-controlled**: Workers cannot modify their own skills (local→remote sync excludes `skills/**`). Only Manager can push skill changes via `push-worker-skills.sh`
