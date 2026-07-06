# frozen_string_literal: true

# Periodic worker that checks for stalled jobs (expired heartbeats).
#
# Runs every 30 seconds via sidekiq-cron. This is the recovery
# mechanism for SIGKILL'd workers and frozen processes.
#
class StallMonitorWorker
  include Sidekiq::Worker

  sidekiq_options queue: "monitor", retry: 0

  def perform
    monitor = HeartbeatMonitor.new
    monitor.check_all
  rescue StandardError => e
    Rails.logger.error("[StallMonitorWorker] Error: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
  end
end
