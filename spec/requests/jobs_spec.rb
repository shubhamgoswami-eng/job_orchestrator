# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Jobs API", type: :request do
  before do
    allow(SchedulerWorker).to receive(:perform_async)
  end

  # ─── POST /jobs ─────────────────────────────────────────────────────

  describe "POST /jobs" do
    let(:valid_params) do
      {
        client_id: "acme_corp",
        priority: "high",
        workload: "process_assessment"
      }
    end

    context "with valid parameters" do
      it "creates a job and returns 201" do
        post "/jobs", params: valid_params, as: :json

        expect(response).to have_http_status(:created)
        json = JSON.parse(response.body)
        expect(json["id"]).to be_present
        expect(json["state"]).to eq("queued")
        expect(json["priority"]).to eq("high")
        expect(json["client_id"]).to eq("acme_corp")
      end

      it "returns the job ID for status tracking" do
        post "/jobs", params: valid_params, as: :json
        json = JSON.parse(response.body)

        expect(json["id"]).to be_a(Integer)
        expect(Job.find(json["id"])).to be_present
      end
    end

    context "with invalid parameters" do
      it "returns 422 for invalid priority" do
        post "/jobs", params: valid_params.merge(priority: "urgent"), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["errors"]).to include(a_string_matching(/Invalid priority/))
      end

      it "returns 422 for missing client_id" do
        post "/jobs", params: valid_params.merge(client_id: ""), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "returns 422 for missing workload" do
        post "/jobs", params: valid_params.merge(workload: ""), as: :json

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "with idempotency key" do
      it "deduplicates submissions with the same key" do
        params_with_key = valid_params.merge(idempotency_key: "unique_123")

        post "/jobs", params: params_with_key, as: :json
        first_id = JSON.parse(response.body)["id"]

        post "/jobs", params: params_with_key, as: :json
        second_id = JSON.parse(response.body)["id"]

        expect(second_id).to eq(first_id)
        expect(Job.count).to eq(1)
      end
    end

    context "with all priority levels" do
      %w[low medium high].each do |priority|
        it "accepts '#{priority}' priority" do
          post "/jobs", params: valid_params.merge(priority: priority), as: :json
          expect(response).to have_http_status(:created)
        end
      end
    end
  end

  # ─── GET /jobs/:id ─────────────────────────────────────────────────

  describe "GET /jobs/:id" do
    it "returns job details" do
      job = create(:job, client_id: "acme", workload: "task_1")

      get "/jobs/#{job.id}"

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["id"]).to eq(job.id)
      expect(json["client_id"]).to eq("acme")
      expect(json["state"]).to eq("queued")
    end

    it "returns 404 for non-existent job" do
      get "/jobs/99999"

      expect(response).to have_http_status(:not_found)
    end
  end
end
