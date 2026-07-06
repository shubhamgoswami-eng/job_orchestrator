# frozen_string_literal: true

require "rails_helper"
require "mock_redis"

RSpec.describe ConcurrencyGuard do
  let(:redis) { mock_redis }
  let(:guard) { described_class.new(redis: redis) }
  let(:client_id) { "test_client" }

  before do
    # Set up a default quota
    create(:client_quota, client_id: client_id, concurrency_limit: 3)
  end

  # ─── Slot Acquisition ─────────────────────────────────────────────

  describe "#acquire" do
    it "acquires a slot when quota is available" do
      expect(guard.acquire(client_id: client_id, job_id: 1)).to be true
    end

    it "tracks the job in the sorted set" do
      guard.acquire(client_id: client_id, job_id: 1)
      expect(guard.running_count(client_id: client_id)).to eq(1)
    end

    it "allows up to the concurrency limit" do
      expect(guard.acquire(client_id: client_id, job_id: 1)).to be true
      expect(guard.acquire(client_id: client_id, job_id: 2)).to be true
      expect(guard.acquire(client_id: client_id, job_id: 3)).to be true
    end

    it "rejects when quota is full" do
      3.times { |i| guard.acquire(client_id: client_id, job_id: i + 1) }
      expect(guard.acquire(client_id: client_id, job_id: 4)).to be false
    end

    it "uses default limit when no quota record exists" do
      unknown_client = "unknown_client"
      # Default limit is 5 (from ClientQuota::DEFAULT_CONCURRENCY_LIMIT)
      5.times { |i| guard.acquire(client_id: unknown_client, job_id: i + 1) }
      expect(guard.acquire(client_id: unknown_client, job_id: 6)).to be false
    end
  end

  # ─── Slot Release ──────────────────────────────────────────────────

  describe "#release" do
    it "releases a slot" do
      guard.acquire(client_id: client_id, job_id: 1)
      expect(guard.release(client_id: client_id, job_id: 1)).to be true
      expect(guard.running_count(client_id: client_id)).to eq(0)
    end

    it "is idempotent — releasing a non-existent slot returns false" do
      expect(guard.release(client_id: client_id, job_id: 999)).to be false
    end

    it "frees up space for new acquisitions" do
      3.times { |i| guard.acquire(client_id: client_id, job_id: i + 1) }
      guard.release(client_id: client_id, job_id: 1)
      expect(guard.acquire(client_id: client_id, job_id: 4)).to be true
    end
  end

  # ─── Dynamic Quota Changes ────────────────────────────────────────

  describe "dynamic quota updates" do
    it "respects lowered quota immediately for new acquisitions" do
      # Start with limit 3, acquire 2 slots
      guard.acquire(client_id: client_id, job_id: 1)
      guard.acquire(client_id: client_id, job_id: 2)

      # Lower the quota to 2
      ClientQuota.find_by(client_id: client_id).update!(concurrency_limit: 2)

      # New acquisition should fail (2 running == limit of 2)
      expect(guard.acquire(client_id: client_id, job_id: 3)).to be false
    end

    it "allows acquisitions after quota is raised" do
      # Fill up with limit 3
      3.times { |i| guard.acquire(client_id: client_id, job_id: i + 1) }

      # Raise the quota to 5
      ClientQuota.find_by(client_id: client_id).update!(concurrency_limit: 5)

      # New acquisitions should succeed
      expect(guard.acquire(client_id: client_id, job_id: 4)).to be true
      expect(guard.acquire(client_id: client_id, job_id: 5)).to be true
    end
  end

  # ─── Running Jobs Enumeration ──────────────────────────────────────

  describe "#running_jobs" do
    it "returns the list of running job IDs" do
      guard.acquire(client_id: client_id, job_id: 10)
      guard.acquire(client_id: client_id, job_id: 20)

      jobs = guard.running_jobs(client_id: client_id)
      expect(jobs).to contain_exactly("10", "20")
    end
  end

  # ─── Error Handling ────────────────────────────────────────────────

  describe "Redis failure handling" do
    it "fails closed on acquire when Redis is down" do
      broken_redis = instance_double(Redis)
      allow(broken_redis).to receive(:eval).and_raise(Redis::CannotConnectError)

      broken_guard = described_class.new(redis: broken_redis)
      expect(broken_guard.acquire(client_id: client_id, job_id: 1)).to be false
    end

    it "handles release failure gracefully" do
      broken_redis = instance_double(Redis)
      allow(broken_redis).to receive(:zrem).and_raise(Redis::CannotConnectError)

      broken_guard = described_class.new(redis: broken_redis)
      expect(broken_guard.release(client_id: client_id, job_id: 1)).to be false
    end
  end

  # ─── Isolation Between Clients ─────────────────────────────────────

  describe "client isolation" do
    it "tracks slots independently per client" do
      other_client = "other_client"
      create(:client_quota, client_id: other_client, concurrency_limit: 2)

      # Fill client_id quota
      3.times { |i| guard.acquire(client_id: client_id, job_id: i + 1) }

      # other_client should still be able to acquire
      expect(guard.acquire(client_id: other_client, job_id: 100)).to be true
    end
  end
end
