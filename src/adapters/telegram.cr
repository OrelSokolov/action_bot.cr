# Telegram Bot API adapter (https://core.telegram.org/bots/api).
#
# Config (ENV): TELEGRAM_BOT_TOKEN, TELEGRAM_API_BASE (default
# https://api.telegram.org — specs point it at a fake server),
# TELEGRAM_SECRET_TOKEN (webhook X-Telegram-Bot-Api-Secret-Token),
# TELEGRAM_STREAM_MIN_INTERVAL (progressive-edit throttle, seconds).

module ActionBot
  module Adapters
    class TelegramAdapter
      include DeliveryAdapter
      include StreamingDelivery
      include IngressAdapter
      include WebhookVerification

      DEFAULT_BASE = "https://api.telegram.org"

      def initialize
        @token = ENV["TELEGRAM_BOT_TOKEN"]? || ""
        @base = ENV["TELEGRAM_API_BASE"]? || DEFAULT_BASE
        @secret = ENV["TELEGRAM_SECRET_TOKEN"]?
        @min_edit_interval = (ENV["TELEGRAM_STREAM_MIN_INTERVAL"]? || "1.0").to_f
      end

      # --- Ingress ----------------------------------------------------------

      def parse_update(payload : JSON::Any) : Update
        update_id = payload["update_id"]?.try(&.as_i64)

        if msg = payload["message"]?
          Update.new(:message, update_id, nil,
            message: parse_message(msg), event: message_event(msg), raw: msg)
        elsif cq = payload["callback_query"]?
          from = parse_participant(cq["from"], "telegram")
          chat = parse_chat(cq["message"]?.try(&.["chat"]?) || empty_obj)
          Update.new(:callback_query, update_id, nil,
            callback: CallbackQuery.new(
              cq["id"]?.try(&.as_s) || "",
              from, chat,
              cq["data"]?.try(&.as_s?), cq), raw: cq)
        else
          Update.new(:message, update_id, nil, raw: payload)
        end
      end

      private def parse_message(msg : JSON::Any) : Message
        from = parse_participant(msg["from"]? || empty_obj, "telegram")
        chat = parse_chat(msg["chat"]? || empty_obj)
        text = msg["text"]?.try(&.as_s?)

        attachments = [] of Attachment
        if photo = msg["photo"]?.try(&.as_a?)
          biggest = photo.max_by? { |p| (p["width"]?.try(&.as_i) || 0) * (p["height"]?.try(&.as_i) || 0) }
          if b = biggest
            attachments << Attachment.new(:photo, b["file_id"].as_s,
              b["width"]?.try(&.as_i?), b["height"]?.try(&.as_i?))
          end
        end

        Message.new(
          msg["message_id"]?.try(&.to_s),
          from, chat, text,
          msg["caption"]?.try(&.as_s?),
          attachments, msg)
      end

      private def message_event(msg : JSON::Any) : Symbol?
        return :left_chat_member if msg["left_chat_member"]?
        nil
      end

      private def parse_participant(u : JSON::Any, platform : String) : Participant
        Participant.new(platform,
          u["id"]?.try(&.to_s) || "",
          u["username"]?.try(&.as_s?),
          (u["first_name"]?.try(&.as_s?)) || (u["title"]?.try(&.as_s?)))
      end

      private def parse_chat(c : JSON::Any) : Chat
        type = case t = c["type"]?.try(&.as_s?)
               when "private"    then :private
               when "group"      then :group
               when "supergroup" then :supergroup
               when "channel"    then :channel
               else                   :private
               end
        Chat.new(c["id"]?.try(&.to_s) || "", type, c["title"]?.try(&.as_s?))
      end

      private def empty_obj : JSON::Any
        JSON::Any.new({} of String => JSON::Any)
      end

      # --- Payload builders (pure — oracle-compared byte for byte) ---------

      # chat_id is numeric in the API when the id is a number.
      private def chat_id_value(chat_id : String) : JSON::Any
        chat_id.each_char.all?(&.ascii_number?) ? JSON::Any.new(chat_id.to_i64) : JSON::Any.new(chat_id)
      end

      def send_message_payload(msg : OutboundMessage) : String
        JSON.build do |j|
          j.object do
            j.field "chat_id", chat_id_value(msg.chat_id)
            j.field "text", msg.text || ""
            if rm = msg.reply_markup
              j.field "reply_markup", rm
            end
          end
        end
      end

      def edit_message_payload(chat_id : String, message_id : String, text : String) : String
        JSON.build do |j|
          j.object do
            j.field "chat_id", chat_id_value(chat_id)
            j.field "message_id", message_id.to_i64? || message_id
            j.field "text", text
          end
        end
      end

      def photo_payload(msg : OutboundMessage) : String
        JSON.build do |j|
          j.object do
            j.field "chat_id", chat_id_value(msg.chat_id)
            j.field "photo", msg.attachment_file_ids.first? || ""
            j.field "caption", msg.text || ""
          end
        end
      end

      # --- Delivery ----------------------------------------------------------

      def deliver(msg : OutboundMessage) : DeliveryReceipt
        method = msg.attachment_file_ids.empty? ? "sendMessage" : "sendPhoto"
        payload = msg.attachment_file_ids.empty? ? send_message_payload(msg) : photo_payload(msg)
        resp = api_call(method, payload)
        DeliveryReceipt.new(resp["result"]["message_id"]?.try(&.to_s), :delivered, resp)
      end

      # --- Streaming (progressive edits) -------------------------------------

      def start_stream(chat_id : String) : DeliveryReceipt
        receipt = deliver(OutboundMessage.new(chat_id, "…"))
        receipt.raw.raw.as(Hash(String, JSON::Any))["streamed"] = JSON::Any.new("")
        receipt.raw.raw.as(Hash(String, JSON::Any))["streamed_at"] =
          JSON::Any.new(Time.utc.to_unix_f)
        DeliveryReceipt.new(receipt.platform_message_id, :streaming, receipt.raw)
      end

      def append_stream(receipt : DeliveryReceipt, text_chunk : String) : Nil
        acc = receipt.raw.raw.as(Hash(String, JSON::Any))
        acc["streamed"] = JSON::Any.new((acc["streamed"]?.try(&.as_s) || "") + text_chunk)
        now = Time.utc.to_unix_f
        last = receipt.raw["streamed_at"].try(&.as_f) || now
        if now - last >= @min_edit_interval
          do_edit(receipt, acc["streamed"].as_s)
          acc["streamed_at"] = JSON::Any.new(now)
        end
      end

      def commit_stream(receipt : DeliveryReceipt, final_text : String) : Nil
        do_edit(receipt, final_text)
        receipt.raw.raw.as(Hash(String, JSON::Any))["streamed"] = JSON::Any.new(final_text)
      end

      private def do_edit(receipt : DeliveryReceipt, text : String) : Nil
        chat_id = extract_chat_id(receipt)
        api_call("editMessageText", edit_message_payload(chat_id, receipt.platform_message_id.to_s, text))
      end

      private def extract_chat_id(receipt : DeliveryReceipt) : String
        receipt.raw["result"]?.try(&.["chat"]?).try(&.["id"]?).try(&.to_s) || ""
      end

      # --- Webhook verification ----------------------------------------------

      def verify_webhook?(headers : HTTP::Headers, body : String) : Bool
        secret = @secret
        return true if secret.nil? || secret.empty? # not configured → open (dev)
        headers["X-Telegram-Bot-Api-Secret-Token"]? == secret
      end

      # --- API ----------------------------------------------------------------

      def api_call(method : String, payload : String) : JSON::Any
        response = HTTP::Client.post("#{@base}/bot#{URI.encode_path(@token)}/#{method}",
          headers: HTTP::Headers{"Content-Type" => "application/json"}, body: payload)
        JSON.parse(response.body)
      end

      def get_updates(offset : Int64, timeout : Int32 = 25) : Array(Update)
        payload = JSON.build do |j|
          j.object do
            j.field "offset", offset
            j.field "timeout", timeout
          end
        end
        resp = HTTP::Client.post("#{@base}/bot#{URI.encode_path(@token)}/getUpdates",
          headers: HTTP::Headers{"Content-Type" => "application/json"},
          body: payload)
        arr = resp.status.ok? ? JSON.parse(resp.body)["result"].as_a : [] of JSON::Any
        arr.map { |u| parse_update(u) }
      rescue IO::Error | Socket::Error
        [] of Update
      end
    end
  end
end
