# TestAdapter — network-free delivery for specs and the console
# (the ActiveJob :test-adapter pattern: deliveries are recorded, not
# sent; streamed chunks are folded into one delivered message).

module ActionBot
  module Adapters
    class TestAdapter
      include DeliveryAdapter
      include StreamingDelivery
      include IngressAdapter

      class_property deliveries = [] of OutboundMessage

      def self.reset : Nil
        deliveries.clear
      end

      # Test ingress: a normalized simplified shape
      # {"kind":"message","chat_id":"...","text":"...","data":"..."} —
      # platform-agnostic, so webhook tests don't depend on Telegram.
      def parse_update(payload : JSON::Any) : Update
        kind = case payload["kind"]?.try(&.as_s?)
               when "callback_query" then :callback_query
               else                      :message
               end
        chat_id = payload["chat_id"]?.try(&.as_s) || "test-chat"
        from = Participant.new("test", payload["from_id"]?.try(&.as_s) || "test-user")
        chat = Chat.new(chat_id, :private)
        msg = Message.new(nil, from, chat, payload["text"]?.try(&.as_s?), nil,
          [] of Attachment, payload)
        if kind == :callback_query
          Update.new(:callback_query, message: msg,
            callback: CallbackQuery.new("test-cq", from, chat, payload["data"]?.try(&.as_s?), payload))
        else
          Update.new(:message, message: msg, raw: payload)
        end
      end

    def deliver(msg : OutboundMessage) : DeliveryReceipt
      self.class.deliveries << msg
      DeliveryReceipt.new("test-#{self.class.deliveries.size}", :delivered,
        JSON::Any.new({} of String => JSON::Any))
    end

    def start_stream(chat_id : String) : DeliveryReceipt
      DeliveryReceipt.new("test-stream-#{chat_id}", :streaming,
        JSON::Any.new({} of String => JSON::Any))
    end

    def append_stream(receipt : DeliveryReceipt, text_chunk : String) : Nil
      acc = receipt.raw.raw.as(Hash(String, JSON::Any))
      acc["streamed"] = JSON::Any.new((acc["streamed"]?.try(&.as_s) || "") + text_chunk)
    end

    def commit_stream(receipt : DeliveryReceipt, final_text : String) : Nil
      acc = receipt.raw.raw.as(Hash(String, JSON::Any))
      acc["streamed"] = JSON::Any.new(final_text)
      self.class.deliveries << OutboundMessage.new(
        receipt.platform_message_id.to_s.split("-", 3)[-1]? || "", final_text)
    end

    # Last delivered text — spec sugar.
    def self.last_text : String?
      deliveries.last?.try(&.text)
    end
  end
end
end
