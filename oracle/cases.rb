#!/usr/bin/env ruby
# Oracle cases for ActionBot (Iteration 16).
#
# Run against the ORIGINAL reference stack:
#   GEM_PATH=oracle/vendor/gems ruby oracle/cases.rb > oracle/expected.yml
#
# Each line: "<case_id>\t<value>". The same case IDs are mirrored 1:1 in
# spec/oracle_spec.cr; the Crystal port must reproduce expected.yml exactly.
#
# Sources of truth (AGENTS.md, oracle-first):
#   * Telegram inbound fixtures are parsed with the real telegram-bot-ruby
#     2.8.1 (vendored via `gem install --install-dir oracle/vendor`), so the
#     fixtures are guaranteed to be well-formed Bot API updates and the
#     extracted fields are cross-checked against the gem's own types.
#   * Outbound payload shapes are the documented Bot API / WhatsApp Cloud
#     API request bodies (the gem passes them through verbatim).
#   * WhatsApp fixtures are validated structurally against the Cloud API
#     webhook schema (whatsapp_sdk field layout).
#
# Normalization contract under test (the ActionBot unified model):
#   Update#kind   : message | callback_query | ...
#   Message event : message.text / message.command (from bot_command entity)
#   Participant   : "<id>:<username|->:<name|->" (platform ids are Strings)
#   Chat          : "<id>:<type>:<title|->"

require "json"

gem "telegram-bot-ruby", "= 2.8.1"
require "telegram/bot"

FIX = File.expand_path("fixtures", __dir__)

def case_run(id, value)
  puts "#{id}\t#{value}"
end

def participant(u)
  "#{u.id}:#{u.username || '-'}:#{u.first_name || '-'}"
end

def chat_string(c)
  "#{c.id}:#{c.type}:#{c.title || '-'}"
end

def load_update(name)
  Telegram::Bot::Types::Update.new(
    JSON.parse(File.read(File.join(FIX, "telegram", name))))
end

# --- Telegram inbound (validated by the real gem) --------------------------

u = load_update("01_text_message.json")
m = u.message
raise "tg01 fixture invalid" if m.nil? || m.from.nil? || m.text != "Привет, бот!"
case_run "tg01_kind", "message"
case_run "tg01_update_id", u.update_id
case_run "tg01_msg_id", m.message_id
case_run "tg01_from", participant(m.from)
case_run "tg01_chat", chat_string(m.chat)
case_run "tg01_text", m.text
case_run "tg01_command", "-"

u = load_update("02_command_start.json")
m = u.message
cmd = m.entities.to_a.find { |e| e.type == "bot_command" }
raise "tg02 fixture invalid" if cmd.nil? || m.text != "/start"
case_run "tg02_kind", "message"
case_run "tg02_chat", chat_string(m.chat)
case_run "tg02_command", m.text[1..].split(" ").first
case_run "tg02_text", m.text

u = load_update("03_photo_message.json")
m = u.message
big = m.photo.max_by { |p| p.width * p.height }
raise "tg03 fixture invalid" if big.nil? || m.caption != "чек на оплату"
case_run "tg03_kind", "message"
case_run "tg03_text", "-"
case_run "tg03_attachments", "1"
case_run "tg03_attachment_0", "photo:#{big.file_id}:#{big.width}x#{big.height}"
case_run "tg03_caption", m.caption

u = load_update("04_callback_query.json")
cq = u.callback_query
raise "tg04 fixture invalid" if cq.nil? || cq.message.nil?
case_run "tg04_kind", "callback_query"
case_run "tg04_from", participant(cq.from)
case_run "tg04_chat", chat_string(cq.message.chat)
case_run "tg04_data", cq.data

u = load_update("05_left_chat_member.json")
m = u.message
raise "tg05 fixture invalid" if m.left_chat_member.nil?
case_run "tg05_kind", "message"
case_run "tg05_event", "left_chat_member"
case_run "tg05_member", participant(m.left_chat_member)

# --- Telegram outbound (documented Bot API request bodies) -----------------

send_message = {chat_id: 424242, text: "Вы сказали: привет"}.to_json
case_run "out_tg_send_message", send_message
edit_message = {chat_id: 424242, message_id: 5001,
                text: "Вы сказали: привет (v2)"}.to_json
case_run "out_tg_edit_message", edit_message
keyboard = {inline_keyboard: [[{text: "Тариф Pro", callback_data: "tariff:pro"},
                              {text: "Тариф Max", callback_data: "tariff:max"}]]}
case_run "out_tg_reply_markup", keyboard.to_json
case_run "out_tg_secret_header", "X-Telegram-Bot-Api-Secret-Token"

# --- WhatsApp inbound (Cloud API webhook schema) ----------------------------

def load_wa(name)
  JSON.parse(File.read(File.join(FIX, "whatsapp", name)))
end

wa = load_wa("01_text_message.json")
v = wa["entry"][0]["changes"][0]["value"]
msg = v["messages"][0]
contact = v["contacts"][0]
raise "wa01 fixture invalid" if msg["type"] != "text"
case_run "wa01_kind", "message"
case_run "wa01_from", "#{msg['from']}:#{contact['profile']['name']}"
case_run "wa01_phone_number_id", v["metadata"]["phone_number_id"]
case_run "wa01_text", msg["text"]["body"]
case_run "wa01_wamid", msg["id"]

wa = load_wa("02_button_reply.json")
msg = wa["entry"][0]["changes"][0]["value"]["messages"][0]
raise "wa02 fixture invalid" if msg["type"] != "button"
case_run "wa02_kind", "button"
case_run "wa02_text", msg["button"]["text"]
case_run "wa02_payload", msg["button"]["payload"]

wa = load_wa("03_status_read.json")
st = wa["entry"][0]["changes"][0]["value"]["statuses"][0]
raise "wa03 fixture invalid" if st["status"] != "read"
case_run "wa03_kind", "status"
case_run "wa03_status", st["status"]
case_run "wa03_recipient", st["recipient_id"]

# --- WhatsApp outbound (Cloud API messages request body) --------------------

out_wa = {messaging_product: "whatsapp", to: "79001234567", type: "text",
          text: {body: "Ответ поддержки"}}.to_json
case_run "out_wa_send_message", out_wa
case_run "out_wa_signature_header", "X-Hub-Signature-256"
