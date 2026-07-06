# frozen_string_literal: true

require "rails_helper"
require "mock_redis"

RSpec.describe JobExecutor do
  let(:redis) { mock_redis }
  let(:concurrency_guard) { ConcurrencyGuard.new(redis: redis) }
  let(:executor) { described_class.new(redis: redis, concurrency_guard: concurrency_guard) }

  before do
    allow(RetryHandler).to receive(:schedule_retry)
  end

  # ─── Successful Execution ──────────────────────────────────────────

  describe "successful execution" do
    it "transitions to completed after workload execution" do
      job = create(:job, :running, workload: "instant_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(job.reload.state).to eq("completed")
      expect(job.completed_at).to be_present
    end

    it "releases the concurrency slot on completion" do
      job = create(:job, :running, workload: "instant_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(concurrency_guard.running_count(client_id: job.client_id)).to eq(0)
    end

    it "clears the heartbeat on completion" do
      job = create(:job, :running, workload: "instant_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(redis.exists?("heartbeat:#{job.id}")).to be false
    end
  end

  # ─── Failed Execution ──────────────────────────────────────────────

  describe "failed execution" do
    it "transitions to failed on workload error" do
      job = create(:job, :running, workload: "fail_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(job.reload.state).to eq("failed")
      expect(job.error_message).to include("Simulated failure")
    end

    it "releases the concurrency slot on failure" do
      job = create(:job, :running, workload: "fail_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(concurrency_guard.running_count(client_id: job.client_id)).to eq(0)
    end

    it "triggers retry for retriable jobs" do
      job = create(:job, :running, workload: "fail_test", retry_count: 0, max_retries: 3)
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      executor.execute(job.id)

      expect(RetryHandler).to have_received(:schedule_retry)
    end
  end

  # ─── Idempotency Guard ─────────────────────────────────────────────

  describe "idempotency" do
    it "skips execution if job is not in running state" do
      job = create(:job, :completed, workload: "instant_test")

      executor.execute(job.id)

      # Should remain completed, not re-executed
      expect(job.reload.state).to eq("completed")
    end

    it "handles non-existent job gracefully" do
      expect { executor.execute(99999) }.not_to raise_error
    end
  end

  # ─── Heartbeat ─────────────────────────────────────────────────────

  describe "heartbeat" do
    it "writes an initial heartbeat when starting execution" do
      job = create(:job, :running, workload: "instant_test")
      concurrency_guard.acquire(client_id: job.client_id, job_id: job.id)

      # The heartbeat is written and then cleared, but during execution
      # it should exist. We verify the mechanism works by checking
      # the heartbeat key was set at some point.
      allow(redis).to receive(:set).and_call_original
      allow(redis).to receive(:del).and_call_original

      executor.execute(job.id)

      expect(redis).to have_received(:set).with(
        "heartbeat:#{job.id}",
        anything,
        ex: JobExecutor::HEARTBEAT_TTL
      ).at_least(:once)
    end
  end
end
