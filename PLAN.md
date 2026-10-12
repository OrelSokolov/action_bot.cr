# action_bot.cr — ActionBot

Боты из коробки: единый контракт сообщений поверх мессенджер-платформ
(Telegram Bot API, WhatsApp Cloud API, web/SSE). Транспортный слой в
духе ActionMailer/ActionMailbox — ИИ-агенты (цикл/инструменты/Brain)
будут отдельным шардом ActiveAgent, подключаемым к ботам через
`reply.stream`. Не порт Rails-гема — дифференциатор (Iteration 16),
но oracle-first по AGENTS.md: фикстуры — реальные шейпы платформенных
API, эталон пейлоадов — `telegram-bot-ruby` / `whatsapp_sdk`
(oracle/cases.rb валидирует фикстуры настоящими гемами).

## Контракты (заморожены)

- `ActionBot::DeliveryAdapter` — `deliver(OutboundMessage) : DeliveryReceipt`
- `ActionBot::StreamingDelivery` (включает DeliveryAdapter) —
  `start_stream/append_stream/commit_stream` (progressive edits)
- `ActionBot::IngressAdapter` — `parse_update(JSON::Any) : Update`
- `ActionBot::WebhookVerification` — `verify_webhook?(headers, body)`
- Модель: `Participant/Chat/Attachment/Message/Update/OutboundMessage/DeliveryReceipt`
- Бот: `ActionBot::Base` — DSL `command/message/callback_query`,
  `reply` (ReplyBuilder), `deliver_now/deliver_later` (ActiveJob —
  опционально)

## Статус

- [x] P0 ядро-контракты + TestAdapter (2026-10-04): oracle 39 кейсов —
      фиксстуры Telegram валидируются настоящим telegram-bot-ruby 2.8.1
      (oracle/vendor), WhatsApp — по схеме Cloud API; исходящие пейлоады
      байт-в-байт с документированными телами API. 19/19 спеков.
- [x] Telegram-адаптер: parse_update (message/callback/photo/command/
      left_chat_member), sendMessage/sendPhoto, вебхук secret_token,
      getUpdates-поллер, стриминг editMessageText с троттлингом
      (TELEGRAM_STREAM_MIN_INTERVAL)
- [x] WhatsApp Cloud-адаптер: GET hub.challenge, X-Hub-Signature-256
      HMAC (constant-time), messages API (text)
- [x] SSE-стриминг `/bot/sse/:bot` (SseStreamAdapter: чанки →
      `data:`-события, финал → `event: done`) — тот же конвейер
      reply.stream, к которому будущий ActiveAgent (агенты) подключится
      без изменений
- [x] railties: `crails generate bot NAME --platform=…` (app/bots/,
      lib/action_bot_cr symlink, монтирование /bot/webhooks+sse в
      config/application.cr, config/bots.yml), `crails bot:poll`,
      `bin/app bot:poll` (boot-ветка через CRails.application.bot_poller —
      railties не зависит от шарда)
- [x] E2E-смоук crails new → generate bot → webhook: 403 без секрета /
      200 с секретом / 404 unknown bot / приложение живо; бот доставил
      sendMessage байт-в-байт с оракулом (tmp/agent_smoke)
- [ ] bench `bench/results/600-bots.md`
- [ ] P1: deliver_later через ActiveJob, conversation state, Slack
- [ ] P2 (внешний шард ActiveAgent, не здесь): контракт `Brain`
      (chat/stream_chat/tool-calls), цикл агента, `Tool`; мост —
      `reply.stream` ActionBot, бот-контракт не меняется

## Отклонения/решения

- Symbol-типизация Crystal: `Chat#type` — Symbol (:private/:group/:channel).
- Стриминг в чаты платформ — эмуляция edits (нативного стриминга нет
  ни у одной платформы); веб получает честный SSE.
- Токен Telegram содержит `:` — экранируется URI.encode_path в путях
  API-вызовов.
- Монтирование в приложении — префикс-матчинг
  (`starts_with?("/bot/webhooks")`), не exact-case: путь несёт
  :platform/:bot сегменты.
- dispatch(update) сбрасывает закешированный reply только при
  повторной диспетчеризации (инжектированный SSE-транспорт должен
  пережить первый dispatch).
