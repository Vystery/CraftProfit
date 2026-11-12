# CraftProfit

See what every recipe costs to craft and what it makes on the Auction House or sold to a vendor, right inside
the default profession window of **WoW Forever**. There is no extra window: recipe rows get a profit tag,
reagents get prices, the recipe details get a profit panel, and profession trainers show which recipes are
worth learning.

## Install

1. Download the release zip and extract it into `World of Warcraft\_forever_\Interface\AddOns\`, so you
   end up with `...\Interface\AddOns\CraftProfit\CraftProfit.toc`.
2. Start the game (or type `/reload` if it is already running) and make sure CraftProfit is enabled in the
   AddOns list on the character select screen.

## Getting started

1. Open the Auction House and click **CraftProfit Scan** (next to your money, bottom left). A full scan takes
   10 to 60 seconds. You can also type `/cf scan` while the Auction House is open. After the scan, CraftProfit
   reads the listings of your recipes' reagents and outputs (the depth scan, see below); the button shows its
   progress and stops it when clicked.
2. Open any profession. Every recipe now shows its net profit, and the selected recipe shows a full breakdown.

Already using **Auctionator** or **TradeSkillMaster**? CraftProfit reads their prices automatically, so you
can skip the scan. Pick a specific source in the options or with `/cf source`.

## What you see

- **Recipe list**: a profit tag on every row (`+12.4g`, `-35s`, green or red). Switch it to margin or both
  in the options or with `/cf tag`. `—` means a price is missing.
- **Reagents**: the line total under each reagent, plus the unit price for stacks. `*` marks a vendor price.
- **Profit panel**: total craft cost, expected sale price, vendor net, sold per day (estimated from your
  scans), and net profit after the Auction House cut. Hover it for a per-reagent breakdown.
- **Vendor net**: what a craft makes if you sell it straight to a vendor (vendor price × items per craft −
  craft cost, no cut). It needs no scan. To show it on every recipe row (and sort by it), tick **Vendor net**
  under the profit panel, pick it in the Filter menu, or type `/cf net vendor`.
- **Profession trainers**: every recipe the trainer offers shows its profit, so you can see which ones are
  worth learning first. Hover a recipe for the breakdown and how many crafts pay back the training cost.
  Turn it off with `/cf trainer`.
- **Sort by profit**: most profitable recipes first within each category. Toggle it in the profession
  window's Filter menu, the panel checkbox, or `/cf sort`.
- **Craft reagents I can make**: reagents you have a recipe for (Bolt of Woolen Cloth, for example) are
  priced at their own craft cost when that is cheaper than buying. This also works through chains, for
  example ore → bar → tube → finished item. Open each profession once so its recipes are known.
- **Shopping list**: click **Shop** in the profit panel to add the recipe (times the craft count next to
  Create; right-click takes it off). At the Auction House a panel beside it lists every reagent the list needs,
  how many you already have (bags, bank, and AH purchases still in the mail), and what the rest costs. **Search all** shows every reagent you
  still need in the Auction House results in one search, cheapest first; click a row to search just that item. `/cf shop` prints the list, `/cf shop clear` empties it.
- **Item tooltips**: the auction price CraftProfit uses for an item, where it comes from and how old it is.
  Items read by the depth scan also show their **depth value** (see below). Turn it off with `/cf tooltip`.
  Over a stack in your bags, hold **Shift** to see every price as the total for the whole stack.
- **Depth value**: the lowest buyout is easy to fake. One listing at 2s in front of 500 at 50s makes it 2s.
  The depth value is the average price of the cheapest 20% of what is listed (at most 1,000 units, at least
  5), so a single cheap listing barely moves it. It comes from the depth scan after each full scan, which reads
  the listings of every reagent and output of your learned recipes, stalest first (reagents read in the last 2
  hours, gear read in the last 24 hours and vendor reagents are skipped, so a run you stop early is picked up
  by the next one; an item with a single listing needs no search). Use it as the sale price with `/cf basis market`. Turn the depth scan off in
  the options or with `/cf depth off`; `/cf depth` runs it on its own.
- **Good price or not**: every depth value is kept as a daily price history (14 days). The **normal price** is
  the median of the last 7 days (today not counted); it needs 3 days of history, until then the tooltip says
  "learning". Today's price is then judged against it: **cheap** (10% or more under normal), **normal**, or
  **high** (10% or more over). You see it in item tooltips (`Normal` and `Now  cheap -12%`), as the color of
  each reagent's line total in the profession window (green cheap, orange high; judged for the quantity one
  craft needs, walking up the listings), and in the profit panel's tooltip, which also shows the craft's cost and
  net at normal reagent prices: is this craft good, or only good because of today's prices?
- **Break-even price**: with a recipe open, a reagent's tooltip and the profit panel's tooltip show the most
  that reagent may cost before the craft stops making a profit.
- **Vendor prices**: thread, vials, dyes and other vendor reagents are priced at the vendor price when that
  is cheaper. Prices are learned from every vendor you visit.

Net profit = sale price × items per craft − Auction House cut (5% by default) − craft cost.
Vendor net = vendor price × items per craft − craft cost.

## Commands

The older `/cp` still works for every command.

```
/cf                  list commands
/cf scan             scan the Auction House (it must be open), then run the depth scan
/cf depth [on|off]   run the depth scan now (or stop it); on/off: run it after every full scan
/cf status           price source, scan data and settings
/cf options          open the settings panel (also under Options > AddOns > CraftProfit)
/cf source <name>    auto | craftprofit | auctionator | tsm
/cf sort             toggle sort by profit
/cf tag <mode>       profit | margin | both
/cf net <basis>      ah | vendor: which profit tags, sorting and the panel lead with
/cf trainer          toggle profit tags at profession trainers (/cf trainer check lists the matches)
/cf craft            toggle pricing reagents at their own craft cost
/cf cut <percent>    Auction House cut used for net profit
/cf basis min|market sale price from your scans: lowest buyout, or market (depth value, else median of recent scans)
/cf tooltip          toggle the tooltip block
/cf shop [clear]     show (or empty) the AH shopping list
/cf share [import]   state of the old cross-character cache (import: merge it again)
/cf reset confirm    wipe all scan data and settings
```

## Price sources

| Source | Where prices come from |
|---|---|
| `auto` (default) | the first of Auctionator, TSM and your own scan that is installed and has data |
| `craftprofit` | your own full Auction House scan (lowest buyout, listed quantity, recent history) |
| `auctionator` | Auctionator's scan database (run a Full Scan in Auctionator) |
| `tsm` | TradeSkillMaster price sources (`DBMarket` etc. need TSM data for your realm) |

## Known limits

- WoW Forever's API can change with patches. If something breaks after a patch, please report it with the
  output of `/cf status`.
- Auctionator and TSM prices (including custom TSM price strings) have not been tested in game yet; the
  built-in scan is the tested source. If they look wrong, use `/cf source craftprofit` and report it.
- Sold per day counts every listing that disappeared between two scans, so expired and cancelled auctions
  count too. Treat it as an upper bound.
- Recipes whose output is not an item (enchants, for example) show cost only.
- The depth scan reads one item at a time and is limited by the Auction House's search throttle; the chat
  message at the end shows how long it took per item and where the time went. It reads at most 400 items per run.
- Trainer profit tags are new and not yet tested in game. If a trainer shows no tags, please report the output
  of `/cf trainer check` (with the trainer window open).

## For addon authors

CraftProfit exposes its namespace as the global `CraftProfit`. Useful entry points:
`CraftProfit:GetSalePrice(itemID)`, `CraftProfit:GetReagentCost(itemID)`,
`CraftProfit:GetReagentCostFor(itemID, quantity)` (walks captured Auction House depth),
`CraftProfit.Calc:Get(recipeID)` (cost, sale, net and margin for a recipe, plus `vendorNet`),
`CraftProfit.Calc:PickNet(eco)` (the net the user chose to see: AH, vendor or the better one), and
`CraftProfit.UI:SetOverride({ key, GetEco, ReagentCost, UpdateDetail })` to supply your own numbers in the
profession window. Events can be observed with `CraftProfit:On(event, fn)`, for example
`PRICES_UPDATED`, `SCAN_FINISHED`, `PURCHASE_RECORDED` and `UI_READY`.

## Help, bugs and ideas

Discord: https://discord.gg/hbJXz7qqpJ (#addon-help, #bug-reports, #suggestions).

## License

All rights reserved, see [LICENSE](LICENSE). Made by Vystery.
