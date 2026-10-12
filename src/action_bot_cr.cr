# ActionBot — bots and agents as first-class framework citizens.
# Unified message contract over messenger platforms (Telegram Bot API,
# WhatsApp Cloud API, web/SSE), designed so an LLM "brain" contract can
# attach later without touching the bot contract.

require "http"
require "json"
require "openssl"
require "active_support_cr"

require "./model"
require "./adapters/adapter"
require "./adapters/test_adapter"
require "./adapters/telegram"
require "./adapters/whatsapp"
require "./reply"
require "./base"
require "./webhook_handler"
require "./sse_handler"
require "./poller"

module ActionBot
  VERSION = "0.1.0"
end
