# ActionBot::Base — the bot base class. DSL mirrors the family style
# (ActionMailer's registry + end-of-program codegen):
#
#   class SupportBot < ActionBot::Base
#     adapter "telegram"
#     command "start" { |m| reply.text "Привет!" }
#     message { |m| reply.text "Вы сказали: #{m.text}" }
#     callback_query { |q| reply.text "Выбрано: #{q.data}" }
#   end
#
# Handlers are plain methods (aa_cmd__start / aa_message / aa_callback /
# aa_event__<name>); the module-level `finished` hook generates each
# subclass's `dispatch(update)` — no runtime reflection, compile-time
# dispatch only.

require "./reply"
require "./model"
require "./adapters/adapter"
require "./adapters/test_adapter"

module ActionBot
  class Base
    BOTS = [] of TypeNode

    macro inherited
      {% ActionBot::Base::BOTS << @type %}
    end

    # adapter "telegram" | "whatsapp" | "test"
    macro adapter(name)
      def self.__platform : String
        {{ name.id.stringify }}
      end

      def self.__adapter : ActionBot::DeliveryAdapter
        ActionBot.build_adapter({{ name.id.stringify }})
      end
    end

    def self.__platform : String
      "test"
    end

    def self.__adapter : ActionBot::DeliveryAdapter
      ActionBot.build_adapter("test")
    end

    # Bot name: SupportBot → "support" (webhook path segment).
    def self.bot_name : String
      n = name.split("::").last
      n = n[..-4] if n.ends_with?("Bot")
      n.underscore
    end

    getter update : Update?
    @reply : ReplyBuilder?

    def initialize(@update : Update? = nil)
    end

    def reply : ReplyBuilder
      @reply ||= begin
        u = @update.not_nil!
        chat_id = if u.kind == :message
                    u.message.not_nil!.chat.id
                  elsif u.kind == :callback_query
                    u.callback.not_nil!.chat.id
                  else
                    raise ArgumentError.new("No chat context for update kind #{u.kind}")
                  end
        ReplyBuilder.new(self.class.__adapter, chat_id)
      end
    end

    def dispatch(update : Update) : Nil
      # Drop a stale reply only on re-dispatch; a pre-injected reply
      # (SSE transport) on a fresh instance must survive.
      @reply = nil if @update
      @update = update
      dispatch
    end

    # Reply override for alternate transports (SSE injects its own
    # StreamingDelivery adapter instead of the platform one).
    def __reply_with(adapter : DeliveryAdapter, chat_id : String) : Nil
      @reply = ReplyBuilder.new(adapter, chat_id)
    end

    # Filled in per-subclass by the module-level finished hook.
    def dispatch : Nil
      raise NotImplementedError.new("#{self.class} has no handlers")
    end

    # --- handler registration macros -----------------------------------------

    macro command(name, &block)
      def aa_cmd__{{ name.id }}({{ block.args[0].id }} : ActionBot::Message)
        {{ block.body }}
        nil
      end
    end

    macro message(&block)
      def aa_message({{ block.args[0].id }} : ActionBot::Message)
        {{ block.body }}
        nil
      end
    end

    macro callback_query(&block)
      def aa_callback({{ block.args[0].id }} : ActionBot::CallbackQuery)
        {{ block.body }}
        nil
      end
    end

    macro event(name, &block)
      def aa_event__{{ name.id }}({{ block.args[0].id }} : ActionBot::Message)
        {{ block.body }}
        nil
      end
    end
  end

  # Adapter factory (token/config from ENV — config/bots.yml feeds it
  # via the app; TEST_* env vars point adapters at fake servers).
  def self.build_adapter(platform : String) : DeliveryAdapter
    case platform
    when "telegram" then Adapters::TelegramAdapter.new
    when "whatsapp" then Adapters::WhatsAppAdapter.new
    when "test"     then Adapters::TestAdapter.new
    else
      raise ArgumentError.new("Unknown adapter platform: #{platform}")
    end
  end

  # Bot lookup by name (webhook path / console).
  def self.lookup_bot(name : String)
    {% for bot in ActionBot::Base::BOTS %}
      return {{ bot.id }} if {{ bot.id }}.bot_name == name
    {% end %}
    nil
  end
end

require "./action_bot_cr"

# Per-bot dispatch generation (runs after all subclasses are defined —
# the same MAILERS-registry layout the ActionMailer port uses).
macro finished
  {% for bot in ActionBot::Base::BOTS %}
    class {{ bot.id }}
      def dispatch : Nil
        u = @update.not_nil!
        {% cmds = bot.methods.select { |meth| meth.name.stringify.starts_with?("aa_cmd__") } %}
        {% events = bot.methods.select { |meth| meth.name.stringify.starts_with?("aa_event__") } %}
        {% has_message = bot.methods.any? { |meth| meth.name.stringify == "aa_message" } %}
        if u.kind == :message
          m = u.message.not_nil!
          if ev = u.event
            {% for meth in events %}
              return {{ meth.name.id }}(m) if ev.to_s == {{ meth.name.stringify[10..] }}
            {% end %}
          end
          if cmd = m.command
            case cmd
            {% for meth in cmds %}
              when {{ meth.name.stringify[8..] }} then return {{ meth.name.id }}(m)
            {% end %}
            end
          end
          {% if has_message %} aa_message(m){% end %}
        elsif u.kind == :callback_query
          cq = u.callback.not_nil!
          {% if bot.methods.any? { |meth| meth.name.stringify == "aa_callback" } %}
            aa_callback(cq)
          {% end %}
        end
        nil
      end
    end
  {% end %}
end
