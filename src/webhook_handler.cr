# WebhookHandler — the single HTTP mount for all bots
# (`/bot/webhooks/:platform/:bot`), the CableHandler pattern: apps add
# one line in their Application#call (`when "/bot/webhooks" then
# ActionBot.webhook_handler.call(context)`) and every registered bot
# is served; new bots don't change the mount.
#
# Flow: find bot by name → build its adapter → GET answers the platform
# verification challenge, POST verifies authenticity (when the adapter
# has the capability) → parse_update → dispatch in a fiber → 200
# immediately (platforms retry timeouts; slow CRM work must not block).

module ActionBot
  class WebhookHandler
    include HTTP::Handler

    MOUNT_PATH = "/bot/webhooks"

    def call(context : HTTP::Server::Context)
      path = context.request.path
      unless path.starts_with?(MOUNT_PATH)
        call_next(context)
        return
      end

      segments = path.split("/").reject(&.empty?) # ["agent","webhooks",platform,bot]
      if segments.size < 4
        context.response.status = :not_found
        return
      end
      platform, bot_name = segments[2], segments[3]

      bot = ActionBot.lookup_bot(bot_name)
      if bot.nil? || bot.__platform != platform
        context.response.status = :not_found
        return
      end

      adapter = bot.__adapter

      case context.request.method
      when "GET"
        if adapter.is_a?(WebhookVerification)
          if challenge = adapter.webhook_challenge(URI::Params.parse(context.request.resource))
            context.response.content_type = "text/plain"
            context.response.print(challenge)
          else
            context.response.status = :forbidden
          end
        else
          context.response.status = :method_not_allowed
        end
      when "POST"
        body = context.request.body.try(&.gets_to_end) || ""
        if adapter.is_a?(WebhookVerification) && !adapter.verify_webhook?(context.request.headers, body)
          context.response.status = :forbidden
          return
        end
        unless adapter.is_a?(IngressAdapter)
          context.response.status = :not_implemented
          return
        end
        update = adapter.parse_update(JSON.parse(body).as(JSON::Any))
        spawn(name: "agent-webhook-#{bot_name}") do
          bot.new.dispatch(update)
        end
        context.response.status = :ok
      else
        context.response.status = :method_not_allowed
      end
    end
  end

  class_property webhook_handler = WebhookHandler.new
end
