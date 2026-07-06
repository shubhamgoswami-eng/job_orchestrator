# frozen_string_literal: true

# Stores the concurrency limit for each client.
#
# The {ConcurrencyGuard} reads this value on every slot acquisition attempt,
# ensuring dynamic updates take effect immediately without restarts.
class ClientQuota < ApplicationRecord
  self.table_name = "client_quotas"
  DEFAULT_CONCURRENCY_LIMIT = 5

  validates :client_id, presence: true, uniqueness: true, length: { maximum: 255 }
  validates :concurrency_limit, numericality: {
    only_integer: true,
    greater_than_or_equal_to: 1,
    less_than_or_equal_to: 100
  }

  # Returns the concurrency limit for a client, falling back to the default
  # if no quota record exists.
  #
  # @param client_id [String]
  # @return [Integer]
  def self.limit_for(client_id)
    find_by(client_id: client_id)&.concurrency_limit || DEFAULT_CONCURRENCY_LIMIT
  end
end
