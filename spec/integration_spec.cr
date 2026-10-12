# Integration specs — the full pipelines against fake platform API
# servers (the smtp_spec pattern): DSL dispatch (TestAdapter), Telegram
# delivery + progressive-edit streaming, webhook ingress for both
# platforms, WhatsApp HMAC verification + challenge, SSE streaming.

require "spec"
require "../src/action_bot_cr"

# --- fake platform API server -----------------------------------------------

class FakeApiServer
  getter requests = [] of {String, String, HTTP::Headers}
  @server : HTTP::Server

  def initialize(&@handler : HTTP::Server::Context -> Nil)
    @server = HTTP::Server.new do |context|
      body = context.request.body.try(&.gets_to_end) || ""
      @requests << {context.request.path.not_nil!, body, context.request.headers}
      @handler.call(context)
    end
    @server.bind_unused_port
    spawn { @server.listen }
    20.times { sleep(10.milliseconds); break if @server.listening? }
  end

  def port : Int32
    @server.addresses.first.as?(Socket::IPAddress).try(&.port) || raise "not bound"
  end

  def base : String
    "http://127.0.0.1:#{port}"
  end

  def requests_for(path_part : String) : Array({String, String, HTTP::Headers})
    @requests.select { |p, _, _| p.includes?(path_part) }
  end

  def bodies_for(method : String) : Array(String)
    @requests.select { |p, _, _| p.includes?("/#{method}") }.map { |_, b, _| b }
  end

  def close : Nil
    @server.close
  end
end

def wait_for(timeout = 2.seconds, &) : Bool
  deadline = Time.utc + timeout
  while Time.utc < deadline
    return true if yield
    sleep(10.milliseconds)
  end
  false
end

# --- bots --------------------------------------------------------------------

class EchoBot < ActionBot::Base
  adapter "test"

  command "start" do |m|
    reply.text "Привет! Я бот поддержки."
  end

  message do |m|
    reply.text "Вы сказали: #{m.text}"
  end

  callback_query do |q|
    reply.text "Выбрано: #{q.data}"
  end

  event :left_chat_member do |m|
    reply.text "#{m.raw["left_chat_member"]["first_name"]} покинул чат"
  end
end

class StreamBot < ActionBot::Base
  adapter "test"

  message do |m|
    reply.stream do |emit|
      emit.call("Гене")
      emit.call("рация ")
      emit.call("по чанкам")
    end
  end
end

class PollerBot < ActionBot::Base
  adapter "telegram"

  message do |m|
    ActionBot::Adapters::TestAdapter.deliveries << ActionBot::OutboundMessage.new(m.chat.id, "polled: #{m.text}")
  end
end

describe "ActionBot integration" do
  before_each { ActionBot::Adapters::TestAdapter.reset }

  # --- DSL dispatch --------------------------------------------------------

  it "dispatches command / message / callback / event" do
    adapter = ActionBot::Adapters::TelegramAdapter.new
    bot = EchoBot.new

    u = adapter.parse_update(JSON.parse(File.read("#{__DIR__}/../oracle/fixtures/telegram/02_command_start.json")))
    bot.dispatch(u)
    ActionBot::Adapters::TestAdapter.last_text.should eq "Привет! Я бот поддержки."

    ActionBot::Adapters::TestAdapter.reset
    u = adapter.parse_update(JSON.parse(File.read("#{__DIR__}/../oracle/fixtures/telegram/01_text_message.json")))
    bot.dispatch(u)
    ActionBot::Adapters::TestAdapter.last_text.should eq "Вы сказали: Привет, бот!"

    ActionBot::Adapters::TestAdapter.reset
    u = adapter.parse_update(JSON.parse(File.read("#{__DIR__}/../oracle/fixtures/telegram/04_callback_query.json")))
    bot.dispatch(u)
    ActionBot::Adapters::TestAdapter.last_text.should eq "Выбрано: tariff:pro"

    ActionBot::Adapters::TestAdapter.reset
    u = adapter.parse_update(JSON.parse(File.read("#{__DIR__}/../oracle/fixtures/telegram/05_left_chat_member.json")))
    bot.dispatch(u)
    ActionBot::Adapters::TestAdapter.last_text.should eq "Ivan покинул чат"
  end

  it "folds streamed chunks into one TestAdapter delivery" do
    adapter = ActionBot::Adapters::TelegramAdapter.new
    u = adapter.parse_update(JSON.parse(File.read("#{__DIR__}/../oracle/fixtures/telegram/01_text_message.json")))
    StreamBot.new.dispatch(u)
    ActionBot::Adapters::TestAdapter.last_text.should eq "Генерация по чанкам"
  end

  # --- Telegram delivery + streaming against a fake API ---------------------

  it "delivers sendMessage byte-exactly and streams via editMessageText" do
    server = FakeApiServer.new do |context|
      context.response.content_type = "application/json"
      if context.request.path.not_nil!.includes?("editMessageText")
        context.response.print({ok: true, result: true}.to_json)
      else
        context.response.print({ok: true, result: {message_id: 9001, chat: {id: 424242}}}.to_json)
      end
    end

    ENV["TELEGRAM_BOT_TOKEN"] = "T1:token"
    ENV["TELEGRAM_API_BASE"] = server.base
    ENV["TELEGRAM_STREAM_MIN_INTERVAL"] = "0"

    tg_adapter = ActionBot::Adapters::TelegramAdapter.new
    receipt = tg_adapter.deliver(ActionBot::OutboundMessage.new("424242", "Вы сказали: привет"))
    receipt.platform_message_id.should eq "9001"
    server.bodies_for("sendMessage").should eq [%({"chat_id":424242,"text":"Вы сказали: привет"})]

    # streaming: start → edits per chunk (min interval 0) → commit
    r = tg_adapter.start_stream("424242")
    tg_adapter.append_stream(r, "Гене")
    tg_adapter.append_stream(r, "рация")
    tg_adapter.commit_stream(r, "Генерация готова")
    edits = server.bodies_for("editMessageText")
    edits.size.should eq 3
    edits[0].should eq %({"chat_id":424242,"message_id":9001,"text":"Гене"})
    edits[1].should eq %({"chat_id":424242,"message_id":9001,"text":"Генерация"})
    edits[2].should eq %({"chat_id":424242,"message_id":9001,"text":"Генерация готова"})

    server.close
    ENV.delete("TELEGRAM_API_BASE")
    ENV.delete("TELEGRAM_STREAM_MIN_INTERVAL")
  end

  it "verifies the Telegram webhook secret" do
    ENV["TELEGRAM_SECRET_TOKEN"] = "s3cret"
    adapter = ActionBot::Adapters::TelegramAdapter.new
    headers = HTTP::Headers{"X-Telegram-Bot-Api-Secret-Token" => "s3cret"}
    adapter.verify_webhook?(headers, "{}").should be_true
    bad = HTTP::Headers{"X-Telegram-Bot-Api-Secret-Token" => "nope"}
    adapter.verify_webhook?(bad, "{}").should be_false
    ENV.delete("TELEGRAM_SECRET_TOKEN")
  end

  # --- webhook ingress -------------------------------------------------------

  it "serves POST /bot/webhooks/:platform/:bot (fiber dispatch → 200)" do
    handler = ActionBot.webhook_handler
    payload = %({"kind":"message","chat_id":"424242","text":"Привет, бот!"})

    io = IO::Memory.new
    request = HTTP::Request.new("POST", "/bot/webhooks/test/echo", body: payload)
    context = HTTP::Server::Context.new(request, HTTP::Server::Response.new(io))
    handler.call(context)
    context.response.status.ok?.should be_true

    wait_for { !ActionBot::Adapters::TestAdapter.deliveries.empty? }.should be_true
    ActionBot::Adapters::TestAdapter.last_text.should eq "Вы сказали: Привет, бот!"

    # unknown bot → 404
    io2 = IO::Memory.new
    context2 = HTTP::Server::Context.new(
      HTTP::Request.new("POST", "/bot/webhooks/test/nope", body: payload),
      HTTP::Server::Response.new(io2))
    handler.call(context2)
    context2.response.status.not_found?.should be_true
  end

  # --- WhatsApp verification + delivery --------------------------------------

  it "verifies X-Hub-Signature-256 and answers hub.challenge" do
    ENV["WHATSAPP_APP_SECRET"] = "appsecret"
    adapter = ActionBot::Adapters::WhatsAppAdapter.new
    body = %({"object":"whatsapp_business_account"})
    sig = "sha256=" + OpenSSL::HMAC.hexdigest(OpenSSL::Algorithm::SHA256, "appsecret", body)
    adapter.verify_webhook?(HTTP::Headers{"X-Hub-Signature-256" => sig}, body).should be_true
    adapter.verify_webhook?(HTTP::Headers{"X-Hub-Signature-256" => "sha256=deadbeef"}, body).should be_false

    ENV["WHATSAPP_VERIFY_TOKEN"] = "vtok"
    adapter = ActionBot::Adapters::WhatsAppAdapter.new
    params = HTTP::Params.new({"hub.mode" => ["subscribe"], "hub.verify_token" => ["vtok"], "hub.challenge" => ["1157854215"]})
    adapter.webhook_challenge(params).should eq "1157854215"
    bad = HTTP::Params.new({"hub.mode" => ["subscribe"], "hub.verify_token" => ["wrong"], "hub.challenge" => ["x"]})
    adapter.webhook_challenge(bad).should be_nil
    ENV.delete("WHATSAPP_APP_SECRET")
    ENV.delete("WHATSAPP_VERIFY_TOKEN")
  end

  it "delivers WhatsApp messages with the documented body" do
    server = FakeApiServer.new do |context|
      context.response.content_type = "application/json"
      context.response.print({messages: [{id: "wamid.out.1"}]}.to_json)
    end
    ENV["WHATSAPP_ACCESS_TOKEN"] = "EAtoken"
    ENV["WHATSAPP_PHONE_NUMBER_ID"] = "222222222222222"
    ENV["WHATSAPP_API_BASE"] = server.base

    adapter = ActionBot::Adapters::WhatsAppAdapter.new
    receipt = adapter.deliver(ActionBot::OutboundMessage.new("79001234567", "Ответ поддержки"))
    receipt.platform_message_id.should eq "wamid.out.1"
    req = server.requests.first
    req[0].should contain("/v21.0/222222222222222/messages")
    req[1].should eq %({"messaging_product":"whatsapp","to":"79001234567","type":"text","text":{"body":"Ответ поддержки"}})
    req[2]["Authorization"].should eq "Bearer EAtoken"

    server.close
    ENV.delete("WHATSAPP_API_BASE")
    ENV.delete("WHATSAPP_PHONE_NUMBER_ID")
    ENV.delete("WHATSAPP_ACCESS_TOKEN")
  end

  # --- SSE streaming ----------------------------------------------------------

  it "streams reply chunks as SSE events" do
    handler = ActionBot.sse_handler
    io = IO::Memory.new
    request = HTTP::Request.new("GET", "/bot/sse/stream?chat_id=web1&text=hi")
    response = HTTP::Server::Response.new(io)
    context = HTTP::Server::Context.new(request, response)
    handler.call(context)
    response.close

    io.rewind
    body = io.to_s
    body.should contain("data: Гене\n\n")
    body.should contain("data: рация \n\n")
    body.should contain("data: по чанкам\n\n")
    body.should contain("event: done\ndata: Генерация по чанкам\n\n")
    context.response.content_type.should eq "text/event-stream"
  end

  # --- poller ------------------------------------------------------------------

  it "polls getUpdates and dispatches to platform bots" do
    fixture = File.read("#{__DIR__}/../oracle/fixtures/telegram/01_text_message.json")
    served = false
    server = FakeApiServer.new do |context|
      context.response.content_type = "application/json"
      if context.request.path.not_nil!.includes?("getUpdates") && !served
        served = true
        context.response.print(%({"ok":true,"result":[#{fixture}]}))
      else
        context.response.print(%({"ok":true,"result":[]}))
      end
    end
    ENV["TELEGRAM_BOT_TOKEN"] = "T2:token"
    ENV["TELEGRAM_API_BASE"] = server.base
    ENV["TELEGRAM_SECRET_TOKEN"] = ""
    # Route the update to the telegram-platform PollerBot (top level).
    poller = ActionBot::Poller.for("telegram")
    spawn { poller.run }
    wait_for { !ActionBot::Adapters::TestAdapter.deliveries.empty? }.should be_true
    ActionBot::Adapters::TestAdapter.last_text.should eq "polled: Привет, бот!"
    poller.stop
    server.close
    ENV.delete("TELEGRAM_API_BASE")
  end
end
