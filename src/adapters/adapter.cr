# Adapter ports — frozen module-interfaces (project ISP standard:
# small ports, `include` instead of inheritance, capability checks via
# `adapter.is_a?(...)`; additive evolution only, never re-profiled).

module ActionBot
  # Outbound: send a normalized message over the platform.
  module DeliveryAdapter
    abstract def deliver(msg : OutboundMessage) : DeliveryReceipt
  end

  # Optional capability — streaming replies into a chat. No platform
  # streams natively, so the honest contract is a message that "lives":
  # start → (append chunk)* → commit. Telegram implements it with
  # editMessageText (batched, throttled ~1 edit/s); the web/SSE side
  # streams real chunks out of the same pipeline.
  module StreamingDelivery
    include DeliveryAdapter

    abstract def start_stream(chat_id : String) : DeliveryReceipt
    abstract def append_stream(receipt : DeliveryReceipt, text_chunk : String) : Nil
    abstract def commit_stream(receipt : DeliveryReceipt, final_text : String) : Nil
  end

  # Inbound: normalize a platform payload into the unified Update.
  module IngressAdapter
    abstract def parse_update(payload : JSON::Any) : Update
  end

  # Optional capability — webhook authenticity. Telegram: constant
  # X-Telegram-Bot-Api-Secret-Token; WhatsApp: X-Hub-Signature-256 HMAC
  # of the raw body with the app secret. `webhook_challenge` answers
  # Meta's GET verification (hub.challenge echo).
  module WebhookVerification
    abstract def verify_webhook?(headers : HTTP::Headers, body : String) : Bool

    def webhook_challenge(params : HTTP::Params) : String?
      nil
    end
  end
end
