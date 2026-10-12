# action_bot.cr

Bots as first-class framework citizens: a unified message contract over
messenger platforms (Telegram Bot API, WhatsApp Cloud API, web/SSE) —
**an original CRails component, not a port**: Rails has no bot
framework, so there is no Ruby original to mirror. The transport layer
follows the ActionMailer/ActionMailbox idiom (`ActionBot::Base` DSL +
adapters); the AI-agent loop (Brain/Tools) is deliberately left to a
separate ActiveAgent shard that plugs in via `reply.stream` without
touching the bot contract. Built oracle-first per the project rules:
Telegram inbound fixtures are validated by the real telegram-bot-ruby
2.8.1 (vendored in `oracle/vendor`), WhatsApp fixtures follow the Cloud
API webhook schema (whatsapp_sdk field layout), and outbound payloads
are byte-identical to the documented API request bodies. Suite: **39
oracle cases + 9 integration specs (19/19)**.

> ⚠️ EXPERIMENTAL FRAMEWORK, DO NOT USE IN PRODUCTION YET.

## Installation

```yaml
dependencies:
  action_bot_cr:
    github: OrelSokolov/action_bot.cr
```

```sh
shards install
```

Depends on `active_support.cr` and `active_job.cr`.

## Usage

```crystal
class SupportBot < ActionBot::Base
  adapter "telegram"
  command "start" { |m| reply.text "Hi!" }
  message { |m| reply.text "You said: #{m.text}" }
  callback_query { |q| reply.text "Selected: #{q.data}" }
end

# dispatch a normalized Update (from webhook, poller or specs)
SupportBot.new.dispatch(update)

# streaming replies (editMessageText on Telegram, real SSE on web)
reply.stream do |emit|
  chunks.each { |c| emit << c }
end
```

Adapters are configured via ENV (`TELEGRAM_BOT_TOKEN`,
`TELEGRAM_SECRET_TOKEN`, `WHATSAPP_ACCESS_TOKEN`,
`WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_APP_SECRET`,
`WHATSAPP_VERIFY_TOKEN`; `*_API_BASE` / `TEST_*` vars point them at
fakes). HTTP endpoints come with the shard: `POST /bot/webhooks/:platform/:bot`
(secret-checked, WhatsApp `hub.challenge` GET) and `GET /bot/sse/:bot`
(chunks → `data:` events, final → `event: done`). Railties provide
`crails generate bot NAME --platform=…`, `config/bots.yml` and
`crails bot:poll` (getUpdates poller).

## Feature comparison

Rails has no bot framework, so the table compares with the de-facto
Ruby stack this shard replaces: telegram-bot-ruby 2.8.1 + whatsapp_sdk
+ a hand-rolled webhook controller.

### Core contract

| Feature | Usual stack (telegram-bot-ruby + whatsapp_sdk) | action_bot.cr | Status |
|---|---|---|---|
| Unified delivery port `deliver(OutboundMessage) → DeliveryReceipt` | one adapter per platform, no shared contract | `DeliveryAdapter` module-interface | ✅ |
| Unified ingress `parse_update(JSON::Any) → Update` | per-gem types (Telegram::Bot::Types, whatsapp_sdk) | `IngressAdapter`, normalized `Update`/`Message`/`Chat`/`Participant` | ✅ |
| Bot DSL `command`/`message`/`callback_query`/`event` | roll your own dispatcher | `ActionBot::Base`, compile-time dispatch | ✅ |
| `reply` builder (text/photo/stream) | API calls inline in handlers | `ReplyBuilder` over any adapter | ✅ |
| Streaming replies in chat | n/a (no platform streams natively) | `StreamingDelivery`: progressive edits on Telegram (throttled ~1 edit/s), honest SSE on web | ✅ (emulated via edits) |
| Webhook authenticity | per-platform middleware | `WebhookVerification`: Telegram secret_token, WhatsApp X-Hub-Signature-256 HMAC (constant-time) | ✅ |
| Testing without network | mock the gem's HTTP client | `TestAdapter` records deliveries (ActiveJob :test-adapter pattern) | ✅ |

### Platforms

| Feature | telegram-bot-ruby 2.8.1 / whatsapp_sdk | action_bot.cr | Status |
|---|---|---|---|
| Telegram: message/command/photo/callback/left_chat_member parsing, sendMessage/sendPhoto | ✅ | Same, fixtures validated by the real gem | ✅ |
| Telegram: getUpdates poller | manual loop | `crails bot:poll` / poller | ✅ |
| WhatsApp: text messages API, hub.challenge, HMAC webhooks | ✅ | Same | ✅ |
| WhatsApp: media/interactive/template sends | ✅ | Text only | ⚠️ partial |
| Slack (or other platforms) | separate gems | not implemented (P1) | ❌ |
| `deliver_later` via ActiveJob | n/a | not implemented (P1) | ❌ |
| Conversation state (contexts, flows) | gems like telegram-bot-ruby's sessions | not implemented (P1) | ❌ |
| AI-agent loop (`Brain`, tools, chat/stream_chat) | e.g. ruby-openai by hand | separate ActiveAgent shard (P2), bridges via `reply.stream` | ❌ (by design) |

### Railties / E2E

| Feature | Usual stack | action_bot.cr | Status |
|---|---|---|---|
| Generator (`app/bots/`, adapter wiring, route mounting, `config/bots.yml`) | hand-rolled | `crails generate bot NAME --platform=…` | ✅ |
| Webhook + SSE mounting under `/bot/…` | routes by hand | auto-mounted (prefix-matched) | ✅ |
| E2E smoke (`crails new` → generate → webhook 403/200/404, byte-exact sendMessage) | — | verified (tmp/agent_smoke) | ✅ |
| 600-bots benchmark | — | planned (`bench/results/600-bots.md`) | ❌ |

## Deviations & Crystal-specific notes

- Symbol typing: `Chat#type` is a Symbol (`:private`/`:group`/`:channel`).
- Streaming into platform chats is emulated with progressive message
  edits — no messenger streams natively; the web side gets real SSE
  from the same `reply.stream` pipeline.
- The Telegram token contains `:` and is escaped with `URI.encode_path`
  in API-call paths.
- App mounting uses prefix matching (`starts_with?("/bot/webhooks")`),
  not exact routes: the path carries `:platform`/`:bot` segments.
- `dispatch(update)` resets a cached `reply` only on re-dispatch, so a
  pre-injected transport (SSE) survives the first dispatch.
- Contracts are frozen module-interfaces (deliver/stream/parse/verify)
  — additive evolution only.

Full details: `PLAN.md` (Russian).

## Testing

```sh
crystal spec   # self-contained: fake HTTP servers, no PostgreSQL/Redis needed
```

Oracle: 39 cases recorded with the real telegram-bot-ruby 2.8.1
(`oracle/cases.rb` → `oracle/expected.yml`; Telegram fixtures parsed by
the vendored gem, WhatsApp checked against the Cloud API schema); the
Crystal specs replay them 1:1 without edits, plus 9 integration specs
(webhooks, SSE, poller, byte-exact outbound payloads).
