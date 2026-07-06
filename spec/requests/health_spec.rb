# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health API", type: :request do
  # ─── GET /health/detailed ──────────────────────────────────────────

  describe "GET /health/detailed" do
    context "when all components are healthy" do
      before do
        # Mock Redis as healthy
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_return("PONG")
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        # Mock Sidekiq queue latency as low
        queue_double = instance_double(Sidekiq::Queue, latency: 0.5, size: 0)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns 200 with healthy status" do
        get "/health/detailed"

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("healthy")
        expect(json["components"]["database"]["healthy"]).to be true
        expect(json["components"]["redis"]["healthy"]).to be true
        expect(json["components"]["sidekiq"]["healthy"]).to be true
        expect(json["timestamp"]).to be_present
      end

      it "includes job summary" do
        create(:job, :queued)
        create(:job, :running)
        create(:job, :completed)

        get "/health/detailed"

        json = JSON.parse(response.body)
        jobs = json["components"]["jobs"]
        expect(jobs["queued"]).to eq(1)
        expect(jobs["running"]).to eq(1)
        expect(jobs["completed"]).to eq(1)
      end
    end

    context "when Redis is down" do
      before do
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_raise(Redis::CannotConnectError)
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        queue_double = instance_double(Sidekiq::Queue, latency: 0.0, size: 0)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns 503 with degraded status" do
        get "/health/detailed"

        expect(response).to have_http_status(:service_unavailable)
        json = JSON.parse(response.body)
        expect(json["status"]).to eq("degraded")
        expect(json["components"]["redis"]["healthy"]).to be false
      end
    end

    context "when Sidekiq latency is too high" do
      before do
        redis_double = instance_double(Redis)
        allow(redis_double).to receive(:ping).and_return("PONG")
        allow(redis_double).to receive(:close)
        allow(Redis).to receive(:new).and_return(redis_double)

        # Latency > 15 seconds
        queue_double = instance_double(Sidekiq::Queue, latency: 20.0, size: 500)
        allow(Sidekiq::Queue).to receive(:new).and_return(queue_double)
      end

      it "returns 503 with high latency" do
        get "/health/detailed"

        expect(response).to have_http_status(:service_unavailable)
        json = JSON.parse(response.body)
        expect(json["components"]["sidekiq"]["healthy"]).to be false
        expect(json["components"]["sidekiq"]["latency_seconds"]).to eq(20.0)
      end
    end
  end
end
