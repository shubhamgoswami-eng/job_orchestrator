# frozen_string_literal: true

# Enforces per-client concurrency limits across the entire cluster using Redis.
#
# Each client_id has a Redis Sorted Set tracking its running job IDs.
# Slot acquisition and release use Lua scripts for atomicity.
#
# Key design decisions:
#   1. Sorted Set (not a counter) — we can enumerate running jobs for debugging
#      and reaper operations, and the score (timestamp) enables orphan detection.
#   2. Lua scripts — atomic check-and-increment prevents the TOCTOU race
#      where two workers both see count < limit and both proceed.
#   3. Dynamic quota — the limit is read from MySQL on every acquire attempt,
#      so admin changes take effect immediately.
#   4. No TTL on the set members — slots are released explicitly or by the
#      StallMonitor reaper. TTL-based expiry risks premature slot release
#      for long-running legitimate jobs.
#
# @example Acquiring a slot
#   guard = ConcurrencyGuard.new
#   if guard.acquire(client_id: "acme", job_id: 42)
#     # proceed to execute
#   else
#     # quota full, re-queue
#   end
#
class ConcurrencyGuard
  REDIS_KEY_PREFIX = "concurrency"

  # Lua script for atomic slot acquisition.
  # KEYS[1] = sorted set key
  # ARGV[1] = concurrency limit
  # ARGV[2] = job_id (member)
  # ARGV[3] = current timestamp (score)
  #
  # Returns 1 if acquired, 0 if quota full.
  ACQUIRE_SCRIPT = <<~LUA
    local current_count = redis.call('ZCARD', KEYS[1])
    local limit = tonumber(ARGV[1])
    if current_count < limit then
      redis.call('ZADD', KEYS[1], ARGV[3], ARGV[2])
      return 1
    else
      return 0
    end
  LUA

  # @param redis [Redis] Redis connection (defaults to global)
  def initialize(redis: nil)
    @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
  end

  # Attempts to acquire a concurrency slot for the given client and job.
  #
  # @param client_id [String] the client identifier
  # @param job_id [Integer] the job ID to register
  # @return [Boolean] true if slot acquired, false if quota full
  def acquire(client_id:, job_id:)
    limit = ClientQuota.limit_for(client_id)
    key = redis_key(client_id)

    result = @redis.eval(
      ACQUIRE_SCRIPT,
      keys: [ key ],
      argv: [ limit, job_id.to_s, Time.current.to_f.to_s ]
    )

    result == 1
  rescue Redis::BaseError => e
    Rails.logger.error("[ConcurrencyGuard] Redis error during acquire: #{e.message}")
    false # Fail closed: don't start jobs if Redis is down
  end

  # Releases a concurrency slot for the given client and job.
  # Safe to call multiple times (idempotent).
  #
  # @param client_id [String]
  # @param job_id [Integer]
  # @return [Boolean] true if a slot was actually released
  def release(client_id:, job_id:)
    key = redis_key(client_id)
    removed = @redis.zrem(key, job_id.to_s)
    !!removed
  rescue Redis::BaseError => e
    Rails.logger.error("[ConcurrencyGuard] Redis error during release: #{e.message}")
    false
  end

  # Returns the number of currently occupied slots for a client.
  #
  # @param client_id [String]
  # @return [Integer]
  def running_count(client_id:)
    @redis.zcard(redis_key(client_id))
  rescue Redis::BaseError => e
    Rails.logger.error("[ConcurrencyGuard] Redis error during count: #{e.message}")
    0
  end

  # Returns all job IDs currently holding slots for a client.
  # Useful for debugging and reaper operations.
  #
  # @param client_id [String]
  # @return [Array<String>] job IDs
  def running_jobs(client_id:)
    @redis.zrange(redis_key(client_id), 0, -1)
  rescue Redis::BaseError => e
    Rails.logger.error("[ConcurrencyGuard] Redis error: #{e.message}")
    []
  end

  # Removes all slots for a client. Used in tests and emergency recovery.
  #
  # @param client_id [String]
  def clear(client_id:)
    @redis.del(redis_key(client_id))
  rescue Redis::BaseError
    # Best effort
  end

  private

  def redis_key(client_id)
    "#{REDIS_KEY_PREFIX}:#{client_id}"
  end
end
