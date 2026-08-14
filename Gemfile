source "https://rubygems.org"

gem "rails", "~> 7.2.3", ">= 7.2.3.1"

# MySQL adapter
gem "mysql2", "~> 0.5"

gem "puma", ">= 5.0"

# Background job processing
gem "sidekiq", "~> 7.0"
gem "sidekiq-cron", "~> 2.0"

# Redis client
gem "redis", "~> 5.0"

# JSON serialization
gem "oj", "~> 3.17"

# Rate limiting (abuse protection)
gem "rack-attack", "~> 6.7"

# Windows timezone data
gem "tzinfo-data", platforms: %i[windows jruby]

group :development, :test do
  gem "debug", platforms: %i[mri windows], require: "debug/prelude"
  gem "rspec-rails", "~> 7.0"
  gem "factory_bot_rails", "~> 6.4"
  gem "faker", "~> 3.4"
  gem "shoulda-matchers", "~> 6.0"
  gem "database_cleaner-active_record", "~> 2.2"
  gem "mock_redis", "~> 0.44"
  gem "brakeman", require: false
  gem "rubocop-rails-omakase", require: false
end

group :test do
  gem "simplecov", require: false
  gem "timecop", "~> 0.9"
end
