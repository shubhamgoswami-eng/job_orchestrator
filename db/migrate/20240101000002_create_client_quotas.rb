# frozen_string_literal: true

class CreateClientQuotas < ActiveRecord::Migration[7.2]
  def change
    create_table :client_quotas do |t|
      t.string :client_id, null: false, limit: 255
      t.integer :concurrency_limit, null: false, default: 5

      t.timestamps
    end

    add_index :client_quotas, :client_id, unique: true, name: "idx_client_quotas_client_id"
  end
end
