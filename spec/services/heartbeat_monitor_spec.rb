# frozen_string_literal: true

require "rails_helper"
require "mock_redis"

RSpec.describe HeartbeatMonitor do
  let(:redis) { mock_redis }
  let(:concurrency_guard) { ConcurrencyGuard.new(redis: redis) }
  let(:monitor) { described_class.new(redis: redis, concurrency_guard: concurrency_guard) }

  before do
    allow(RetryHandler).to receive(:schedule_retry)
  end

  # ─── Stall Detection ───────────────────────────────────────────────

  describe "#check_all" do
    it "stalls running jobs with expired heartbeats" do
      job = create(:job, :running)

      # No heartbeat in Redis → expired
      stalled_count = monitor.check_all

      expect(stalled_count).to eq(1)
      expect(job.reload.state).to eq("stalled")
      expect(job.error_message).to include("Heartbeat expired")
    end

    it "does not stall jobs with active heartbeats" do
      job = create(:job, :running)

      # Simulate active heartbeat
      redis.set("heartbeat:#{job.id}", Time.current.to_f.to_s, ex: 60)

      stalled_count = monitor.check_all

      expect(stalled_count).to eq(0)
      expect(job.reload.state).to eq("running")
    end

    it "releases concurrency slots for stalled jobs" do
      job = create(:job, :running)
      create(:client_quota, client_id: job.client_id, concurrency_limit: 5)
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      monitor.check_all

      expect(concurrency_guard.running_count(client_id: job.client_id)).to eq(0)
    end

    it "triggers retry for stalled jobs with retries remaining" do
      job = create(:job, :running, retry_count: 0, max_retries: 3)

      monitor.check_all

      expect(RetryHandler).to have_received(:schedule_retry)
    end

    it "does not trigger retry for jobs with exhausted retries" do
      job = create(:job, :running, retry_count: 5, max_retries: 5)

      monitor.check_all

      expect(RetryHandler).not_to have_received(:schedule_retry)
    end
  end

  # ─── Split-Brain Safety ────────────────────────────────────────────

  describe "split-brain safety" do
    it "handles concurrent stall attempts safely" do
      job = create(:job, :running)

      # First monitor stalls the job
      first_result = monitor.check_all
      expect(first_result).to eq(1)

      # Second monitor tries to stall the same job — should fail safely
      # because job is already in 'stalled' state
      second_result = monitor.check_all
      expect(second_result).to eq(0)
    end
  end

  # ─── Redis Failure Handling ────────────────────────────────────────

  describe "Redis failure handling" do
    it "does not stall jobs when Redis is unreachable" do
      broken_redis = instance_double(Redis)
      allow(broken_redis).to receive(:exists?).and_raise(Redis::CannotConnectError)

      broken_monitor = described_class.new(redis: broken_redis, concurrency_guard: concurrency_guard)

      job = create(:job, :running)
      stalled_count = broken_monitor.check_all

      # Should not stall — can't distinguish worker crash from Redis crash
      expect(stalled_count).to eq(0)
      expect(job.reload.state).to eq("running")
    end
  end
end
