# frozen_string_literal: true

# Aggregates health status from all infrastructure components.
#
# Checks:
#   1. Database — can we execute a simple query?
#   2. Redis — can we PING?
#   3. Sidekiq latency — is the default queue backed up?
#
# Returns HTTP 503 if any check fails or latency exceeds the threshold.
# Returns HTTP 200 when all components are healthy.
#
class HealthChecker
  SIDEKIQ_LATENCY_THRESHOLD = 15.0 # seconds

  Result = Struct.new(:healthy, :components, :timestamp, keyword_init: true)

  def self.check
    new.check
  end

  def check
    db_status = check_database
    redis_status = check_redis
    sidekiq_status = check_sidekiq

    all_healthy = db_status[:healthy] && redis_status[:healthy] && sidekiq_status[:healthy]

    Result.new(
      healthy: all_healthy,
      components: {
        database: db_status,
        redis: redis_status,
        sidekiq: sidekiq_status,
        jobs: job_summary
      },
      timestamp: Time.current.iso8601
    )
  end

  private

  def check_database
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveRecord::Base.connection.execute("SELECT 1")
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    { healthy: true, latency_ms: latency_ms }
  rescue StandardError => e
    { healthy: false, error: e.message }
  end

  def check_redis
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    redis.ping
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

    { healthy: true, latency_ms: latency_ms }
  rescue StandardError => e
    { healthy: false, error: e.message }
  ensure
    redis&.close
  end

  def check_sidekiq
    require "sidekiq/api"

    queue = Sidekiq::Queue.new("default")
    latency = queue.latency

    healthy = latency <= SIDEKIQ_LATENCY_THRESHOLD

    {
      healthy: healthy,
      latency_seconds: latency.round(2),
      threshold_seconds: SIDEKIQ_LATENCY_THRESHOLD,
      size: queue.size
    }
  rescue StandardError => e
    { healthy: false, error: e.message }
  end

  def job_summary
    {
      queued: Job.queued.count,
      running: Job.running.count,
      completed: Job.in_state("completed").count,
      failed: Job.in_state("failed").count,
      stalled: Job.in_state("stalled").count
    }
  rescue StandardError
    { error: "Unable to query job counts" }
  end
end
