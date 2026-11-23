# Tally: project summary (v1.0.0, formerly CraftProfit)

A gold ledger for WoW Forever. **Status: Beta.** Earlier builds (with the same ledger) loaded in game; 1.0.0 is the ledger-only build and still needs an in-game check.

## What it does
- Files every change in your gold under a category (see `ns.INCOME` / `ns.EXPENSE` in `Ledger.lua`).
- Summary: time played, net cash, gold per hour, net including looted items, looted items (vendor value), gold on hand, biggest AH buy, biggest AH sale.
- Income and expense bar charts; transactions / looted items / past sessions or by-day list.
- Ranges: session, today, 7 days, 30 days, all time; optional all characters.

## Forever-specific notes
- Interface 16001; modern client APIs (`C_AuctionHouse`, `C_MerchantFrame`, `C_Container`).
- WoW hides Lua errors by default, so Tally prints its own errors in chat.
- New addon code needs a full game restart, not `/reload`.

## Publishing (CurseForge)
- Listing name: `Tally – Gold ledger and profit tracker (WoW Forever)`.
- Upload file: `Tally-<version>-forever.zip` (built by the GitHub release workflow from a tag).
- Release type: Beta (tag `1.0.0-beta`) until confirmed in game, then Release.
- Logo: `Tally-logo-400.png` (original design, 400x400).

## Changes
- 1.0.0: stripped back to the ledger only. Removed crafting profits, shopping list, Sell tab, AH tabs and full scan, item tooltips. Looted items now valued at vendor price. "Listed on AH" box replaced by "Gold on hand". Old crafting/AH saved data cleaned out on load.
- 0.2–0.11 (pre-release): crafting profits, AH full scan, shopping list, Sell tab on the AH window, item tooltips, ledger with ranges, charts, biggest buy/sale. Donut charts replaced by bar charts because they looked blurry in game.
