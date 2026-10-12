# WhatsApp Cloud API adapter (graph.facebook.com, v21+).
#
# Config (ENV): WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID,
# WHATSAPP_APP_SECRET (X-Hub-Signature-256 HMAC), WHATSAPP_API_BASE
# (default https://graph.facebook.com — specs point it at a fake
# server).
#
# Webhooks: GET verification echoes hub.challenge when hub.mode=
# subscribe & hub.verify_token match; POST authenticity is
# sha256=HMAC_SHA256(app_secret, raw_body) in X-Hub-Signature-256.

require "openssl/hmac"

module ActionBot
  module Adapters
    class WhatsAppAdapter
      include DeliveryAdapter
      include IngressAdapter
      include WebhookVerification

      DEFAULT_BASE = "https://graph.facebook.com"

      def initialize
        @token = ENV["WHATSAPP_ACCESS_TOKEN"]? || ""
        @phone_number_id = ENV["WHATSAPP_PHONE_NUMBER_ID"]? || ""
        @app_secret = ENV["WHATSAPP_APP_SECRET"]? || ""
        @verify_token = ENV["WHATSAPP_VERIFY_TOKEN"]? || ""
        @base = ENV["WHATSAPP_API_BASE"]? || DEFAULT_BASE
      end

      # --- Ingest ------------------------------------------------------------

      def parse_update(payload : JSON::Any) : Update
        change = payload["entry"]?.try(&.as_a.first?).try(&.["changes"]?).try(&.as_a.first?)
        return Update.new(:message, raw: payload) unless change

        value = change["value"]
        account_id = value["metadata"]?.try(&.["phone_number_id"]?).try(&.as_s?)

        if messages = value["messages"]?.try(&.as_a?)
          msg = messages.first
          wa_id = msg["from"].try(&.as_s) || ""
          contact = value["contacts"]?.try(&.as_a?).try(&.first?)
          name = contact.try(&.["profile"]?).try(&.["name"]?).try(&.as_s?)
          from = Participant.new("whatsapp", wa_id, nil, name)
          chat = Chat.new(wa_id, :private)

          kind, text, payload_data =
            case msg["type"]?.try(&.as_s)
            when "button"
              btn = msg["button"]
              {:button, btn["text"]?.try(&.as_s?), btn["payload"]?.try(&.as_s?)}
            else
              {:message, msg["text"]?.try(&.["body"]?).try(&.as_s?), nil}
            end

          message = Message.new(msg["id"]?.try(&.as_s?), from, chat, text, nil,
            [] of Attachment, msg)
          Update.new(kind, nil, account_id, message: message, raw: msg)
        elsif statuses = value["statuses"]?.try(&.as_a?)
          st = statuses.first
          Update.new(:status, nil, account_id,
            status: st["status"]?.try(&.as_s?), raw: st)
        else
          Update.new(:message, nil, account_id, raw: payload)
        end
      end

      # --- Webhook verification ----------------------------------------------

      def verify_webhook?(headers : HTTP::Headers, body : String) : Bool
        return true if @app_secret.empty? # not configured → open (dev)
        sig = headers["X-Hub-Signature-256"]?
        return false unless sig.try(&.starts_with?("sha256="))
        expected = OpenSSL::HMAC.hexdigest(:sha256, @app_secret, body)
        crypto_eq(sig.not_nil![7..], expected)
      end

      # GET verification: echo hub.challenge when the token matches.
      def webhook_challenge(params : HTTP::Params) : String?
        return nil unless params["hub.mode"]? == "subscribe"
        if @verify_token.empty? || params["hub.verify_token"]? == @verify_token
          params["hub.challenge"]?
        end
      end

      private def crypto_eq(a : String, b : String) : Bool
        return false unless a.bytesize == b.bytesize
        a.to_slice.zip(b.to_slice).reduce(0_u8) { |acc, (x, y)| acc | (x ^ y) } == 0
      end

      # --- Outbound -----------------------------------------------------------

      def message_payload(msg : OutboundMessage) : String
        JSON.build do |j|
          j.object do
            j.field "messaging_product", "whatsapp"
            j.field "to", msg.chat_id
            j.field "type", "text"
            j.field "text" do
              j.object do
                j.field "body", msg.text || ""
              end
            end
          end
        end
      end

      def deliver(msg : OutboundMessage) : DeliveryReceipt
        response = HTTP::Client.post("#{@base}/v21.0/#{@phone_number_id}/messages",
          headers: HTTP::Headers{
            "Content-Type"  => "application/json",
            "Authorization" => "Bearer #{@token}",
          },
          body: message_payload(msg))
        body = JSON.parse(response.body)
        id = body["messages"]?.try(&.as_a?).try(&.first?).try(&.["id"]?).try(&.as_s?)
        DeliveryReceipt.new(id, :delivered, body)
      end
    end
  end
end
