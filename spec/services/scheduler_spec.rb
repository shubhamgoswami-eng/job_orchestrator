# frozen_string_literal: true

require "rails_helper"
require "mock_redis"

RSpec.describe Scheduler do
  let(:redis) { mock_redis }
  let(:concurrency_guard) { ConcurrencyGuard.new(redis: redis) }
  let(:scheduler) { described_class.new(concurrency_guard: concurrency_guard) }

  before do
    # Stub Sidekiq workers to prevent actual enqueuing
    allow(JobExecutorWorker).to receive(:perform_async)
  end

  # ─── Priority Ordering ──────────────────────────────────────────────

  describe "priority ordering" do
    let(:client_id) { "priority_client" }

    before do
      create(:client_quota, client_id: client_id, concurrency_limit: 10)
    end

    it "dispatches high-priority jobs before low-priority ones" do
      low = create(:job, client_id: client_id, priority: 0, scheduled_at: 1.minute.ago)
      high = create(:job, client_id: client_id, priority: 2, scheduled_at: Time.current)

      scheduler.run

      # Both should be dispatched, but high first
      expect(high.reload.state).to eq("running")
      expect(low.reload.state).to eq("running")
      expect(high.started_at).to be <= low.started_at
    end
  end

  # ─── Fairness (Anti-Starvation) ────────────────────────────────────

  describe "fairness across clients" do
    it "serves multiple clients, not just the one with most jobs" do
      client_a = "client_a"
      client_b = "client_b"
      create(:client_quota, client_id: client_a, concurrency_limit: 10)
      create(:client_quota, client_id: client_b, concurrency_limit: 10)

      # Client A floods the queue with 20 low-priority jobs
      20.times { create(:job, client_id: client_a, priority: 0, scheduled_at: 1.minute.ago) }

      # Client B has just 2 medium-priority jobs
      2.times { create(:job, client_id: client_b, priority: 1, scheduled_at: 1.minute.ago) }

      scheduler.run

      # Client B's jobs should be dispatched (not starved by Client A)
      b_running = Job.for_client(client_b).running.count
      expect(b_running).to eq(2), "Client B should not be starved — expected 2 running, got #{b_running}"
    end
  end

  # ─── Concurrency Quota Enforcement ─────────────────────────────────

  describe "concurrency quota enforcement" do
    it "does not dispatch more jobs than the client's quota allows" do
      client_id = "limited_client"
      create(:client_quota, client_id: client_id, concurrency_limit: 2)

      5.times { create(:job, client_id: client_id, scheduled_at: 1.minute.ago) }

      scheduler.run

      running = Job.for_client(client_id).running.count
      expect(running).to eq(2)
    end
  end

  # ─── Scheduled At Respect ──────────────────────────────────────────

  describe "scheduled_at filtering" do
    it "does not dispatch jobs scheduled in the future" do
      client_id = "future_client"
      create(:client_quota, client_id: client_id, concurrency_limit: 10)

      create(:job, client_id: client_id, scheduled_at: 1.hour.from_now)
      ready = create(:job, client_id: client_id, scheduled_at: 1.minute.ago)

      scheduler.run

      expect(ready.reload.state).to eq("running")
      expect(Job.queued.count).to eq(1) # future job still queued
    end
  end

  # ─── Dispatch Count Limiting ───────────────────────────────────────

  describe "dispatch limiting" do
    it "returns the number of dispatched jobs" do
      client_id = "counting_client"
      create(:client_quota, client_id: client_id, concurrency_limit: 10)

      3.times { create(:job, client_id: client_id, priority: 2, scheduled_at: 1.minute.ago) }

      dispatched = scheduler.run
      expect(dispatched).to eq(3)
    end

    it "returns 0 when no jobs are schedulable" do
      expect(scheduler.run).to eq(0)
    end
  end

  # ─── State Transition Failures ─────────────────────────────────────

  describe "state transition failure handling" do
    it "releases the concurrency slot when transition fails" do
      client_id = "transition_fail_client"
      create(:client_quota, client_id: client_id, concurrency_limit: 5)

      job = create(:job, client_id: client_id, scheduled_at: 1.minute.ago)

      # Simulate the job being picked up by another scheduler instance
      allow(JobStateMachine).to receive(:transition!).and_return(
        JobStateMachine::Result.new(success: false, error: "Concurrent modification")
      )

      scheduler.run

      # The slot should have been released
      expect(concurrency_guard.running_count(client_id: client_id)).to eq(0)
    end
  end
end
