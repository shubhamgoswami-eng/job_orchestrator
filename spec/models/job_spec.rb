# frozen_string_literal: true

require "rails_helper"

RSpec.describe Job, type: :model do
  describe "validations" do
    subject { build(:job) }

    it { is_expected.to validate_presence_of(:client_id) }
    it { is_expected.to validate_presence_of(:workload) }
    it { is_expected.to validate_presence_of(:state) }
    it { is_expected.to validate_presence_of(:priority) }

    it { is_expected.to validate_inclusion_of(:state).in_array(Job::STATES) }
    it { is_expected.to validate_inclusion_of(:priority).in_array(Job::PRIORITY_VALUES) }

    it {
      is_expected.to validate_numericality_of(:retry_count)
        .only_integer
        .is_greater_than_or_equal_to(0)
    }
  end

  describe "scopes" do
    describe ".schedulable" do
      it "returns only queued jobs with scheduled_at <= now" do
        ready = create(:job, :queued, scheduled_at: 1.minute.ago)
        _future = create(:job, :queued, scheduled_at: 1.hour.from_now)
        _running = create(:job, :running)

        expect(Job.schedulable).to eq([ ready ])
      end
    end

    describe ".by_scheduling_order" do
      it "orders by priority DESC, then scheduled_at ASC" do
        low = create(:job, :low_priority, scheduled_at: 1.minute.ago)
        high = create(:job, :high_priority, scheduled_at: Time.current)
        medium = create(:job, :medium_priority, scheduled_at: 2.minutes.ago)

        expect(Job.by_scheduling_order).to eq([ high, medium, low ])
      end
    end
  end

  describe ".priority_from_label" do
    it "converts 'high' to 2" do
      expect(Job.priority_from_label("high")).to eq(2)
    end

    it "converts 'medium' to 1" do
      expect(Job.priority_from_label("medium")).to eq(1)
    end

    it "converts 'low' to 0" do
      expect(Job.priority_from_label("low")).to eq(0)
    end

    it "is case-insensitive" do
      expect(Job.priority_from_label("HIGH")).to eq(2)
    end

    it "raises ArgumentError for invalid priority" do
      expect { Job.priority_from_label("urgent") }.to raise_error(ArgumentError)
    end
  end

  describe "#terminal?" do
    it "returns true for completed jobs" do
      expect(build(:job, :completed)).to be_terminal
    end

    it "returns true for failed jobs" do
      expect(build(:job, :failed)).to be_terminal
    end

    it "returns false for running jobs" do
      expect(build(:job, :running)).not_to be_terminal
    end

    it "returns false for queued jobs" do
      expect(build(:job, :queued)).not_to be_terminal
    end
  end

  describe "#retriable?" do
    it "returns true for failed jobs with retries remaining" do
      job = build(:job, :failed, retry_count: 2, max_retries: 5)
      expect(job).to be_retriable
    end

    it "returns false for failed jobs with retries exhausted" do
      job = build(:job, :failed, retry_count: 5, max_retries: 5)
      expect(job).not_to be_retriable
    end

    it "returns false for non-failed jobs" do
      job = build(:job, :running, retry_count: 0, max_retries: 5)
      expect(job).not_to be_retriable
    end
  end
end
