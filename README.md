# Job Orchestrator

A production-grade distributed job orchestration system built with Ruby on Rails, MySQL, Redis, and Sidekiq.

## Features

- **Strict State Machine**: Jobs follow `queued → running → completed | failed | stalled` with atomic, crash-safe transitions
- **Dynamic Concurrency Quotas**: Per-client limits enforced cluster-wide via Redis, updateable without restarts
- **Priority + Fairness Scheduling**: Deficit Round Robin algorithm prevents client starvation while respecting priority
- **Dead Man's Switch**: Heartbeat monitoring with automatic stall detection and recovery
- **Exponential Backoff Retries**: Failed/stalled jobs retry with jitter, respecting concurrency quotas
- **Abuse Protection**: Rack::Attack rate limiting (per-client and global)
- **Observability**: Detailed health endpoint with component-level status

## Architecture

See [DESIGN.md](DESIGN.md) for detailed architectural decisions, scaling strategies, and failure mode analysis.

## Requirements

- Ruby 3.2+
- MySQL 8.0+
- Redis 6.0+
- Bundler

## Quick Start

### 1. Clone and Install Dependencies

```bash
git clone <repository-url>
cd job_orchestrator
bundle install
```

### 2. Using Docker Compose (Recommended)

The easiest way to get MySQL and Redis running:

```bash
docker-compose up -d mysql redis
```

### 3. Database Setup

```bash
# Create databases and run migrations
bundle exec rails db:create
bundle exec rails db:migrate

# Seed default client quotas (optional)
bundle exec rails db:seed
```

### 4. Start the Application

```bash
# Terminal 1: Rails API server
bundle exec rails server

# Terminal 2: Sidekiq worker
bundle exec sidekiq -C config/sidekiq.yml
```

### 5. Submit a Job

```bash
curl -X POST http://localhost:3000/jobs \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "acme_corp",
    "priority": "high",
    "workload": "process_assessment"
  }'
```

### 6. Check Job Status

```bash
curl http://localhost:3000/jobs/1
```

### 7. Health Check

```bash
curl http://localhost:3000/health/detailed
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DB_HOST` | `127.0.0.1` | MySQL host |
| `DB_PORT` | `3306` | MySQL port |
| `DB_USERNAME` | `root` | MySQL username |
| `DB_PASSWORD` | (empty) | MySQL password |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL |
| `RAILS_MAX_THREADS` | `5` | Database connection pool size |
| `SIDEKIQ_CONCURRENCY` | `10` | Sidekiq worker threads |

## Running Tests

```bash
# Full test suite
bundle exec rspec

# With coverage report
COVERAGE=true bundle exec rspec

# Specific test file
bundle exec rspec spec/services/job_state_machine_spec.rb

# Only model tests
bundle exec rspec spec/models/

# Only request tests
bundle exec rspec spec/requests/
```

## Project Structure

```
app/
├── controllers/
│   ├── application_controller.rb  # Global error handling
│   ├── jobs_controller.rb         # POST /jobs, GET /jobs/:id
│   └── health_controller.rb       # GET /health/detailed
├── models/
│   ├── job.rb                     # Job model with validations/scopes
│   └── client_quota.rb            # Per-client concurrency limits
├── services/
│   ├── job_state_machine.rb       # Atomic state transitions
│   ├── concurrency_guard.rb       # Redis-based quota enforcement
│   ├── job_submission_service.rb  # Job creation and validation
│   ├── scheduler.rb               # Deficit Round Robin scheduling
│   ├── job_executor.rb            # Workload execution + heartbeat
│   ├── heartbeat_monitor.rb       # Stall detection
│   ├── retry_handler.rb           # Exponential backoff retries
│   └── health_checker.rb          # Component health aggregation
├── workers/
│   ├── scheduler_worker.rb        # Periodic scheduling (every 5s)
│   ├── job_executor_worker.rb     # Individual job execution
│   └── stall_monitor_worker.rb    # Periodic stall check (every 30s)
spec/
├── models/                        # Model validation tests
├── services/                      # Service unit tests
├── requests/                      # API integration tests
└── support/                       # Test helpers
```

## API Reference

### POST /jobs

Submit a job for asynchronous execution.

**Request:**
```json
{
  "client_id": "string (required)",
  "priority": "low | medium | high (required)",
  "workload": "string (required)",
  "idempotency_key": "string (optional)"
}
```

**Response (201 Created):**
```json
{
  "id": 1,
  "client_id": "acme_corp",
  "priority": "high",
  "workload": "process_assessment",
  "state": "queued",
  "retry_count": 0,
  "scheduled_at": "2024-01-01T00:00:00Z",
  "created_at": "2024-01-01T00:00:00Z"
}
```

### GET /jobs/:id

Get the current status of a job.

### GET /health/detailed

Returns component-level health status.

**Response (200 OK / 503 Service Unavailable):**
```json
{
  "status": "healthy",
  "components": {
    "database": { "healthy": true, "latency_ms": 1.2 },
    "redis": { "healthy": true, "latency_ms": 0.5 },
    "sidekiq": { "healthy": true, "latency_seconds": 0.0, "size": 0 },
    "jobs": { "queued": 5, "running": 2, "completed": 100, "failed": 1, "stalled": 0 }
  },
  "timestamp": "2024-01-01T00:00:00Z"
}
```

## Design Decisions

See [DESIGN.md](DESIGN.md) for comprehensive coverage of:
- Scaling to 100k jobs/hour
- Redis failure recovery
- Split-brain handling
- Frozen worker recovery
- Abuse protection strategies

## Assumptions

1. **Workload simulation**: The `workload` field is a task identifier. In production, this would dispatch to actual task handlers. For this submission, workloads are simulated with configurable durations.
2. **At Least Once semantics**: We guarantee jobs execute at least once. Workloads should be designed to be idempotent.
3. **Clock synchronization**: We assume reasonable clock sync across cluster nodes (within a few seconds). NTP is sufficient.
4. **Single MySQL instance**: The schema supports read replicas but doesn't implement multi-primary. For the scale requirements, a single primary with replicas is sufficient.
