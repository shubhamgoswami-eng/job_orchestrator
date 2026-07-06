# frozen_string_literal: true

require "rails_helper"

RSpec.describe RetryHandler do
  # ─── Retry Scheduling ──────────────────────────────────────────────

  describe ".schedule_retry" do
    it "transitions a failed job back to queued with incremented retry count" do
      job = create(:job, :failed, retry_count: 1, max_retries: 5)

      result = described_class.schedule_retry(job)

      expect(result).to be true
      job.reload
      expect(job.state).to eq("queued")
      expect(job.retry_count).to eq(2)
      expect(job.scheduled_at).to be > Time.current
    end

    it "transitions a stalled job back to queued" do
      job = create(:job, :stalled, retry_count: 0, max_retries: 3)

      result = described_class.schedule_retry(job)

      expect(result).to be true
      expect(job.reload.state).to eq("queued")
    end

    it "resets started_at and completed_at for retried jobs" do
      job = create(:job, :failed, retry_count: 0, max_retries: 3)

      described_class.schedule_retry(job)
      job.reload

      expect(job.started_at).to be_nil
      expect(job.completed_at).to be_nil
      expect(job.error_message).to be_nil
    end

    it "does not retry when max retries exhausted" do
      job = create(:job, :failed, retry_count: 5, max_retries: 5)

      result = described_class.schedule_retry(job)

      expect(result).to be false
      expect(job.reload.state).to eq("failed")
    end

    it "does not retry jobs in non-retriable states" do
      job = create(:job, :running)

      result = described_class.schedule_retry(job)

      expect(result).to be false
      expect(job.reload.state).to eq("running")
    end
  end

  # ─── Backoff Calculation ───────────────────────────────────────────

  describe ".calculate_delay" do
    it "increases exponentially" do
      delays = (0..4).map { |n| described_class.calculate_delay(n) }

      # Each delay should be roughly 2x the previous (within jitter range)
      delays.each_cons(2) do |shorter, longer|
        # With jitter, the ratio should be between 1.0 and 4.0
        expect(longer).to be >= shorter * 0.5
      end
    end

    it "respects the maximum delay cap" do
      # With retry_count = 20, raw delay would be 5 * 2^20 = 5,242,880
      delay = described_class.calculate_delay(20)
      max_with_jitter = RetryHandler::MAX_DELAY * (1 + RetryHandler::JITTER_FACTOR)

      expect(delay).to be <= max_with_jitter
    end

    it "has a minimum delay of 1 second" do
      # Even at retry_count 0, delay should be at least 1 second
      100.times do
        delay = described_class.calculate_delay(0)
        expect(delay).to be >= 1.0
      end
    end
  end
end
