# frozen_string_literal: true

# Seed default client quotas for testing
clients = [
  { client_id: "acme_corp", concurrency_limit: 5 },
  { client_id: "beta_health", concurrency_limit: 3 },
  { client_id: "gamma_labs", concurrency_limit: 10 }
]

clients.each do |attrs|
  ClientQuota.find_or_create_by!(client_id: attrs[:client_id]) do |q|
    q.concurrency_limit = attrs[:concurrency_limit]
  end
end

puts "Seeded #{clients.size} client quotas"
