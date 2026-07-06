# frozen_string_literal: true

# Detailed health endpoint returning component-level health status.
#
# GET /health/detailed
#   Returns HTTP 200 with structured JSON when all healthy.
#   Returns HTTP 503 when any component is degraded.
#
class HealthController < ApplicationController
  # GET /health/detailed
  def detailed
    result = HealthChecker.check

    status = result.healthy ? :ok : :service_unavailable

    render json: {
      status: result.healthy ? "healthy" : "degraded",
      components: result.components,
      timestamp: result.timestamp
    }, status: status
  end
end
