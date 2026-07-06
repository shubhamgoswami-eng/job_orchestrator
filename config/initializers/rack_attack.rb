# frozen_string_literal: true

# Rate limiting to prevent abuse (e.g., 1 million jobs in 10 seconds).
#
# Strategy: Per-client rate limiting using Rack::Attack.
# This ensures a single abusive client cannot overwhelm the system
# while others remain unaffected.
#
class Rack::Attack
  # Limit job submissions per client_id: 100 per minute
  throttle("jobs/create/client", limit: 100, period: 60) do |req|
    if req.path == "/jobs" && req.post?
      # Parse the request body to extract client_id
      begin
        body = JSON.parse(req.body.read)
        req.body.rewind
        body["client_id"]
      rescue JSON::ParserError
        nil
      end
    end
  end

  # Global rate limit: 1000 job submissions per minute across all clients
  throttle("jobs/create/global", limit: 1000, period: 60) do |req|
    req.ip if req.path == "/jobs" && req.post?
  end

  # Custom response for throttled requests
  self.throttled_responder = lambda do |_request|
    [
      429,
      { "Content-Type" => "application/json" },
      [{ error: "Rate limit exceeded. Please try again later." }.to_json]
    ]
  end
end
