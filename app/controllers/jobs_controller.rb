# frozen_string_literal: true

# API endpoint for job submission.
#
# POST /jobs
#   Accepts a JSON payload with client_id, priority, and workload.
#   Returns the job ID and initial status immediately.
#
# GET /jobs/:id
#   Returns the current state of a job.
#
class JobsController < ApplicationController
  # POST /jobs
  def create
    result = JobSubmissionService.call(
      client_id: job_params[:client_id],
      priority: job_params[:priority],
      workload: job_params[:workload],
      idempotency_key: job_params[:idempotency_key]
    )

    if result.success?
      render json: serialize_job(result.job), status: :created
    else
      render json: { errors: result.errors }, status: :unprocessable_entity
    end
  end

  # GET /jobs/:id
  def show
    job = Job.find_by(id: params[:id])

    if job
      render json: serialize_job(job)
    else
      render json: { error: "Job not found" }, status: :not_found
    end
  end

  private

  def job_params
    params.permit(:client_id, :priority, :workload, :idempotency_key)
  end

  def serialize_job(job)
    {
      id: job.id,
      client_id: job.client_id,
      priority: job.priority_label,
      workload: job.workload,
      state: job.state,
      retry_count: job.retry_count,
      scheduled_at: job.scheduled_at&.iso8601,
      started_at: job.started_at&.iso8601,
      completed_at: job.completed_at&.iso8601,
      error_message: job.error_message,
      created_at: job.created_at&.iso8601
    }
  end
end
