# frozen_string_literal: true

class ApplicationController < ActionController::API
  # Global exception handling for consistent error responses
  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { error: e.message }, status: :not_found
  end

  rescue_from ActionController::ParameterMissing do |e|
    render json: { error: e.message }, status: :bad_request
  end

  rescue_from StandardError do |e|
    Rails.logger.error("Unhandled error: #{e.message}\n#{e.backtrace&.first(10)&.join("\n")}")
    render json: { error: "Internal server error" }, status: :internal_server_error
  end
end
