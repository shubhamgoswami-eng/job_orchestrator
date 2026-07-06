# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2024_01_01_000002) do
  create_table "client_quotas", force: :cascade do |t|
    t.string "client_id", limit: 255, null: false
    t.integer "concurrency_limit", default: 5, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "idx_client_quotas_client_id", unique: true
  end

  create_table "jobs", force: :cascade do |t|
    t.string "client_id", limit: 255, null: false
    t.integer "priority", default: 1, null: false
    t.string "workload", limit: 255, null: false
    t.string "state", limit: 20, default: "queued", null: false
    t.string "idempotency_key", limit: 255
    t.integer "retry_count", default: 0, null: false
    t.integer "max_retries", default: 5, null: false
    t.datetime "scheduled_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "started_at"
    t.datetime "completed_at"
    t.text "error_message"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id", "state"], name: "idx_jobs_client_state"
    t.index ["idempotency_key"], name: "idx_jobs_idempotency", unique: true
    t.index ["state", "scheduled_at", "priority"], name: "idx_jobs_scheduling"
    t.index ["state", "started_at"], name: "idx_jobs_stall_detection"
  end
end
