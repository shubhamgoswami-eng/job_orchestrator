# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientQuota, type: :model do
  describe "validations" do
    subject { build(:client_quota) }

    it { is_expected.to validate_presence_of(:client_id) }
    it { is_expected.to validate_uniqueness_of(:client_id).case_insensitive }
    it {
      is_expected.to validate_numericality_of(:concurrency_limit)
        .only_integer
        .is_greater_than_or_equal_to(1)
        .is_less_than_or_equal_to(100)
    }
  end

  describe ".limit_for" do
    it "returns the configured limit for an existing client" do
      create(:client_quota, client_id: "acme", concurrency_limit: 10)
      expect(ClientQuota.limit_for("acme")).to eq(10)
    end

    it "returns the default limit for an unknown client" do
      expect(ClientQuota.limit_for("unknown")).to eq(ClientQuota::DEFAULT_CONCURRENCY_LIMIT)
    end
  end
end
