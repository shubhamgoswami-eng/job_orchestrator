# frozen_string_literal: true

# Executes a single job. Dispatched by the Scheduler after
# concurrency slot acquisition and state transition to "running".
#
# This worker is stateless — all state lives in MySQL and Redis.
# If the worker crashes (SIGKILL), the heartbeat will expire and
# the StallMonitorWorker will recover the job.
#
class JobExecutorWorker
  include Sidekiq::Worker

  # No automatic Sidekiq retries — we handle retries at the application
  # level via RetryHandler to respect concurrency quotas.
  sidekiq_options queue: "execution", retry: 0

  def perform(job_id)
    executor = JobExecutor.new
    executor.execute(job_id)
  end
end
