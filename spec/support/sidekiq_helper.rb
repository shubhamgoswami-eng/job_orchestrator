# frozen_string_literal: true

# Sidekiq testing mode configuration
require "sidekiq/testing"

RSpec.configure do |config|
  config.before(:each) do
    Sidekiq::Worker.clear_all
  end
end

# Default to fake mode (jobs are pushed to arrays, not executed)
Sidekiq::Testing.fake!
