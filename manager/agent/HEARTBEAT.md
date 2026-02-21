## Manager Heartbeat Checklist

### 1. 读取 state.json

从本地读取 state.json（如未同步，先 mc cp 拉取）：

```bash
mc cp hiclaw/hiclaw-storage/agents/manager/state.json ~/hiclaw-fs/agents/manager/state.json 2>/dev/null || true
cat ~/hiclaw-fs/agents/manager/state.json
```

state.json 的 `active_tasks` 包含所有进行中的任务（有限任务和无限任务）。无需遍历所有 meta.json。

---

### 2. 有限任务状态询问

遍历 `active_tasks` 中 `"type": "finite"` 的条目：

- 从条目的 `assigned_to` 和 `room_id` 字段获取负责的 Worker 及对应 Room
- 在该 Worker 的 Room（或 project_room_id 若有）中 @mention Worker 询问进展：
  ```
  @{worker}:{domain} 你当前的任务 {task-id} 进展如何？有没有遇到阻塞？
  ```
- 根据 Worker 回复判断是否正常推进
- 如果 Worker 未回复（超过一个 heartbeat 周期无响应），在 Room 中标记异常并提醒人类管理员
- 如果 Worker 已回复完成但 meta.json 未更新，主动更新 meta.json（status → completed，填写 completed_at），并从 state.json 的 `active_tasks` 中删除该条目

---

### 3. 无限任务超时检查

遍历 `active_tasks` 中 `"type": "infinite"` 的条目，对每个条目：

```
当前时间 UTC = now

判断条件（同时满足）：
  1. last_executed_at < next_scheduled_at（本轮尚未执行）
     或 last_executed_at 为 null（从未执行）
  2. now > next_scheduled_at + 30分钟（已超时未执行）

若满足，在对应 room_id 中 @mention Worker 触发执行：
  @{worker}:{domain} 该执行你的定时任务 {task-id}「{task-title}」了，请现在执行并用 "executed" 关键字汇报。
```

**注意**：无限任务永不从 active_tasks 中删除。Worker 汇报 `executed` 后，Manager 更新 `last_executed_at` 和 `next_scheduled_at`，然后 mc cp 同步 state.json。

---

### 4. 项目进展监控

扫描 ~/hiclaw-fs/shared/projects/ 下所有活跃项目的 plan.md：

```bash
for meta in ~/hiclaw-fs/shared/projects/*/meta.json; do
  cat "$meta"
done
```

- 筛选 `"status": "active"` 的项目
- 对每个活跃项目，读取 plan.md，找出标记为 `[~]`（进行中）的任务
- 若该 Worker 在本 heartbeat 周期内没有活动，在项目群中 @mention：
  ```
  @{worker}:{domain} 你正在执行的任务 {task-id}「{title}」有进展吗？有遇到阻塞请告知。
  ```
- 如果项目群中有 Worker 汇报了任务完成但 plan.md 还没更新，立即处理（见 AGENTS.md 项目管理部分）

---

### 5. 容量评估

- 统计 state.json 中 type=finite 的条目数（有限任务进行中数量）和没有分配任务的空闲 Worker
- 如果 Worker 不足，循环人类管理员是否需要创建新的 Worker
- 如果有 Worker 空闲，建议重新分配任务

---

### 6. Worker 容器生命周期管理

仅当容器 API 可用时执行（先检查）：

```bash
bash -c 'source /opt/hiclaw/scripts/lib/container-api.sh && container_api_available && echo available'
```

若输出 `available`，继续执行以下步骤：

1. 同步状态：
   ```bash
   bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action sync-status
   ```

2. 检测空闲：对每个 Worker，若 state.json 中无其 finite task 且 container_status=running：
   - 若 idle_since 未设置，设为当前时间
   - 若 (now - idle_since) > idle_timeout_minutes，执行自动停止：
     ```bash
     bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action check-idle
     ```
   - 在 Manager 与该 Worker 的 Room 中记录：
     「Worker <name> 容器已因空闲超时自动暂停。有任务时将自动唤醒。」

3. 若有正在运行 finite task 的 Worker 但其容器状态为 stopped（异常情况），执行启动并告警：
   ```bash
   bash /opt/hiclaw/agent/skills/worker-management/scripts/lifecycle-worker.sh --action start --worker <name>
   ```

---

### 7. Matrix 会话过期检查（每日一次）

```bash
bash /opt/hiclaw/agent/skills/worker-management/scripts/session-keepalive.sh --action scan
```

- 若输出 `SCAN_RESULT: skipped`：跳过（距上次扫描不足 23 小时）
- 若输出 `SCAN_RESULT: all_ok`：无需处理
- 若输出包含 `NEAR_EXPIRY_ROOM:` 行：在与 Human Admin 的 DM 中通知（每行格式为 `room_id\ttype\tname\tidle`）：
  「以下 Matrix 房间的消息将在约 1 天内因空闲过期（7 天空闲限制）：
  - [worker/project] <name>（<room_id>，已空闲 Xh）
  如需保留消息，请回复需要保活的房间名称或 room_id，我将向对应房间发送消息。」

---

### 8. 回复

- 如果所有 Worker 正常且无待处理事项：HEARTBEAT_OK
- 否则：汇总发现和建议的操作，通知人类管理员
