# Changelog

## 0.5.12

This version does not fix the "CraftProfit has been blocked" error some players get when using an item from
their bags. It makes the error much easier to report, so it can be found.

- New: `/cf blocked` opens a window with the records as text you can copy (Ctrl+C) and paste into a report, so
  nothing has to be typed off the chat.
- New: each record now also says what the game was running when it blocked the action (the call stack).
- If you get the error, please type `/cf blocked` and send what the window shows. A `/reload` clears the error
  until it happens again.

## 0.5.11

- Fixed: prices seemed to be gone (no prices in tooltips, `/cf status` showing "on Unknown") when the game
  did not give CraftProfit a realm name. Your saved prices were still there; CraftProfit was looking in an
  empty set. It now picks your prices from ruleset and faction alone (for example `Normal-Horde`). Anything
  you scanned while it said "Unknown" is merged in the next time you log in.
- Fixed: a Lua error (`VendorPrices.lua:54: attempt to compare number with table`) when a saved vendor price
  was not a plain number. Such an entry is now ignored until you visit a vendor that sells the item.

## 0.5.10

- Changed: holding Shift over a stack (per-item prices / stack totals) now only rewrites CraftProfit's own
  tooltip lines instead of asking the game to rebuild the whole tooltip. The rebuild is the likely cause of
  the "CraftProfit tried to call the protected function SetPreferredGamepadInteractTarget()" error reported
  when opening a gamepad radial. The tooltip looks the same as before.
- If the game still blocks an action and names CraftProfit, please send what `/cf blocked` prints.

## 0.5.9

- Fixed: "Use vendor price when cheaper" ignored the built-in vendor prices whenever an Auction House price
  existed, so a reagent you had not yet seen at a vendor cost its AH price (Weak Flux 2s 15c instead of 1s).
  Built-in prices now win when cheaper, the same as prices learned at a vendor. Learned prices are still per
  unit (bundles divided by their size) and skip limited-stock and token-cost items.

## 0.5.8

- Fixed: Salt showed a vendor price of 5c; it costs 50c. The built-in vendor prices (used until you open a
  vendor that sells the item) no longer beat Auction House prices, so a wrong one can no longer hide the price
  from Auctionator, TSM or your own scan. Prices learned at a vendor still win when they are cheaper.
- Fixed: the built-in Empty Vial price is now per vial (4c; the vendor sells 5 for 20c).
- Fixed: vendor prices for items sold in bundles are no longer rounded to whole copper (7c for 5 is 1.4c each,
  not 1c).

## 0.5.7

- Fixed: on recipes with many reagents (most tailoring recipes: five to eight reagents in two columns) the
  profit panel dropped its Sort by profit / Craft reagents / Vendor net checkboxes, and the CraftProfit window
  next to the profession window never opened. Now the panel stays in the recipe pane only when all of it fits;
  otherwise the whole panel opens in the CraftProfit window (below or right of the profession window, see
  `/cf dock`). The one-line "net profit + Shop" strip is gone.

## 0.5.6

- Fixed: the CraftProfit Scan button in the Auction House sat on top of AuctionMaster's "Full Scan" button and
  its status text. When another addon has a button right of the money display, CraftProfit's button now goes
  to the right of it.

## 0.5.5

- Fixed: prices and price history are now kept per ruleset and per faction. Before, a scan on your Alliance
  character also showed on your Horde character of the same ruleset (and the other way round). Prices you
  already have are kept: each character's old prices go to its ruleset and faction the first time you log in
  with it. Scan once on your other faction to fill its prices.
- Fixed: characters of the same ruleset and faction now always share prices. The game gives some characters a
  different internal server name, and CraftProfit used to keep a separate set of prices for each name.
  `/cf status` shows which set a character uses, for example `Normal-Horde`.

## 0.5.4

- Fixed: a Lua error (`bad argument #1 to 'UnitPlayerControlled'`) when pressing or releasing Shift over a
  player or NPC after hovering a stack in your bags. Shift now re-draws the tooltip only while it shows an
  item, and the remembered stack is dropped as soon as the tooltip changes or hides.
- Recipes that make no item (most enchants) no longer get a "—" tag in the recipe list, so their names are
  not cut short for it.
- New: when the game blocks an action and names CraftProfit (the "blocked from an action only available to the
  Blizzard UI" popup), CraftProfit says so in chat and notes what was on screen. `/cf blocked` prints the
  notes; please include them when you report the popup.

## 0.5.3

- Fixed: **Sold per day** was blank when the price source was Auctionator (for example on "auto" with
  Auctionator installed). Prices still come from Auctionator; sold per day now comes from CraftProfit's own
  scan history, and the profit panel tooltip says so.
- Fixed: on recipes with a long description and many reagents (enchants with an "Enchant" target slot in
  particular) the profit panel could cover Track Recipe and the Create/Enchant button. It now never goes below
  Track Recipe. When space is short it becomes one line (net profit and Shop; the rest is in its tooltip).
  When there is no room at all it opens in its own CraftProfit window next to the profession window, drawn
  with the profession window's own border and background.
- New option **Profit panel when there is no room** (also `/cf dock below | right`): that window goes below the
  profession window or to its right, for small screens. If the chosen side would leave the screen, the other
  one is used.
- The profit panel now looks like the recipe pane's own sections ("Reagents:", "Optional Target:"): a gold
  "Profit (Auction House):" label and plain rows, no box. When space is short, the stat rows stay and the
  checkboxes go first. The header drops the price source's name when it does not fit next to Shop (the
  tooltip still names it).
- Reagent prices now sit to the right of the reagent name, lined up with the profit panel, when the reagents
  are in one column. With a second column of reagents (five or more, or ForeverRecipes' two per row) they stay
  under the name, and a long reagent name is cut at two lines (the full name is in its tooltip) so the price
  never covers the name.
- Fixed: help and usage lines such as `/cf net ah|vendor` or `/cf source auto|craftprofit|...` lost
  characters in chat (a "|" starts a chat color code). They now read `/cf net ah | vendor`.

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
