# Unified, platform-neutral message model. Every adapter normalizes its
# platform payload into these types; handlers and CRM code never see
# platform shapes. Frozen contract — fields are additive-only.

module ActionBot
  class Participant
    getter platform : String # "telegram" | "whatsapp" | ...
    getter id : String       # platform ids are Strings everywhere
    getter username : String?
    getter name : String?

    def initialize(@platform, @id, @username = nil, @name = nil)
    end

    # Rendering used by the oracle protocol: "<id>:<username|->:<name|->".
    def to_s : String
      "#{@id}:#{@username || "-"}:#{@name || "-"}"
    end
  end

  class Chat
    getter id : String
    getter type : Symbol # :private | :group | :supergroup | :channel
    getter title : String?

    def initialize(@id, @type, @title = nil)
    end

    def to_s : String # oracle protocol: "<id>:<type>:<title|->"
      "#{@id}:#{@type}:#{@title || "-"}"
    end
  end

  class Attachment
    getter kind : Symbol # :photo | :document | :video | ...
    getter file_id : String
    getter width : Int32?
    getter height : Int32?

    def initialize(@kind, @file_id, @width = nil, @height = nil)
    end

    def to_s : String # oracle protocol: "<kind>:<file_id>:<WxH|->"
      dims = {@width, @height}.any?(&.nil?) ? "-" : "#{@width}x#{@height}"
      "#{@kind}:#{@file_id}:#{dims}"
    end
  end

  class Message
    getter id : String?              # platform message id (tg message_id, wa wamid)
    getter from : Participant
    getter chat : Chat
    getter text : String?
    getter caption : String?
    getter attachments : Array(Attachment)
    getter raw : JSON::Any

    def initialize(@id, @from, @chat, @text = nil, @caption = nil,
                   @attachments = [] of Attachment, @raw = JSON::Any.new({} of String => JSON::Any))
    end

    # "/start" (with a bot_command entity) → "start"; nil otherwise.
    def command : String?
      entities = @raw["entities"]?.try(&.as_a?) || [] of JSON::Any
      return nil unless entities.any? { |e| e["type"]?.try(&.as_s?) == "bot_command" }
      text = @text
      return nil if text.nil? || text.empty? || text[0] != '/'
      text[1..].split(" ").first?
    end
  end

  class CallbackQuery
    getter id : String
    getter from : Participant
    getter chat : Chat
    getter data : String?
    getter raw : JSON::Any

    def initialize(@id, @from, @chat, @data, @raw)
    end
  end

  # A normalized platform event.
  class Update
    getter kind : Symbol # :message | :callback_query | :status
    getter update_id : Int64? # telegram sequential id (offset for getUpdates)
    getter account_id : String? # whatsapp phone_number_id (routing/outbound)
    getter message : Message?
    getter callback : CallbackQuery?
    getter status : String? # whatsapp delivery status: sent|delivered|read|failed
    getter event : Symbol?  # sub-event of a message: :left_chat_member, ...
    getter raw : JSON::Any

    def initialize(@kind, @update_id = nil, @account_id = nil, @message = nil,
                   @callback = nil, @status = nil, @event = nil,
                   @raw = JSON::Any.new({} of String => JSON::Any))
    end

    def message? : Bool
      @kind == :message
    end

    def callback_query? : Bool
      @kind == :callback_query
    end

    def status_update? : Bool
      @kind == :status
    end
  end

  # --- Outbound -------------------------------------------------------------

  class OutboundMessage
    getter chat_id : String
    getter text : String?
    getter attachment_file_ids : Array(String)
    getter reply_markup : JSON::Any?

    def initialize(@chat_id, @text = nil,
                   @attachment_file_ids = [] of String, @reply_markup = nil)
    end
  end

  class DeliveryReceipt
    getter platform_message_id : String?
    getter status : Symbol # :delivered | :streaming
    getter raw : JSON::Any

    def initialize(@platform_message_id, @status, @raw)
    end
  end
end
