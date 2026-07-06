# frozen_string_literal: true

# Executes a job's workload and manages its lifecycle during execution.
#
# Responsibilities:
#   1. Verify the job is still in "running" state (idempotency guard)
#   2. Start a heartbeat thread that pulses to Redis every 20 seconds
#   3. Execute the simulated workload
#   4. Transition to "completed" or "failed"
#   5. Release the concurrency slot
#   6. Stop the heartbeat thread
#
# The heartbeat runs in a separate thread to ensure it continues even
# during CPU-intensive workload execution.
#
class JobExecutor
  HEARTBEAT_INTERVAL = 20 # seconds
  HEARTBEAT_TTL = 60      # seconds — stall detection threshold
  HEARTBEAT_KEY_PREFIX = "heartbeat"

  def initialize(redis: nil, concurrency_guard: ConcurrencyGuard.new)
    @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
    @concurrency_guard = concurrency_guard
  end

  # Executes a job by ID.
  #
  # @param job_id [Integer]
  # @return [void]
  def execute(job_id)
    job = Job.find_by(id: job_id)

    unless job
      Rails.logger.error("[JobExecutor] Job##{job_id} not found")
      return
    end

    # Idempotency guard: only execute if still in running state
    unless job.state == "running"
      Rails.logger.warn("[JobExecutor] Job##{job_id} is in '#{job.state}' state, skipping execution")
      return
    end

    heartbeat_thread = start_heartbeat(job_id)

    begin
      perform_workload(job)
      complete_job(job)
    rescue StandardError => e
      fail_job(job, e)
    ensure
      stop_heartbeat(heartbeat_thread)
      clear_heartbeat(job_id)
      @concurrency_guard.release(client_id: job.client_id, job_id: job.id)
    end
  end

  private

  # Simulates workload execution.
  # In production, this would dispatch to the actual task handler.
  def perform_workload(job)
    Rails.logger.info("[JobExecutor] Executing workload '#{job.workload}' for Job##{job.id}")

    # Simulate varying workload durations based on the workload identifier
    duration = simulate_duration(job.workload)
    sleep(duration)

    Rails.logger.info("[JobExecutor] Workload '#{job.workload}' completed for Job##{job.id}")
  end

  # Determines simulated duration based on workload ID.
  # Allows testing with predictable durations.
  def simulate_duration(workload)
    case workload
    when /^fast_/     then 1
    when /^slow_/     then 10
    when /^fail_/     then raise StandardError, "Simulated failure for workload: #{workload}"
    when /^instant_/  then 0
    else
      # Default: random 2-5 seconds
      rand(2.0..5.0)
    end
  end

  def complete_job(job)
    job.reload # Refresh to get current lock_version
    result = JobStateMachine.transition!(job, :completed)

    if result.success?
      Rails.logger.info("[JobExecutor] Job##{job.id} completed successfully")
    else
      # Job was stalled by the monitor while we were completing — that's OK
      Rails.logger.warn("[JobExecutor] Could not complete Job##{job.id}: #{result.error}")
    end
  end

  def fail_job(job, error)
    job.reload
    result = JobStateMachine.transition!(job, :failed, error_message: error.message)

    if result.success?
      Rails.logger.warn("[JobExecutor] Job##{job.id} failed: #{error.message}")
      # Schedule retry if applicable
      RetryHandler.schedule_retry(job) if job.reload.retriable?
    else
      Rails.logger.error("[JobExecutor] Could not transition Job##{job.id} to failed: #{result.error}")
    end
  end

  # Starts a background thread that writes heartbeats to Redis.
  #
  # @param job_id [Integer]
  # @return [Thread]
  def start_heartbeat(job_id)
    # Write initial heartbeat immediately
    pulse_heartbeat(job_id)

    Thread.new do
      loop do
        sleep(HEARTBEAT_INTERVAL)
        pulse_heartbeat(job_id)
      rescue StandardError => e
        Rails.logger.error("[Heartbeat] Error pulsing for Job##{job_id}: #{e.message}")
      end
    end
  end

  def stop_heartbeat(thread)
    return unless thread&.alive?

    thread.kill
    thread.join(5) # Wait up to 5 seconds for clean shutdown
  end

  # Writes a heartbeat to Redis with TTL.
  #
  # @param job_id [Integer]
  def pulse_heartbeat(job_id)
    key = heartbeat_key(job_id)
    @redis.set(key, Time.current.to_f.to_s, ex: HEARTBEAT_TTL)
  rescue Redis::BaseError => e
    Rails.logger.error("[Heartbeat] Redis error for Job##{job_id}: #{e.message}")
  end

  def clear_heartbeat(job_id)
    @redis.del(heartbeat_key(job_id))
  rescue Redis::BaseError
    # Best effort cleanup
  end

  def heartbeat_key(job_id)
    "#{HEARTBEAT_KEY_PREFIX}:#{job_id}"
  end
end
