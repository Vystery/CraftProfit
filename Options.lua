-- CraftProfit :: Options
-- Settings panel (Options > AddOns > CraftProfit) built on the retail Settings API.

local _, CP = ...
local Options = {}
CP.Options = Options

local function Proxy(category, key, varType, label, default, onSet)
	return Settings.RegisterProxySetting(category, "CraftProfit_" .. key, varType, label, default,
		function() return CP.settings[key] end,
		function(value)
			CP.settings[key] = value
			CP.touched[key] = true
			if onSet then onSet(value) end
			CP:Fire("SETTINGS_CHANGED", key, value)
		end)
end

function Options:Setup()
	if self.category then return end
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterProxySetting) then
		CP:Debug("Settings API not available; options panel disabled")
		return
	end

	local ok, err = pcall(function()
		local category = Settings.RegisterVerticalLayoutCategory("CraftProfit")
		self.category = category

		-- Price source
		local source = Proxy(category, "source", Settings.VarType.String, "Price source", CP.defaults.source)
		Settings.CreateDropdown(category, source, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("auto", "Automatic (Auctionator, TSM, then own scan)")
			for _, def in ipairs(CP.Sources.list) do
				local suffix = def:IsAvailable() and "" or "  (not installed)"
				container:Add(def.key, def.name .. suffix)
			end
			return container:GetData()
		end, "Where CraftProfit reads auction prices from. Automatic picks the first installed source that has data.")

		local basis = Proxy(category, "saleBasis", Settings.VarType.String, "Sale price basis (own scan)", CP.defaults.saleBasis)
		Settings.CreateDropdown(category, basis, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("min", "Lowest current buyout")
			container:Add("market", "Market value (depth, else median of recent scans)")
			return container:GetData()
		end, "Which price from your own scans counts as the expected sale price.")

		-- AH cut slider (stored as fraction, shown as percent)
		local cut = Settings.RegisterProxySetting(category, "CraftProfit_ahCut", Settings.VarType.Number,
			"Auction house cut", math.floor(CP.defaults.ahCut * 100 + 0.5),
			function() return math.floor((CP.settings.ahCut or 0) * 100 + 0.5) end,
			function(value)
				CP.settings.ahCut = (tonumber(value) or 0) / 100
				CP.touched.ahCut = true
				CP:Fire("SETTINGS_CHANGED", "ahCut", CP.settings.ahCut)
			end)
		local sliderOptions = Settings.CreateSliderOptions(0, 15, 1)
		sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
			return string.format("%d%%", value)
		end)
		Settings.CreateSlider(category, cut, sliderOptions, "Percentage the Auction House keeps from a sale. Retail uses 5%.")

		-- Toggles
		local rows = Proxy(category, "showRowTags", Settings.VarType.Boolean, "Profit tags in the recipe list", CP.defaults.showRowTags)
		Settings.CreateCheckbox(category, rows, "Show a profit tag on every recipe row.")

		local tag = Proxy(category, "rowTag", Settings.VarType.String, "Recipe row tag shows", CP.defaults.rowTag)
		Settings.CreateDropdown(category, tag, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("profit", "Net profit (e.g. +12.4g)")
			container:Add("margin", "Margin (e.g. +27%)")
			container:Add("both", "Profit and margin (less room for names)")
			return container:GetData()
		end, "Rows are narrow; the compact profit leaves the most room for recipe names. Full numbers are always in the details panel.")

		local net = Proxy(category, "netBasis", Settings.VarType.String, "Profit when selling to", CP.defaults.netBasis)
		Settings.CreateDropdown(category, net, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("ah", "Auction House (after the cut)")
			container:Add("vendor", "Vendor (sell price, no scan needed)")
			return container:GetData()
		end, "Which profit the recipe tags, the sort and the details panel lead with. The panel always shows the other one too.")

		local trainer = Proxy(category, "trainerTags", Settings.VarType.Boolean, "Profit tags at profession trainers", CP.defaults.trainerTags)
		Settings.CreateCheckbox(category, trainer, "Show each recipe's profit in the trainer window, so you can see which recipes are worth learning first. The tooltip adds the breakdown and how many crafts pay back the training cost.")

		local reagents = Proxy(category, "showReagentPrices", Settings.VarType.Boolean, "Reagent prices in recipe details", CP.defaults.showReagentPrices)
		Settings.CreateCheckbox(category, reagents, "Show unit price and line total under each reagent.")

		local panel = Proxy(category, "showPanel", Settings.VarType.Boolean, "Profit panel in recipe details", CP.defaults.showPanel)
		Settings.CreateCheckbox(category, panel, "Show the profit breakdown (Auction House and vendor) for the selected recipe.")

		local sort = Proxy(category, "sortByProfit", Settings.VarType.Boolean, "Sort recipes by profit", CP.defaults.sortByProfit,
			function(value) CP.UI:SetSortByProfit(value) end)
		Settings.CreateCheckbox(category, sort, "Within each category, list the most profitable recipes first.")

		local profitable = Proxy(category, "profitableOnly", Settings.VarType.Boolean, "Only show profitable crafts", CP.defaults.profitableOnly,
			function(value) CP.UI:SetProfitableOnly(value) end)
		Settings.CreateCheckbox(category, profitable, "Show only recipes that make a profit: hides losses, break-even and unknown profit (missing prices).")

		local craft = Proxy(category, "craftIntermediates", Settings.VarType.Boolean, "Craft reagents I can make", CP.defaults.craftIntermediates)
		Settings.CreateCheckbox(category, craft, "Price reagents you have a learned recipe for (e.g. Bolt of Woolen Cloth) at their own craft cost instead of the auction price. Open each profession once per session so its recipes are known.")

		local cheaper = Proxy(category, "craftOnlyWhenCheaper", Settings.VarType.Boolean, "Craft reagents only when cheaper", CP.defaults.craftOnlyWhenCheaper)
		Settings.CreateCheckbox(category, cheaper, "With the option above: keep the buy price when buying the reagent is cheaper than crafting it. Turn off to always assume you craft it (skill-ups).")

		local vendor = Proxy(category, "useVendorWhenCheaper", Settings.VarType.Boolean, "Use vendor price when cheaper", CP.defaults.useVendorWhenCheaper)
		Settings.CreateCheckbox(category, vendor, "Reagents sold by vendors (thread, vials, dye) cost the vendor price if it is lower than the auction price.")

		local scanButton = Proxy(category, "scanButton", Settings.VarType.Boolean, "Scan button in the Auction House", CP.defaults.scanButton)
		Settings.CreateCheckbox(category, scanButton, "Show the CraftProfit Scan button next to the money display in the Auction House.")

		local depthScan = Proxy(category, "depthScan", Settings.VarType.Boolean, "Depth scan after a full scan", CP.defaults.depthScan)
		Settings.CreateCheckbox(category, depthScan, "After a full scan, read the listings of every reagent and output of your learned recipes, so one cheap listing cannot fake the market price. /cf depth runs it on its own.")

		local tooltip = Proxy(category, "tooltip", Settings.VarType.Boolean, "Price block in item tooltips", CP.defaults.tooltip)
		Settings.CreateCheckbox(category, tooltip, "Add the auction price, its source and the scan age (or why there is no price) to every item tooltip.")

		local debug = Proxy(category, "debug", Settings.VarType.Boolean, "Debug output", CP.defaults.debug)
		Settings.CreateCheckbox(category, debug, "Print diagnostic messages to chat.")

		Settings.RegisterAddOnCategory(category)
	end)

	if not ok then
		self.category = nil
		CP:Debug("options panel failed: %s", tostring(err))
	end
end

function Options:Open()
	if not self.category then self:Setup() end
	if self.category and Settings and Settings.OpenToCategory then
		Settings.OpenToCategory(self.category:GetID())
	else
		CP:Print("options panel unavailable on this client; use /cf commands instead.")
	end
end

CP:RegisterEvent("PLAYER_LOGIN", function() Options:Setup() end)
