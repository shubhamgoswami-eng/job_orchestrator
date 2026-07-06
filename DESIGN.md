# DESIGN.md — Distributed Job Orchestrator

## Architecture Overview

```
┌──────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│   Rails API   │────▶│   MySQL (State)   │◀────│   Sidekiq Workers    │
│  POST /jobs   │     │  jobs table       │     │  SchedulerWorker     │
│  GET /health  │     │  client_quotas    │     │  JobExecutorWorker   │
└──────┬───────┘     └──────────────────┘     │  StallMonitorWorker  │
       │                                       └────────┬─────────────┘
       │             ┌──────────────────┐               │
       └────────────▶│   Redis           │◀──────────────┘
                     │  heartbeat:{id}   │
                     │  concurrency:{cid}│
                     │  Sidekiq queues   │
                     └──────────────────┘
```

### Key Design Decisions

1. **Scheduler/Executor Separation**: The `SchedulerWorker` is the single decision-maker for what runs next. It picks jobs using Deficit Round Robin, acquires concurrency slots, transitions to `running`, and enqueues `JobExecutorWorker`. The executor is stateless — it only runs the workload and manages its heartbeat.

2. **State Machine without Gems**: Instead of using `aasm` or `state_machines`, we use raw `UPDATE ... WHERE state = ? AND lock_version = ?` for atomic transitions. This is more predictable and debuggable for distributed systems where race conditions are the primary concern.

3. **Redis Lua for Concurrency**: The `ConcurrencyGuard` uses a Lua script for atomic check-and-increment. This prevents the TOCTOU race condition where two workers both see `count < limit` and both proceed.

4. **Sorted Sets for Slot Tracking**: We use Redis Sorted Sets (not counters) for concurrency tracking. This lets us enumerate running jobs for debugging and reaper operations, and the score (timestamp) enables orphan detection.

---

## Part 3: Scaling & Design Questions

### 1. Scaling to 100k Jobs/Hour

At 100k jobs/hour (~28 jobs/second), the primary bottlenecks are:

#### Redis Contention
- **Problem**: A single `concurrency:{client_id}` key becomes a hotspot if many workers contend on it.
- **Mitigation**:
  - The Lua script is atomic and fast (<1ms), so contention is minimal at 28 jobs/sec.
  - At higher scale (1M+/hour), we would shard Redis by `client_id` hash: `concurrency:{hash(client_id) % N}` across N Redis instances.
  - Use Redis Cluster with hash tags to keep related keys on the same shard: `{client_id}:concurrency`, `{client_id}:heartbeat`.

#### Scheduler Bottleneck
- **Problem**: A single SchedulerWorker scanning all clients becomes a bottleneck.
- **Mitigation**:
  - **Partition by client**: Run N scheduler instances, each responsible for `client_id % N`. This is the "Scheduler" vs "Executor" separation — schedulers make decisions, executors run workloads.
  - **Index optimization**: The `idx_jobs_scheduling` composite index on `(state, scheduled_at, priority)` keeps the scheduling query fast even with millions of rows.
  - **Batch dispatching**: The scheduler dispatches up to `MAX_DISPATCH_PER_CYCLE = 50` jobs per invocation to prevent thundering herd effects.

#### Database Bottleneck
- **Problem**: `UPDATE ... WHERE state = 'queued'` causes row-level lock contention.
- **Mitigation**:
  - Each scheduling query fetches a specific `client_id + state` combination, which uses the `idx_jobs_client_state` index.
  - At extreme scale, partition the `jobs` table by `client_id` (MySQL native partitioning).
  - Use read replicas for status queries (`GET /jobs/:id`, health checks).

#### Architecture at Scale
```
                    ┌─────────────────┐
                    │  Load Balancer   │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
         ┌────┴───┐    ┌────┴───┐    ┌────┴───┐
         │ Rails 1 │    │ Rails 2 │    │ Rails 3 │
         └────┬───┘    └────┬───┘    └────┬───┘
              │              │              │
              └──────────────┼──────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
    ┌────┴────┐        ┌────┴────┐        ┌────┴────┐
    │Scheduler│        │Scheduler│        │Scheduler│
    │ Shard 0 │        │ Shard 1 │        │ Shard 2 │
    └────┬────┘        └────┬────┘        └────┬────┘
         │                   │                   │
         └───────────────────┼───────────────────┘
                             │
    ┌────────────────────────┼────────────────────────┐
    │                        │                        │
┌───┴────┐  ┌───┴────┐  ┌───┴────┐  ┌───┴────┐  ┌───┴────┐
│Executor│  │Executor│  │Executor│  │Executor│  │Executor│
│Pool 1  │  │Pool 2  │  │Pool 3  │  │Pool 4  │  │Pool 5  │
└────────┘  └────────┘  └────────┘  └────────┘  └────────┘
```

---

### 2. Failure Modes

#### What happens if Redis loses all keys (`FLUSHALL`)?

**Impact**:
- All heartbeat keys disappear → StallMonitorWorker would detect all running jobs as "stalled".
- All concurrency tracking lost → ConcurrencyGuard would allow unlimited new starts.

**Mitigation strategy** (implemented):
1. **HeartbeatMonitor checks Redis availability first**: If `redis.exists?` raises `Redis::BaseError`, we return `false` (don't stall). This prevents mass-stalling during Redis outages.
2. **Concurrency Guard fails closed**: If Redis is unreachable, `acquire()` returns `false` — no new jobs start.
3. **Recovery procedure**:
   - After Redis comes back, the StallMonitorWorker will naturally detect genuinely crashed jobs (their heartbeat keys were never re-created).
   - For concurrency slots, running a recovery Rake task that reads `Job.where(state: 'running')` and re-populates the Redis sorted sets would restore consistency.

**Improvement for production**: Add a Redis key `redis:boot_time` on startup. If the monitor detects this key changed (Redis restarted), enter a "grace period" where stall detection is paused for 2 minutes to let running workers re-establish heartbeats.

#### How do you handle a "split-brain" where two workers try to stall the same job?

**Implemented solution**: `JobStateMachine.transition!` uses `UPDATE jobs SET state = 'stalled' WHERE id = ? AND state = 'running' AND lock_version = ?`. This returns `affected_rows`. Only the first caller gets `affected_rows == 1`. The second gets `0` and receives a `Result(success: false)`.

This is inherently safe because:
1. MySQL row-level locks serialize concurrent UPDATEs on the same row.
2. The `WHERE state = 'running'` clause means the second attempt finds no matching row.
3. No side effects are triggered on failure (idempotent).

#### How do you handle a worker that is "frozen" (e.g., long GC pause) for 2 minutes?

**Scenario**:
1. Worker freezes during execution (GC pause, I/O stall).
2. Heartbeat thread also freezes (same process).
3. After 60 seconds, heartbeat key expires in Redis.
4. StallMonitorWorker detects expired heartbeat → transitions to `stalled`.
5. RetryHandler re-queues the job.
6. SchedulerWorker picks it up and dispatches to another executor.
7. Worker unfreezes after 2 minutes and tries to complete the original job.

**Safety**:
- The unfrozen worker calls `JobStateMachine.transition!(job, :completed)`.
- But `job.state` in its memory is `running`, while the DB has `stalled` (or re-`running` on another worker).
- The `WHERE state = 'running' AND lock_version = ?` check fails because `lock_version` has changed.
- The transition is rejected. The worker logs a warning and releases its slot.
- The new worker continues unaffected.

**Duplicate execution risk**: The workload may have been partially executed by both workers. This is why the assignment emphasizes "At Least Once" semantics with idempotency. The `idempotency_key` field and the workload itself should be designed to handle duplicate execution (e.g., using database upserts, idempotent API calls).

---

### 3. Abuse Protection

**Scenario**: A client submits 1 million jobs in 10 seconds.

#### Layer 1: Rate Limiting (Rack::Attack)
- Per-client: 100 submissions/minute
- Global: 1000 submissions/minute
- Returns HTTP 429 with a retry-after header

#### Layer 2: Concurrency Quotas
- Even if rate limiting is bypassed, `ConcurrencyGuard` ensures at most N jobs run per client.
- The remaining jobs sit in `queued` state, consuming only database rows (not CPU/memory).

#### Layer 3: Scheduler Fairness (DRR)
- The Deficit Round Robin algorithm ensures other clients still get scheduled.
- A client with 1M queued jobs gets the same scheduling "credits" as a client with 10 jobs — proportional to their highest priority, not their queue depth.

#### Layer 4: Database Protection
- The `MAX_DISPATCH_PER_CYCLE = 50` limit prevents the scheduler from attempting to dispatch all 1M jobs at once.
- MySQL's `LIMIT` clause in queries prevents full-table scans.
- Composite indexes on `(client_id, state)` keep query performance constant regardless of total job count.

#### Additional Protection (if more time):
- **Admission control**: Reject submissions when a client already has >10k queued jobs.
- **Priority degradation**: Automatically downgrade a flooding client's priority to "low".
- **Queue depth alerting**: Trigger ops alerts when any client's queue depth exceeds a threshold.

---

## Retry Strategy: "At Least Once" with Idempotency

We implement **At Least Once** processing because true **Exactly Once** is impossible in distributed systems (see: [Two Generals' Problem](https://en.wikipedia.org/wiki/Two_Generals%27_Problem)).

### How It Works

1. **At Least Once**: If a job fails or stalls, it is retried. The workload may be executed more than once.
2. **Idempotency**: The `idempotency_key` field ensures that duplicate submissions create only one job. The workload execution itself should be designed to be idempotent (e.g., using database `INSERT ... ON DUPLICATE KEY UPDATE`, or checking for prior completion before performing side effects).
3. **Exponential Backoff**: Delays between retries grow exponentially (`5s, 10s, 20s, 40s, 80s`) with ±25% jitter to prevent thundering herd effects.
4. **Quota-Respecting Retries**: Retried jobs re-enter the scheduler queue and must acquire a concurrency slot before executing. They do NOT bypass the quota system.

---

## State Machine

```
           ┌──────────────────────────────────────────────┐
           │                                              │
           ▼                                              │
        ┌──────┐    acquire slot    ┌─────────┐          │
   ────▶│queued│──────────────────▶│ running  │          │
        └──────┘                    └────┬─────┘          │
           ▲                             │                │
           │                    ┌────────┼────────┐       │
           │                    │        │        │       │
           │               ┌────▼──┐ ┌───▼───┐ ┌──▼────┐ │
           │               │failed │ │complete│ │stalled│ │
           │               └───┬───┘ └───────┘ └───┬───┘ │
           │                   │                    │     │
           │     retry         │      retry         │     │
           └───────────────────┘────────────────────┘     │
```

All transitions are guarded by:
- **State check**: `WHERE state = ?` prevents illegal transitions
- **Optimistic locking**: `WHERE lock_version = ?` prevents concurrent modifications
- **Atomic UPDATE**: Single SQL statement, no read-then-write race condition
