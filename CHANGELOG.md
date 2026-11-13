# Changelog

## Unreleased

- **Ungroup recipes**: Filter menu / options / `/cf ungroup` drops category headers and shows one flat
  list sorted by profit, so the best craft is at the top instead of buried under Everyday Meals / Stamina Food.

## 0.5.2

- Shopping list: when you open the Auction House buy page for a reagent the list still needs, the quantity is
  filled in with how many you are missing. Items that are sold one per auction have no quantity box and are
  left as they are.
- Fixed: buying one item from a grouped Auction House row (for example 1 of 860 Copper Rods) counted the whole
  row as bought. CraftProfit now records what you paid for, so the shopping list shows 1 in the mail.
- The shopping list's button on the Auction House is now a small **Shop** button, so it no longer covers the
  AH's own bid and buyout boxes.

## 0.5.1

- **Profitable only**: a Filter menu / options / `/cf profit` toggle that hides recipes whose craft
  profit is negative, zero or unknown (a missing price). Empty categories are removed from the list.
- **Shopping list**: **Shop** in the profit panel adds the selected recipe, times the craft count next to
  Create (right-click takes it off). At the Auction House a panel beside the window lists every reagent you
  still need after what's in your bags and bank, with the cost at the scanned prices. What you buy at the AH
  counts right away as "in the mail" until you collect it. **Search all** puts every missing reagent into the
  Auction House results in one search; click an item to search just that one. Vendor reagents are listed but
  not searched. The list is shared by all your characters. `/cf shop` and `/cf shop clear`.
- Hold **Shift** over a stack in your bags and the tooltip shows every price for the whole stack (20 Light
  Leather: the auction price for all 20). Without Shift it shows the price per item and a "Stack of 20" hint.
- Item tooltips no longer show the CraftProfit block on items that can't go to the Auction House: quest
  items, bind-on-pickup items, and anything already Soulbound or Warbound (for example a BoE you equipped).
- The profit panel no longer overlaps other addons in the recipe details. It now goes below whatever is
  actually under the reagents (ForeverRecipes' Difficulty and Source rows, Auctionator's reagent total) and
  follows ForeverRecipes' two-per-row reagent layout. When space is tight it shrinks to the Net profit row.
- Fixed "shared price cache could not be written (push FAILED ...)" after every scan on some clients. Prices
  reach your other characters through the normal saved data again, so CraftProfit no longer writes its old
  extra copy into the game's console settings (CVars). Nothing is lost when updating: whatever that old copy
  still holds is merged in once at login (only prices newer than your own; nothing of yours is overwritten).
- `/cf share` shows whether that old copy was imported; `/cf share import` merges it again.

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
