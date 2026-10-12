# Oracle spec: the Crystal port must reproduce oracle/expected.yml
# exactly (captured via oracle/cases.rb with the real telegram-bot-ruby
# 2.8.1 validating every Telegram fixture + documented Cloud API
# shapes). Same case IDs, no edits; values use the \n/\t escape
# protocol of the other shards.

require "spec"
require "../src/action_bot_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

def escape(s : String) : String
  s.gsub("\\", "\\\\\\\\").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

def check(id, value)
  (EXPECTED[id]? || "MISSING #{id}").should eq escape(value.to_s)
end

FIX = "#{__DIR__}/../oracle/fixtures"

def tg_update(name) : ActionBot::Update
  adapter = ActionBot::Adapters::TelegramAdapter.new
  adapter.parse_update(JSON.parse(File.read("#{FIX}/telegram/#{name}")))
end

def wa_update(name) : ActionBot::Update
  adapter = ActionBot::Adapters::WhatsAppAdapter.new
  adapter.parse_update(JSON.parse(File.read("#{FIX}/whatsapp/#{name}")))
end

def wa_from(u : ActionBot::Update) : String
  p = u.message.not_nil!.from
  "#{p.id}:#{p.name}"
end

describe "ActionBot oracle" do
  # --- Telegram inbound -----------------------------------------------------

  it "tg01 text message" do
    u = tg_update("01_text_message.json")
    m = u.message.not_nil!
    check "tg01_kind", u.kind
    check "tg01_update_id", u.update_id
    check "tg01_msg_id", m.id
    check "tg01_from", m.from
    check "tg01_chat", m.chat
    check "tg01_text", m.text
    check "tg01_command", m.command || "-"
  end

  it "tg02 command" do
    u = tg_update("02_command_start.json")
    m = u.message.not_nil!
    check "tg02_kind", u.kind
    check "tg02_chat", m.chat
    check "tg02_command", m.command
    check "tg02_text", m.text
  end

  it "tg03 photo" do
    u = tg_update("03_photo_message.json")
    m = u.message.not_nil!
    check "tg03_kind", u.kind
    check "tg03_text", m.text || "-"
    check "tg03_attachments", m.attachments.size
    check "tg03_attachment_0", m.attachments[0]
    check "tg03_caption", m.caption
  end

  it "tg04 callback query" do
    u = tg_update("04_callback_query.json")
    cq = u.callback.not_nil!
    check "tg04_kind", u.kind
    check "tg04_from", cq.from
    check "tg04_chat", cq.chat
    check "tg04_data", cq.data
  end

  it "tg05 left chat member" do
    u = tg_update("05_left_chat_member.json")
    m = u.message.not_nil!
    check "tg05_kind", u.kind
    check "tg05_event", u.event
    raw_member = m.raw["left_chat_member"]
    member = ActionBot::Participant.new("telegram",
      raw_member["id"].to_s,
      raw_member["username"]?.try(&.as_s?),
      raw_member["first_name"]?.try(&.as_s?))
    check "tg05_member", member
  end

  # --- Telegram outbound payloads -------------------------------------------

  it "tg outbound payloads" do
    adapter = ActionBot::Adapters::TelegramAdapter.new
    msg = ActionBot::OutboundMessage.new("424242", "Вы сказали: привет")
    check "out_tg_send_message", adapter.send_message_payload(msg)
    check "out_tg_edit_message", adapter.edit_message_payload("424242", "5001", "Вы сказали: привет (v2)")
    keyboard = JSON.parse(%({"inline_keyboard":[[{"text":"Тариф Pro","callback_data":"tariff:pro"},{"text":"Тариф Max","callback_data":"tariff:max"}]]}))
    check "out_tg_reply_markup", keyboard.to_json
    check "out_tg_secret_header", "X-Telegram-Bot-Api-Secret-Token"
  end

  # --- WhatsApp inbound -----------------------------------------------------

  it "wa01 text message" do
    u = wa_update("01_text_message.json")
    m = u.message.not_nil!
    check "wa01_kind", u.kind
    check "wa01_from", wa_from(u)
    check "wa01_phone_number_id", u.account_id
    check "wa01_text", m.text
    check "wa01_wamid", m.id
  end

  it "wa02 button reply" do
    u = wa_update("02_button_reply.json")
    m = u.message.not_nil!
    check "wa02_kind", u.kind
    check "wa02_text", m.text
    check "wa02_payload", m.raw["button"]["payload"]
  end

  it "wa03 status" do
    u = wa_update("03_status_read.json")
    check "wa03_kind", u.kind
    check "wa03_status", u.status
    check "wa03_recipient", u.raw["recipient_id"]
  end

  # --- WhatsApp outbound ----------------------------------------------------

  it "wa outbound payload" do
    adapter = ActionBot::Adapters::WhatsAppAdapter.new
    msg = ActionBot::OutboundMessage.new("79001234567", "Ответ поддержки")
    check "out_wa_send_message", adapter.message_payload(msg)
    check "out_wa_signature_header", "X-Hub-Signature-256"
  end
end
