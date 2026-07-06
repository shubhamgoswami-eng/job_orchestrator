# frozen_string_literal: true

# Represents an asynchronous job submitted by a client for execution.
#
# Jobs follow a strict state machine lifecycle:
#   queued → running → completed | failed | stalled
#
# State transitions are enforced at the service layer via {JobStateMachine}
# to ensure atomicity and prevent illegal transitions.
#
# @see JobStateMachine for transition logic
# @see ConcurrencyGuard for per-client quota enforcement
class Job < ApplicationRecord
  # -- Constants ----------------------------------------------------------

  STATES = %w[queued running completed failed stalled].freeze
  TERMINAL_STATES = %w[completed failed].freeze
  PRIORITIES = { "low" => 0, "medium" => 1, "high" => 2 }.freeze
  PRIORITY_VALUES = PRIORITIES.values.freeze

  # -- Validations --------------------------------------------------------

  validates :client_id, presence: true, length: { maximum: 255 }
  validates :workload, presence: true, length: { maximum: 255 }
  validates :state, presence: true, inclusion: { in: STATES }
  validates :priority, presence: true, inclusion: { in: PRIORITY_VALUES }
  validates :retry_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :max_retries, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :idempotency_key, uniqueness: true, allow_nil: true

  # -- Scopes -------------------------------------------------------------

  scope :in_state, ->(state) { where(state: state) }
  scope :queued, -> { in_state("queued") }
  scope :running, -> { in_state("running") }
  scope :schedulable, -> {
    queued.where("scheduled_at <= ?", Time.current)
  }

  scope :for_client, ->(client_id) { where(client_id: client_id) }

  # Ordered for scheduling: highest priority first, then oldest first (FIFO within priority)
  scope :by_scheduling_order, -> { order(priority: :desc, scheduled_at: :asc, id: :asc) }

  # -- Class Methods ------------------------------------------------------

  # Resolves a string priority label to its integer value.
  #
  # @param label [String] one of "low", "medium", "high"
  # @return [Integer] the priority integer (0, 1, or 2)
  # @raise [ArgumentError] if the label is invalid
  def self.priority_from_label(label)
    PRIORITIES.fetch(label.to_s.downcase) do
      raise ArgumentError, "Invalid priority: #{label}. Must be one of: #{PRIORITIES.keys.join(', ')}"
    end
  end

  # -- Instance Methods ---------------------------------------------------

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  def retriable?
    state == "failed" && retry_count < max_retries
  end

  def priority_label
    PRIORITIES.key(priority) || "unknown"
  end
end
