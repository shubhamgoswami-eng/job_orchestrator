# frozen_string_literal: true

# Handles retry logic with exponential backoff for failed and stalled jobs.
#
# Retry strategy:
#   - Exponential backoff: delay = BASE_DELAY * 2^retry_count
#   - Jitter: ±25% random jitter to prevent thundering herd on retries
#   - Max retries: configurable per job (default 5)
#   - Re-enters the queue: retries go through the normal scheduling pipeline,
#     meaning they respect concurrency quotas and fairness rules.
#
# Idempotency:
#   - The retry handler is safe to call multiple times for the same job.
#   - The state machine transition (failed/stalled → queued) uses optimistic
#     locking, so duplicate calls will fail harmlessly.
#
class RetryHandler
  BASE_DELAY = 5 # seconds
  MAX_DELAY = 300 # 5 minutes cap
  JITTER_FACTOR = 0.25

  class << self
    # Schedules a retry for a failed or stalled job.
    #
    # Transitions the job back to "queued" with an incremented retry_count
    # and a scheduled_at timestamp in the future (exponential backoff).
    #
    # @param job [Job] the job to retry (must be in failed or stalled state)
    # @return [Boolean] true if retry was scheduled
    def schedule_retry(job)
      job.reload

      unless %w[failed stalled].include?(job.state)
        Rails.logger.warn("[RetryHandler] Job##{job.id} is in '#{job.state}' state, cannot retry")
        return false
      end

      if job.retry_count >= job.max_retries
        Rails.logger.info("[RetryHandler] Job##{job.id} has exhausted retries (#{job.retry_count}/#{job.max_retries})")
        return false
      end

      delay = calculate_delay(job.retry_count)
      next_attempt_at = Time.current + delay

      result = JobStateMachine.transition!(
        job,
        :queued,
        retry_count: job.retry_count + 1,
        scheduled_at: next_attempt_at,
        error_message: nil
      )

      if result.success?
        Rails.logger.info(
          "[RetryHandler] Job##{job.id} scheduled for retry ##{job.retry_count} " \
          "at #{next_attempt_at} (delay=#{delay.round(1)}s)"
        )
        true
      else
        Rails.logger.warn("[RetryHandler] Failed to schedule retry for Job##{job.id}: #{result.error}")
        false
      end
    end

    # Calculates the backoff delay for a given retry attempt.
    #
    # @param retry_count [Integer] current retry count (0-based)
    # @return [Float] delay in seconds
    def calculate_delay(retry_count)
      base = [ BASE_DELAY * (2**retry_count), MAX_DELAY ].min
      jitter = base * JITTER_FACTOR * (rand * 2 - 1) # ±25%
      [ base + jitter, 1.0 ].max # Minimum 1 second
    end
  end
end
