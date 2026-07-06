# frozen_string_literal: true

require "redis"

module RedisHelper
  def mock_redis
    @mock_redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end

  def reset_mock_redis!
    mock_redis.flushdb
  end
end

RSpec.configure do |config|
  config.include RedisHelper

  config.before(:each) do
    reset_mock_redis!
  end
end
