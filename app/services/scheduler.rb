# frozen_string_literal: true

# Implements Deficit Round Robin (DRR) scheduling with priority weighting.
#
# The scheduler is the single decision-maker for what jobs run next.
# It solves two competing goals:
#   1. Priority — high-priority jobs should run before low-priority ones
#   2. Fairness — no single client should starve others
#
# Algorithm: Deficit Round Robin
# ─────────────────────────────────
# - Each client gets a "deficit counter" that accumulates credits each round.
# - Credits per round are proportional to the highest-priority queued job:
#     high = 3, medium = 2, low = 1
# - Each scheduling round, we iterate through clients with queued jobs.
# - A client can "spend" credits to dequeue jobs (1 credit per job).
# - Unspent credits carry over to the next round (capped to prevent runaway).
# - This ensures high-priority clients get more throughput while
#   guaranteeing every client gets at least 1 slot per N rounds.
#
# The scheduler also handles:
#   - Concurrency slot acquisition via ConcurrencyGuard
#   - State transition to "running" via JobStateMachine
#   - Dispatching to JobExecutorWorker
#
class Scheduler
  # Priority weights: how many credits each priority level earns per round
  PRIORITY_WEIGHTS = { 2 => 3, 1 => 2, 0 => 1 }.freeze
  MAX_DEFICIT = 10 # Cap deficit to prevent unbounded accumulation

  # Maximum jobs to dispatch per scheduler invocation (prevents thundering herd)
  MAX_DISPATCH_PER_CYCLE = 50

  def initialize(concurrency_guard: ConcurrencyGuard.new)
    @concurrency_guard = concurrency_guard
    @deficits = Hash.new(0) # client_id → accumulated deficit credits
  end

  # Runs one scheduling cycle: picks jobs across clients using DRR
  # and dispatches them to executors.
  #
  # @return [Integer] number of jobs dispatched
  def run
    dispatched = 0

    # Find all clients with schedulable jobs
    client_ids = Job.schedulable.distinct.pluck(:client_id)
    return 0 if client_ids.empty?

    # Add credits to each client based on their highest-priority queued job
    client_ids.each do |client_id|
      highest_priority = Job.schedulable.for_client(client_id).maximum(:priority) || 0
      weight = PRIORITY_WEIGHTS.fetch(highest_priority, 1)
      @deficits[client_id] = [ @deficits[client_id] + weight, MAX_DEFICIT ].min
    end

    # Round-robin through clients, spending credits
    # Sort by deficit descending so clients with more accumulated credits go first
    sorted_clients = client_ids.sort_by { |cid| -@deficits[cid] }

    sorted_clients.each do |client_id|
      break if dispatched >= MAX_DISPATCH_PER_CYCLE

      while @deficits[client_id] > 0 && dispatched < MAX_DISPATCH_PER_CYCLE
        job = pick_next_job(client_id)
        break unless job

        if dispatch_job(job)
          dispatched += 1
          @deficits[client_id] -= 1
        else
          # Quota full for this client — move on, keep credits for next round
          break
        end
      end
    end

    # Clean up deficits for clients with no queued jobs
    @deficits.delete_if { |cid, _| !client_ids.include?(cid) }

    Rails.logger.info("[Scheduler] Dispatched #{dispatched} jobs") if dispatched > 0
    dispatched
  end

  private

  # Selects the next best job for a client (highest priority, oldest first).
  #
  # @param client_id [String]
  # @return [Job, nil]
  def pick_next_job(client_id)
    Job.schedulable
       .for_client(client_id)
       .by_scheduling_order
       .first
  end

  # Attempts to dispatch a single job: acquire slot → transition → enqueue executor.
  #
  # @param job [Job]
  # @return [Boolean] true if dispatched
  def dispatch_job(job)
    # Step 1: Acquire concurrency slot
    unless @concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)
      Rails.logger.debug("[Scheduler] Quota full for client #{job.client_id}, skipping Job##{job.id}")
      return false
    end

    # Step 2: Atomic transition to running
    result = JobStateMachine.transition!(job, :running)

    unless result.success?
      # Transition failed (job was picked up by another scheduler instance)
      # Release the slot we just acquired
      @concurrency_guard.release(client_id: job.client_id, job_id: job.id)
      Rails.logger.warn("[Scheduler] Failed to transition Job##{job.id}: #{result.error}")
      return false
    end

    # Step 3: Dispatch to executor
    JobExecutorWorker.perform_async(job.id)
    Rails.logger.info("[Scheduler] Dispatched Job##{job.id} (client=#{job.client_id}, priority=#{job.priority_label})")
    true
  rescue StandardError => e
    # If anything goes wrong after slot acquisition, release the slot
    @concurrency_guard.release(client_id: job.client_id, job_id: job.id)
    Rails.logger.error("[Scheduler] Error dispatching Job##{job.id}: #{e.message}")
    false
  end
end
