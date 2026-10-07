# frozen_string_literal: true

# Data-plane routes: chat completions, legacy completions, embeddings, responses.
# Registered via `Sinatra::Base.register Routes::Completions` in proxy.rb.
module Routes
  module Completions
    def self.stream_requested?(body)
      body["stream"] == true
    end

    def self.registered(app)
      %w[chat/completions completions responses].each do |endpoint|
        responses_api = endpoint == "responses"

        app.post "/v1/#{endpoint}" do
          req = parse_request
          stream_requested = Routes::Completions.stream_requested?(req[:body])

          if stream_requested
            HTTPSupport::SSE_HEADERS.each { |k, v| headers[k] = v }

            # The stream block runs lazily during response-body iteration,
            # after the `after` filters. Deferring request accounting to the
            # block keeps in_flight covering the whole stream (so graceful
            # shutdown drains properly) and the duration metric honest.
            @stream_deferred = true
            stream do |out|
              result = with_auto_select(
                model: req[:model], model_name: req[:model_name],
                path: endpoint, body: req[:body], headers: req[:headers]
              ) { |pc, p, b, pm, h, lp, dr| try_stream(pc, p, b, pm, h, out: out, log_prefix: lp, deadline_remaining: dr, responses_api: responses_api, model_name: req[:model_name]) }
              handle_streaming_error(result, out, is_responses: responses_api)
            rescue HTTPSupport::ClientDisconnected
              settings.logger.info("[#{@request_id}] Client disconnected mid-stream")
            rescue => e
              settings.logger.error("[#{@request_id}] Streaming error: #{e.class}: #{e.message}")
              settings.logger.debug(e.backtrace.join("\n")) if e.backtrace
              begin
                if responses_api
                  out << streaming_responses_error("Internal streaming error", detail: "request_id=#{@request_id}")
                else
                  out << streaming_error("Internal streaming error", detail: "request_id=#{@request_id}")
                end
                out << "data: [DONE]\n\n"
              rescue
                nil
              end
            ensure
              finalize_request!
            end
          else
            result = with_auto_select(
              model: req[:model], model_name: req[:model_name],
              path: endpoint, body: req[:body], headers: req[:headers]
            ) { |pc, p, b, pm, h, lp, dr| try_single_request(pc, p, b, pm, h, log_prefix: lp, deadline_remaining: dr, responses_api: responses_api) }
            handle_non_stream_result(result)
          end
        end
      end

      app.post "/v1/embeddings" do
        req = parse_request(allowed_headers: ["Authorization"])
        result = with_auto_select(
          model: req[:model], model_name: req[:model_name],
          path: "embeddings", body: req[:body], headers: req[:headers]
        ) { |pc, p, b, pm, h, lp, dr| try_single_request(pc, p, b, pm, h, log_prefix: lp, deadline_remaining: dr) }
        handle_non_stream_result(result)
      end
    end
  end
end
