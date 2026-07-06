# frozen_string_literal: true

class CreateJobs < ActiveRecord::Migration[7.2]
  def change
    create_table :jobs do |t|
      t.string :client_id, null: false, limit: 255
      t.integer :priority, null: false, default: 1, comment: "0=low, 1=medium, 2=high"
      t.string :workload, null: false, limit: 255
      t.string :state, null: false, default: "queued", limit: 20
      t.string :idempotency_key, limit: 255
      t.integer :retry_count, null: false, default: 0
      t.integer :max_retries, null: false, default: 5
      t.datetime :scheduled_at, null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error_message
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    # Primary scheduling query: find queued jobs ready to run, ordered by priority
    add_index :jobs, [:state, :scheduled_at, :priority], name: "idx_jobs_scheduling"

    # Per-client state lookups (concurrency counting, fairness queries)
    add_index :jobs, [:client_id, :state], name: "idx_jobs_client_state"

    # Idempotency enforcement — MySQL allows multiple NULLs in unique indexes
    add_index :jobs, :idempotency_key, unique: true, name: "idx_jobs_idempotency"

    # Stall detection: find running jobs to check heartbeats
    add_index :jobs, [:state, :started_at], name: "idx_jobs_stall_detection"
  end
end
