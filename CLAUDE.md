# Tally

Shared WoW Forever rules: ../CLAUDE.md (if present locally).

A gold ledger only: income and expenses by category, net profit/loss, time
ranges, all characters. Crafting profits and AH selling were built and then
removed on purpose (Auctionator does it better) — don't add them back.

## Files
- `Tally.toc`, `Core.lua` (event bus, error reporting, helpers, settings,
  slash commands), `Ledger.lua` (classifying gold changes, sessions, daily
  totals, saved log, range queries), `UI.lua` (the one window: summary boxes,
  bar charts, transactions / looted items / history list).
- `Tally-summary.md` — design notes and a per-version change log. Add a
  `Changes` entry for every version.

## SavedVariables `TallyDB`
- `settings`: scale (1.1), ledgerRange (session|today|week|month|all), ledgerAll.
- `ledger[Name-Realm]`: current session, history (last 20 sessions),
  days[YYYY-MM-DD] (income/expense per category, items, played, big buy/sale),
  log (last 2,000 entries, newest first).

## Behaviour to keep
- Gold changes are filed by a hint from a hook first (repair, AH post, AH buy,
  sold-mail invoice, quest turn-in, flight), then by the most recently opened
  window, else "Other income/spending".
- Charts are plain rectangles in whole pixels (no rotated/dotted shapes: they
  looked blurry in game).
- Every event handler runs in pcall; errors print once in chat as
  "Tally error" and go to the game's error handler.

## Slash: `/tally` — toggle; today/week/month/all/session, reset, scale, debug.
