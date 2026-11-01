# Changelog

## 0.5.0

- **Depth value**: after a full scan, CraftProfit reads the listings of your recipes' reagents and outputs
  and works out a depth value: the average price of the cheapest 20% of what is listed (at most 1,000 units).
  One cheap listing in front of a deep market no longer fakes the price. It shows in item tooltips and is
  the sale price with `/cf basis market`. The first depth scan reads up to 400 items (a few minutes, about
  0.4 s per item); later ones only re-read what is due, usually well under a minute.
- **Good price or not**: depth values are kept as a 14-day price history. Once an item has 3 days of it,
  tooltips show its normal price (median of the last 7 days) and whether today's price is cheap, normal or high.
  Reagent prices in the profession window turn green (cheap) or orange (high), and the profit panel's tooltip
  shows the craft at normal reagent prices.
- With a recipe open, reagents show their break-even price for that recipe (also listed in the profit panel's
  tooltip).
- Item tooltips keep only the value on the right (prices line up); details such as the listed count sit next
  to the label.
- `/cf demo history` invents a week of price history (session only) to preview the verdicts.
- `/cf depth` runs the depth scan on its own (or stops it); `/cf depth on|off` and an option control whether
  it follows every full scan. The scan button shows its progress. Items go stalest first and anything read in
  the last 2 hours (gear: 24 hours) is skipped, so stopping early loses nothing. The end message reports the time per item.
- Per-item Auction House searches for commodities (cloth, herbs, dust...) now get answers on WoW Forever: they
  are sent the way the default Auction House sends them.

## 0.4.1

- Item tooltips: the CraftProfit lines are shorter, so they no longer widen the tooltip (an item with no
  auctions used to push the equipped-item comparison to the other side of the screen).
- On enchanting recipes the profit panel no longer covers the **Enchant** slot where you pick the item
  to enchant; the panel now sits below it.

## 0.4.0

- **Vendor net**: the profit panel shows what a craft makes sold straight to a vendor (no cut, no scan
  needed). The **Vendor net** checkbox under the panel (or the Filter menu, or `/cf net vendor`) switches every
  recipe row and the sort to it. Also in the options ("Profit when selling to").
- **Profit at profession trainers**: every recipe a trainer teaches shows its profit; the tooltip adds the
  breakdown and how many crafts pay back the training cost. `/cf trainer` toggles it.
- The slash command is now `/cf` (`/cf scan`, `/cf status`, ...). The old `/cp` still works.

## 0.3.0 (first public release)

First public release of CraftProfit for WoW Forever.

- Every recipe in the profession window shows its profit after the Auction House cut.
- Sort recipes by profit, see reagent prices, and get a profit breakdown for the selected recipe.
- Reagents you can craft yourself are priced at their own craft cost when that is cheaper.
- Item tooltips show the auction price, its source and how old it is.
- Prices come from CraftProfit's own Auction House scan, or from Auctionator or TradeSkillMaster.
- Scans are shared between your characters.

Fixes since the beta test builds:

- Sort by profit updates the recipe list again, and turning it off restores Blizzard's order.
- `/cf reset confirm` also clears the prices shared between characters.
- A scan that stops early or returns nothing no longer wipes or skews your price data.
- Searching for one "... of the Bear" style variant no longer overwrites the price of the cheapest variant.
- Your settings are kept when saved data loads late on the beta client.

## 0.2.2

- Recipe row tags use the ScrollBox `OnInitializedFrame` event (build 69977 broke the old row hook).

## 0.2.1

- Item tooltip block with the auction price, its source and scan age.
- Price cache shared across characters; saved data kept in the console vault.

## 0.2.0

- Price ladders (Auction House depth), recorded purchases, extension API for other addons.

## 0.1.0

- Profit tags, reagent prices and the profit panel in the profession window; own AH scan, Auctionator and TSM.
