# frozen_string_literal: true

# Detects stalled jobs by checking for expired heartbeats in Redis.
#
# A job is considered stalled when:
#   1. It is in the "running" state in the database
#   2. Its heartbeat key has expired in Redis (TTL elapsed, meaning no pulse
#      was received within the HEARTBEAT_TTL window of 60 seconds)
#
# The monitor handles the SIGKILL recovery scenario:
#   - A worker is SIGKILL'd mid-execution
#   - The heartbeat thread dies
#   - The heartbeat Redis key expires after 60s
#   - This monitor detects the expiry and transitions to "stalled"
#   - The concurrency slot is released
#   - RetryHandler re-queues if retries remain
#
# Split-brain protection:
#   - Two monitors might try to stall the same job simultaneously.
#   - JobStateMachine's atomic transition (WHERE state='running') ensures
#     only one succeeds. The loser gets a "concurrent modification" error
#     and moves on safely.
#
class HeartbeatMonitor
  HEARTBEAT_KEY_PREFIX = "heartbeat"

  def initialize(redis: nil, concurrency_guard: ConcurrencyGuard.new)
    @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    @concurrency_guard = concurrency_guard
  end

  # Scans all running jobs and stalls any with expired heartbeats.
  #
  # @return [Integer] number of jobs stalled
  def check_all
    stalled_count = 0

    Job.running.find_each(batch_size: 100) do |job|
      if heartbeat_expired?(job.id)
        if stall_job(job)
          stalled_count += 1
        end
      end
    end

    Rails.logger.info("[HeartbeatMonitor] Stalled #{stalled_count} jobs") if stalled_count > 0
    stalled_count
  end

  private

  # Checks whether a job's heartbeat has expired.
  #
  # A missing key means the heartbeat TTL elapsed (worker crashed or frozen).
  # We also handle the case where Redis itself was restarted — in that case,
  # ALL heartbeat keys are gone, so we use a grace period based on started_at.
  #
  # @param job_id [Integer]
  # @return [Boolean]
  def heartbeat_expired?(job_id)
    key = "#{HEARTBEAT_KEY_PREFIX}:#{job_id}"
    !@redis.exists?(key)
  rescue Redis::BaseError => e
    # If Redis is down, don't stall jobs — we can't distinguish between
    # "worker crashed" and "Redis crashed". Err on the side of caution.
    Rails.logger.error("[HeartbeatMonitor] Redis error checking Job##{job_id}: #{e.message}")
    false
  end

  # Transitions a job to stalled, releases its concurrency slot, and
  # schedules a retry if applicable.
  #
  # @param job [Job]
  # @return [Boolean] true if stalling succeeded
  def stall_job(job)
    result = JobStateMachine.transition!(job, :stalled, error_message: "Heartbeat expired — worker presumed dead")

    unless result.success?
      # Another process already handled this job (split-brain safe)
      Rails.logger.debug("[HeartbeatMonitor] Job##{job.id} already transitioned: #{result.error}")
      return false
    end

    # Release the concurrency slot
    @concurrency_guard.release(client_id: job.client_id, job_id: job.id)

    Rails.logger.warn("[HeartbeatMonitor] Job##{job.id} stalled (client=#{job.client_id})")

    # Schedule retry if applicable
    job.reload
    RetryHandler.schedule_retry(job) if job.retry_count < job.max_retries

    true
  end
end
