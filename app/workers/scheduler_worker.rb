# frozen_string_literal: true

# Periodic worker that runs the scheduler to dispatch queued jobs.
#
# Runs every 5 seconds via sidekiq-cron. Also triggered on-demand
# when a new job is submitted for lower latency.
#
# Thread safety: The scheduler instance is per-invocation, so
# deficit counters reset each cycle. For true DRR, we could
# persist deficits in Redis, but per-cycle reset is acceptable
# given the 5-second frequency — it still prevents starvation
# within each cycle.
#
class SchedulerWorker
  include Sidekiq::Worker

  sidekiq_options queue: "scheduler", retry: 0, lock: :until_executed

  def perform
    scheduler = Scheduler.new
    scheduler.run
  rescue StandardError => e
    Rails.logger.error("[SchedulerWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
  end
end
