# frozen_string_literal: true

FactoryBot.define do
  factory :job do
    client_id { "client_#{SecureRandom.hex(4)}" }
    priority { 1 } # medium
    workload { "task_#{SecureRandom.hex(4)}" }
    state { "queued" }
    retry_count { 0 }
    max_retries { 5 }
    scheduled_at { Time.current }

    trait :low_priority do
      priority { 0 }
    end

    trait :medium_priority do
      priority { 1 }
    end

    trait :high_priority do
      priority { 2 }
    end

    trait :queued do
      state { "queued" }
    end

    trait :running do
      state { "running" }
      started_at { Time.current }
    end

    trait :completed do
      state { "completed" }
      started_at { 1.minute.ago }
      completed_at { Time.current }
    end

    trait :failed do
      state { "failed" }
      started_at { 1.minute.ago }
      completed_at { Time.current }
      error_message { "Something went wrong" }
    end

    trait :stalled do
      state { "stalled" }
      started_at { 2.minutes.ago }
      completed_at { Time.current }
      error_message { "Heartbeat expired" }
    end

    trait :with_idempotency_key do
      idempotency_key { SecureRandom.uuid }
    end

    trait :scheduled_future do
      scheduled_at { 1.hour.from_now }
    end

    trait :instant_workload do
      workload { "instant_test" }
    end

    trait :failing_workload do
      workload { "fail_test" }
    end
  end

  factory :client_quota do
    client_id { "client_#{SecureRandom.hex(4)}" }
    concurrency_limit { 5 }

    trait :low_limit do
      concurrency_limit { 1 }
    end

    trait :high_limit do
      concurrency_limit { 20 }
    end
  end
end
