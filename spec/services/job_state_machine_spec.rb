# frozen_string_literal: true

require "rails_helper"

RSpec.describe JobStateMachine do
  # ─── Valid Transitions ───────────────────────────────────────────────

  describe ".transition!" do
    context "valid transitions" do
      it "transitions queued → running" do
        job = create(:job, :queued)
        result = described_class.transition!(job, :running)

        expect(result).to be_success
        expect(job.reload.state).to eq("running")
        expect(job.started_at).to be_present
      end

      it "transitions running → completed" do
        job = create(:job, :running)
        result = described_class.transition!(job, :completed)

        expect(result).to be_success
        expect(job.reload.state).to eq("completed")
        expect(job.completed_at).to be_present
      end

      it "transitions running → failed" do
        job = create(:job, :running)
        result = described_class.transition!(job, :failed, error_message: "Boom!")

        expect(result).to be_success
        expect(job.reload.state).to eq("failed")
        expect(job.error_message).to eq("Boom!")
      end

      it "transitions running → stalled" do
        job = create(:job, :running)
        result = described_class.transition!(job, :stalled, error_message: "Heartbeat expired")

        expect(result).to be_success
        expect(job.reload.state).to eq("stalled")
      end

      it "transitions failed → queued (retry)" do
        job = create(:job, :failed)
        result = described_class.transition!(job, :queued, retry_count: 1, scheduled_at: 1.minute.from_now)

        expect(result).to be_success
        expect(job.reload.state).to eq("queued")
        expect(job.retry_count).to eq(1)
        expect(job.started_at).to be_nil
        expect(job.completed_at).to be_nil
      end

      it "transitions stalled → queued (recovery)" do
        job = create(:job, :stalled)
        result = described_class.transition!(job, :queued, retry_count: 1)

        expect(result).to be_success
        expect(job.reload.state).to eq("queued")
      end
    end

    # ─── Invalid Transitions ──────────────────────────────────────────

    context "invalid transitions" do
      it "rejects queued → completed" do
        job = create(:job, :queued)
        result = described_class.transition!(job, :completed)

        expect(result).to be_failure
        expect(result.error).to include("Illegal transition")
        expect(job.reload.state).to eq("queued")
      end

      it "rejects queued → failed" do
        job = create(:job, :queued)
        result = described_class.transition!(job, :failed)

        expect(result).to be_failure
      end

      it "rejects completed → anything" do
        job = create(:job, :completed)

        %w[queued running failed stalled].each do |target|
          result = described_class.transition!(job, target)
          expect(result).to be_failure
          expect(job.reload.state).to eq("completed")
        end
      end

      it "rejects running → queued (no direct re-queue, must go through failed/stalled)" do
        job = create(:job, :running)
        result = described_class.transition!(job, :queued)

        expect(result).to be_failure
      end
    end

    # ─── Concurrency Safety ──────────────────────────────────────────

    context "concurrent modification detection" do
      it "rejects transition when lock_version has changed" do
        job = create(:job, :queued)

        # Simulate another process updating the job
        Job.where(id: job.id).update_all(lock_version: job.lock_version + 1)

        result = described_class.transition!(job, :running)

        expect(result).to be_failure
        expect(result.error).to include("Concurrent modification")
      end

      it "rejects transition when state has already changed" do
        job = create(:job, :queued)

        # Simulate another process transitioning the job
        Job.where(id: job.id).update_all(state: "running", lock_version: job.lock_version + 1)

        # Our stale reference still thinks it's queued
        result = described_class.transition!(job, :running)

        expect(result).to be_failure
      end
    end

    # ─── Idempotency ─────────────────────────────────────────────────

    context "idempotency" do
      it "safely handles double-transition attempts" do
        job = create(:job, :queued)

        result1 = described_class.transition!(job, :running)
        expect(result1).to be_success

        # Attempt same transition again with stale job object
        stale_job = Job.find(job.id)
        # But state is now 'running', so queued → running is not applicable
        # It would need to be from 'running' state
        result2 = described_class.transition!(job, :running)
        expect(result2).to be_failure
      end
    end
  end

  # ─── Transition Validation ─────────────────────────────────────────

  describe ".valid_transition?" do
    it "validates all legal transitions" do
      expect(described_class.valid_transition?("queued", "running")).to be true
      expect(described_class.valid_transition?("running", "completed")).to be true
      expect(described_class.valid_transition?("running", "failed")).to be true
      expect(described_class.valid_transition?("running", "stalled")).to be true
      expect(described_class.valid_transition?("failed", "queued")).to be true
      expect(described_class.valid_transition?("stalled", "queued")).to be true
    end

    it "rejects all illegal transitions" do
      expect(described_class.valid_transition?("queued", "completed")).to be false
      expect(described_class.valid_transition?("queued", "failed")).to be false
      expect(described_class.valid_transition?("queued", "stalled")).to be false
      expect(described_class.valid_transition?("completed", "queued")).to be false
      expect(described_class.valid_transition?("running", "queued")).to be false
    end
  end
end
