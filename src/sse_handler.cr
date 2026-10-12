# SseHandler — honest chunked streaming for web clients
# (`GET /bot/sse/:bot?chat_id=...&text=...`). The same handler-block
# pipeline as platform bots, but the reply's StreamingDelivery
# capability writes SSE events (`data: <chunk>` → final `event: done`)
# instead of platform message edits. Brain (P2) plugs into the exact
# same reply.stream pipeline.

require "./reply"

module ActionBot
  class SseStreamAdapter
    include StreamingDelivery

    def initialize(@io : IO)
    end

    def deliver(msg : OutboundMessage) : DeliveryReceipt
      @io << "data: " << (msg.text || "") << "\n\n"
      @io.flush
      DeliveryReceipt.new("sse", :delivered, JSON::Any.new({} of String => JSON::Any))
    end

    def start_stream(chat_id : String) : DeliveryReceipt
      DeliveryReceipt.new("sse-#{chat_id}", :streaming, JSON::Any.new({} of String => JSON::Any))
    end

    def append_stream(receipt : DeliveryReceipt, text_chunk : String) : Nil
      @io << "data: " << text_chunk << "\n\n"
      @io.flush
    end

    def commit_stream(receipt : DeliveryReceipt, final_text : String) : Nil
      @io << "event: done\ndata: " << final_text << "\n\n"
      @io.flush
    end
  end

  class SseHandler
    include HTTP::Handler

    MOUNT_PATH = "/bot/sse"

    def call(context : HTTP::Server::Context)
      path = context.request.path
      unless path.starts_with?(MOUNT_PATH)
        call_next(context)
        return
      end

      segments = path.split("/").reject(&.empty?)
      if segments.size < 3
        context.response.status = :not_found
        return
      end
      bot_name = segments[2]
      bot = ActionBot.lookup_bot(bot_name)
      if bot.nil?
        context.response.status = :not_found
        return
      end

      params = URI::Params.parse(context.request.resource)
      chat_id = params["chat_id"]? || "web"
      text = params["text"]? || ""

      context.response.content_type = "text/event-stream"
      context.response.headers["Cache-Control"] = "no-cache"
      context.response.headers["X-Accel-Buffering"] = "no"

      io = context.response
      adapter = SseStreamAdapter.new(io)
      from = Participant.new("web", chat_id)
      chat = Chat.new(chat_id, :private)
      update = Update.new(:message, message: Message.new(nil, from, chat, text))

      instance = bot.new
      instance.__reply_with(adapter, chat_id)
      instance.dispatch(update)
    end
  end

  class_property sse_handler = SseHandler.new
end
