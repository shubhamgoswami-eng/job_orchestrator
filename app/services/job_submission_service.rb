# frozen_string_literal: true

# Handles job submission: validates input, persists the job, and triggers scheduling.
#
# This is the entry point for the POST /jobs API. It ensures:
#   1. Input validation with clear error messages
#   2. Idempotency key support (optional)
#   3. Immediate persistence in "queued" state
#   4. Asynchronous scheduling trigger via SchedulerWorker
#
class JobSubmissionService
  Result = Struct.new(:success, :job, :errors, keyword_init: true) do
    def success? = success
    def failure? = !success
  end

  # Submits a new job for asynchronous execution.
  #
  # @param client_id [String]
  # @param priority [String] "low", "medium", or "high"
  # @param workload [String] simulated task identifier
  # @param idempotency_key [String, nil] optional idempotency key
  # @return [Result]
  def self.call(client_id:, priority:, workload:, idempotency_key: nil)
    new.call(
      client_id: client_id,
      priority: priority,
      workload: workload,
      idempotency_key: idempotency_key
    )
  end

  def call(client_id:, priority:, workload:, idempotency_key: nil)
    # Validate and convert priority
    priority_value = begin
      Job.priority_from_label(priority)
    rescue ArgumentError => e
      return Result.new(success: false, job: nil, errors: [ e.message ])
    end

    # Handle idempotency: if a job with this key already exists, return it
    if idempotency_key.present?
      existing = Job.find_by(idempotency_key: idempotency_key)
      if existing
        return Result.new(success: true, job: existing, errors: [])
      end
    end

    # Create the job
    job = Job.new(
      client_id: client_id,
      priority: priority_value,
      workload: workload,
      state: "queued",
      scheduled_at: Time.current,
      idempotency_key: idempotency_key.presence
    )

    if job.save
      # Trigger the scheduler to pick up this job asynchronously.
      # The scheduler runs periodically, but we also kick it on submission
      # for lower latency.
      SchedulerWorker.perform_async
      Result.new(success: true, job: job, errors: [])
    else
      Result.new(success: false, job: nil, errors: job.errors.full_messages)
    end
  rescue ActiveRecord::RecordNotUnique
    # Race condition: two submissions with the same idempotency_key
    existing = Job.find_by(idempotency_key: idempotency_key)
    if existing
      Result.new(success: true, job: existing, errors: [])
    else
      Result.new(success: false, job: nil, errors: [ "Duplicate submission detected" ])
    end
  end
end
