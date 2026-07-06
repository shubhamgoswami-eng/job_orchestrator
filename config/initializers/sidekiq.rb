# frozen_string_literal: true

Sidekiq.configure_server do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }

  # Register periodic cron jobs
  config.on(:startup) do
    schedule = {
      "scheduler_worker" => {
        "cron" => "*/5 * * * * *", # Every 5 seconds (using 6-field cron for seconds)
        "class" => "SchedulerWorker",
        "queue" => "scheduler",
        "description" => "Runs the job scheduler to dispatch queued jobs"
      },
      "stall_monitor_worker" => {
        "cron" => "*/30 * * * * *", # Every 30 seconds
        "class" => "StallMonitorWorker",
        "queue" => "monitor",
        "description" => "Checks for stalled jobs with expired heartbeats"
      }
    }

    Sidekiq::Cron::Job.load_from_hash!(schedule)
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0") }
end
