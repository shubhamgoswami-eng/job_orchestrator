# frozen_string_literal: true

Rails.application.routes.draw do
  # Job submission and status
  resources :jobs, only: [ :create, :show ]

  # Health monitoring
  get "health/detailed", to: "health#detailed"

  # Default Rails health check
  get "up" => "rails/health#show", as: :rails_health_check
end
