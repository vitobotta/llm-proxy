# frozen_string_literal: true

# Admin/observability routes: health, metrics, model listing.
# Registered via `Sinatra::Base.register Routes::Admin` in proxy.rb.
module Routes
  module Admin
    def self.registered(app)
      app.get "/health" do
        content_type :json
        {status: "ok"}.to_json
      end

      app.get "/v1/health/detail" do
        content_type :json
        provider_status = {}
        ConfigStore.selectors.each do |name, selector|
          metrics = selector.active_metrics
          provider_status[name] = {
            active_provider: selector.active_provider_name,
            metrics: metrics,
            providers: selector.provider_stats
          }
        end
        {status: "ok", models: ConfigStore.models.keys, providers: provider_status, timestamp: Time.now.iso8601}.to_json
      end

      app.get "/metrics" do
        metrics_token_required!
        content_type "text/plain; version=0.0.4"
        Metrics.to_prometheus
      end

      app.get "/v1/models" do
        content_type :json
        models = ConfigStore.models
        {
          object: "list",
          data: models.keys.map { |name| {id: name, object: "model", owned_by: "proxy", context_length: models[name]["context_length"]}.compact }
        }.to_json
      end

      app.get "/v1/models/:name" do
        content_type :json
        model = ConfigStore.model(params[:name])
        halt json_error(status: 404, message: "Model '#{params[:name]}' not found", type: "model_not_found") unless model

        {
          id: model["name"],
          object: "model",
          owned_by: "proxy",
          context_length: model["context_length"],
          providers: model["providers"].map { |p| {provider: p["provider"], model: p["model"]} }
        }.compact.to_json
      end
    end
  end
end
