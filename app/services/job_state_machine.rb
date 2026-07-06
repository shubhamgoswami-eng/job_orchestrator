# frozen_string_literal: true

# Enforces the strict job lifecycle state machine with atomic transitions.
#
# State diagram:
#   queued → running → completed
#                    → failed
#                    → stalled
#
# All transitions use optimistic locking (lock_version) combined with
# a WHERE clause on the current state. This prevents:
#   1. Illegal transitions (e.g., queued → completed)
#   2. Concurrent transitions (two workers transitioning the same job)
#   3. Stale updates (race between stall monitor and job completion)
#
# @example Transitioning a job to running
#   result = JobStateMachine.transition!(job, :running)
#   result.success? # => true
#
class JobStateMachine
  # Maps each state to its set of legal successor states.
  TRANSITIONS = {
    "queued"    => %w[running].freeze,
    "running"   => %w[completed failed stalled].freeze,
    "completed" => [].freeze,
    "failed"    => %w[queued].freeze, # retry: failed → queued
    "stalled"   => %w[queued].freeze  # recovery: stalled → queued
  }.freeze

  Result = Struct.new(:success, :error, keyword_init: true) do
    def success? = success
    def failure? = !success
  end

  class << self
    # Atomically transitions a job to the target state.
    #
    # Uses UPDATE ... WHERE id = ? AND state = ? AND lock_version = ?
    # to guarantee exactly one process can perform the transition.
    #
    # @param job [Job] the job to transition
    # @param target_state [String, Symbol] the desired state
    # @param attrs [Hash] additional attributes to set (e.g., error_message)
    # @return [Result] success or failure with error message
    def transition!(job, target_state, **attrs)
      target_state = target_state.to_s

      unless valid_transition?(job.state, target_state)
        return Result.new(
          success: false,
          error: "Illegal transition: #{job.state} → #{target_state}"
        )
      end

      timestamp_attrs = timestamp_for(target_state)
      update_attrs = attrs.merge(state: target_state).merge(timestamp_attrs)

      # Atomic update with optimistic locking.
      # The WHERE clause ensures:
      #   1. The job is still in the expected state (no concurrent transition)
      #   2. The lock_version hasn't changed (no stale update)
      rows_updated = Job.where(
        id: job.id,
        state: job.state,
        lock_version: job.lock_version
      ).update_all(
        update_attrs.merge(lock_version: job.lock_version + 1, updated_at: Time.current)
      )

      if rows_updated == 1
        job.reload
        Result.new(success: true, error: nil)
      else
        Result.new(
          success: false,
          error: "Concurrent modification detected for Job##{job.id}. " \
                 "Expected state=#{job.state}, lock_version=#{job.lock_version}."
        )
      end
    rescue ActiveRecord::RecordNotFound => e
      Result.new(success: false, error: "Job not found: #{e.message}")
    end

    # Checks whether a state transition is legal.
    #
    # @param from_state [String]
    # @param to_state [String]
    # @return [Boolean]
    def valid_transition?(from_state, to_state)
      TRANSITIONS.fetch(from_state.to_s, []).include?(to_state.to_s)
    end

    private

    # Returns timestamp attributes appropriate for the target state.
    def timestamp_for(target_state)
      case target_state
      when "running"
        { started_at: Time.current }
      when "completed", "failed", "stalled"
        { completed_at: Time.current }
      when "queued"
        # Reset timestamps for retry
        { started_at: nil, completed_at: nil }
      else
        {}
      end
    end
  end
end
