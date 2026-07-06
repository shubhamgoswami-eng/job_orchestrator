# frozen_string_literal: true

require "rails_helper"

RSpec.describe JobSubmissionService do
  before do
    allow(SchedulerWorker).to receive(:perform_async)
  end

  # ─── Successful Submission ─────────────────────────────────────────

  describe ".call" do
    it "creates a job in queued state" do
      result = described_class.call(
        client_id: "test_client",
        priority: "high",
        workload: "task_001"
      )

      expect(result).to be_success
      expect(result.job.state).to eq("queued")
      expect(result.job.priority).to eq(2)
      expect(result.job.client_id).to eq("test_client")
      expect(result.job.workload).to eq("task_001")
    end

    it "triggers the scheduler after submission" do
      described_class.call(
        client_id: "test_client",
        priority: "medium",
        workload: "task_002"
      )

      expect(SchedulerWorker).to have_received(:perform_async)
    end

    it "persists the job to the database" do
      expect {
        described_class.call(
          client_id: "test_client",
          priority: "low",
          workload: "task_003"
        )
      }.to change(Job, :count).by(1)
    end
  end

  # ─── Validation Errors ─────────────────────────────────────────────

  describe "validation" do
    it "rejects invalid priority values" do
      result = described_class.call(
        client_id: "test_client",
        priority: "urgent",
        workload: "task_004"
      )

      expect(result).to be_failure
      expect(result.errors).to include(a_string_matching(/Invalid priority/))
    end

    it "rejects missing client_id" do
      result = described_class.call(
        client_id: "",
        priority: "high",
        workload: "task_005"
      )

      expect(result).to be_failure
    end

    it "rejects missing workload" do
      result = described_class.call(
        client_id: "test_client",
        priority: "high",
        workload: ""
      )

      expect(result).to be_failure
    end
  end

  # ─── Idempotency Key ──────────────────────────────────────────────

  describe "idempotency" do
    it "returns the existing job if idempotency key matches" do
      first = described_class.call(
        client_id: "test_client",
        priority: "high",
        workload: "task_006",
        idempotency_key: "unique_key_1"
      )

      second = described_class.call(
        client_id: "test_client",
        priority: "high",
        workload: "task_006",
        idempotency_key: "unique_key_1"
      )

      expect(second).to be_success
      expect(second.job.id).to eq(first.job.id)
      expect(Job.count).to eq(1)
    end

    it "creates separate jobs without idempotency key" do
      3.times do
        described_class.call(
          client_id: "test_client",
          priority: "medium",
          workload: "task_007"
        )
      end

      expect(Job.count).to eq(3)
    end
  end
end
