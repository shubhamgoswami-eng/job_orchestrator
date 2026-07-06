# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthChecker do
  # ─── All Healthy ──────────────────────────────────────────────────

  describe ".check" do
    context "when all components are healthy" do
      before do
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_return("PONG")
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        queue_double = instance_double(Sidekiq::Queue, latency: 1.0, size: 5)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns a healthy result" do
        result = described_class.check

        expect(result.healthy).to be true
        expect(result.components[:database][:healthy]).to be true
        expect(result.components[:redis][:healthy]).to be true
        expect(result.components[:sidekiq][:healthy]).to be true
      end

      it "includes latency metrics" do
        result = described_class.check

        expect(result.components[:database][:latency_ms]).to be_a(Float)
        expect(result.components[:redis][:latency_ms]).to be_a(Float)
        expect(result.components[:sidekiq][:latency_seconds]).to eq(1.0)
      end

      it "includes job summary counts" do
        create(:job, :queued)
        create(:job, :running)

        result = described_class.check

        expect(result.components[:jobs][:queued]).to eq(1)
        expect(result.components[:jobs][:running]).to eq(1)
      end
    end

    # ─── Degraded State ──────────────────────────────────────────────

    context "when Redis is unreachable" do
      before do
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_raise(Redis::CannotConnectError)
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        queue_double = instance_double(Sidekiq::Queue, latency: 0.0, size: 0)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns unhealthy result" do
        result = described_class.check
        expect(result.healthy).to be false
        expect(result.components[:redis][:healthy]).to be false
      end
    end

    context "when Sidekiq latency exceeds threshold" do
      before do
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_return("PONG")
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        queue_double = instance_double(Sidekiq::Queue, latency: 20.0, size: 1000)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns unhealthy result" do
        result = described_class.check
        expect(result.healthy).to be false
        expect(result.components[:sidekiq][:healthy]).to be false
      end
    end
  end
end
