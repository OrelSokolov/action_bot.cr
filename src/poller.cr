# Poller — long-poll transport for platforms without webhooks
# (Telegram getUpdates). Runs in the app binary's worker/scheduler role
# (`crails bot:poll telegram`); dispatches updates to every bot
# registered for the platform, in the same process — CRM models are
# directly reachable from handlers.

module ActionBot
  class Poller
    def initialize(@platform : String, @adapter : Adapters::TelegramAdapter,
                   @poll_interval : Time::Span = 25.seconds)
      @offset = ENV["TELEGRAM_UPDATE_OFFSET"]?.try(&.to_i64) || 0_i64
      @running = false
    end

    def self.for(platform : String) : Poller
      case platform
      when "telegram" then new("telegram", Adapters::TelegramAdapter.new)
      else
        raise ArgumentError.new("No polling transport for platform: #{platform}")
      end
    end

    def run : Nil
      @running = true
      while @running
        updates = @adapter.get_updates(@offset)
        updates.each do |update|
          if id = update.update_id
            @offset = id + 1
          end
          dispatch(update)
        end
        # A well-behaved long-poll server blocks for `timeout`, pacing
        # the loop; guard against instant-empty responses anyway.
        sleep(0.5.seconds) if updates.empty?
        Fiber.yield
      end
    end

    def stop : Nil
      @running = false
    end

    private def dispatch(update : Update) : Nil
      {% for bot in ActionBot::Base::BOTS %}
        if {{ bot.id }}.__platform == @platform
          {{ bot.id }}.new.dispatch(update)
        end
      {% end %}
    end
  end
end
