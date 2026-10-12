# ReplyBuilder — the `reply` object inside handler blocks (the analog
# of ActionMailer's `mail`): collects an OutboundMessage and delivers it
# through the bot's adapter. `text`/`photo` deliver now; `stream` pipes
# chunks through the adapter's StreamingDelivery capability.

module ActionBot
  class ReplyBuilder
    def initialize(@adapter : DeliveryAdapter, @chat_id : String)
    end

    def text(body : String) : DeliveryReceipt
      @adapter.deliver(OutboundMessage.new(@chat_id, body))
    end

    def photo(file_id : String, caption : String? = nil) : DeliveryReceipt
      @adapter.deliver(OutboundMessage.new(@chat_id, caption, [file_id]))
    end

    # reply.stream do |emit|          # emit.<<(chunk) repeatedly
    #   chunks.each { |c| emit << c }
    # end
    #
    # Falls back to buffering (single deliver) when the adapter has no
    # StreamingDelivery capability.
    def stream(& : Proc(String, Nil) -> Nil) : DeliveryReceipt
      full = String::Builder.new
      adapter = @adapter
      if adapter.is_a?(StreamingDelivery)
        receipt = adapter.start_stream(@chat_id)
        emitter = ->(chunk : String) { full << chunk; adapter.append_stream(receipt, chunk); nil }
        yield emitter
        adapter.commit_stream(receipt, full.to_s)
        receipt
      else
        emitter = ->(chunk : String) { full << chunk; nil }
        yield emitter
        @adapter.deliver(OutboundMessage.new(@chat_id, full.to_s))
      end
    end
  end
end
