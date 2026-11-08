local fake = require("spec.support.sources")
local S = require("spec.workshop.support")

describe("Workshop UI", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, wns

    before_each(function()
        ns, wns = load_workshop({ before = function()
            WoWMock.recipes[100] = { name = "Potion", profession = "Alchemy", qualityItemIDs = { 501, 502 },
                schematic = { reagentSlotSchematics = {
                    { reagentType = 1, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 11 } } } } } }
            WoWMock.recipes[110] = { name = "Flask", profession = "Alchemy", qualityItemIDs = { 511, 512 },
                schematic = { reagentSlotSchematics = {} } }
            WoWMock.recipes[300] = { name = "Milling", profession = "Inscription", isSalvage = true,
                schematic = { quantityMax = 5, reagentSlotSchematics = {} } }
        end })
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:11"] = 100, ["i:501"] = 500, ["i:502"] = 900,
            ["i:512"] = 3000, ["i:511"] = 1000 } }))
    end)

    local function build()
        local tab = ns.UI.GetTab("workshop")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        return tab
    end

    it("registers the tab, the settings section and the dashboard tile", function()
        assert.is_table(ns.UI.GetTab("workshop"))
        local sections, widgets = {}, {}
        for _, s in ipairs(ns.UI.SortedSettings()) do sections[#sections + 1] = s.id end
        for _, w in ipairs(ns.UI.SortedWidgets()) do widgets[w.id] = true end
        assert.same({ "core", "pricing", "workshop" }, sections)
        assert.is_true(widgets["workshop.crafting"])
        assert.is_true(ns.UI.SortedSettings()[3].build(CreateFrame("Frame"), 0) > 60)
    end)

    it("lists the recipes in a sortable, searchable table; qualities expand", function()
        S.craft(100, {}, { { S.result({ id = 502, quality = 2 }) }, { S.result({ id = 501, quality = 1 }) } })
        S.craft(110, {}, { { S.result({ id = 512, quality = 2 }) } })
        wns.Lots.Sell("i:512", 1, 5000)
        local R = wns.WorkshopRecipes
        local recipes = wns.Stats.Recipes({})
        local rows = R.Rows(recipes, { sort = "profit" })
        assert.same({ 110, 100 }, { rows[1].recipe, rows[2].recipe })   -- Flask sold: highest profit first
        assert.is_true(rows[2].expandable)
        rows = R.Rows(recipes, { sort = "profit", reverse = true })
        assert.equals(100, rows[1].recipe)
        rows = R.Rows(recipes, { sort = "crafts" })
        assert.equals(100, rows[1].recipe)                              -- two crafts before one
        assert.equals(1, #R.Rows(recipes, { search = "flask" }))
        rows = R.Rows(recipes, { sort = "profit", expanded = { [100] = true } })
        assert.equals(4, #rows)
        assert.equals("quality", rows[3].kind)
        assert.equals(2, rows[3].quality)
        assert.is_nil(R.Margin({ soldCost = 0, profit = 5 }))
        assert.equals(50, R.Margin({ soldCost = 100, profit = 50 }))
    end)

    it("switches the views with the sub-tabs and opens recipe details in a dialog", function()
        S.craft(100, {}, { { S.result({ id = 502, quality = 2, conc = 20 }) }, { S.result({ id = 501, quality = 1 }) } })
        wns.Lots.Sell("i:502", 1, 2000)
        S.craft(300, {}, { { S.result({ id = 950 }) } }, { call = function()
            C_TradeSkillUI.CraftSalvage(300, 1, { itemID = 900 }, {})
        end })
        build()
        local UI = wns.WorkshopUI
        assert.equals("overview", UI.state.view)
        assert.is_true(UI.CurrentPage().frame:IsShown())
        for _, id in ipairs({ "recipes", "orders", "salvage", "overview" }) do
            UI.Show(id)
            assert.equals(id, UI.state.view)
            assert.is_true(UI.CurrentPage().frame:IsShown())
        end
        assert.equals("overview", GoblinomicsWorkshopDB.settings.view)
        UI.Show("recipes")
        assert.equals(1, #UI.CurrentPage().rows)
        UI.OpenRecipe(100)
        local page = UI.DetailPage()
        assert.equals(2, page.detail.crafts)
        assert.equals(3, #page.detail.history)
        UI.OpenRecipe(100, 2)
        assert.equals(1, page.detail.crafts)
        UI.state.profession = "Tailoring"
        UI.Refresh()
        assert.equals(0, #UI.CurrentPage().rows)
    end)

    it("opens crafting orders and salvaged items in a details dialog", function()
        S.craft(300, {}, { { S.result({ id = 950 }) } }, { call = function()
            C_TradeSkillUI.CraftSalvage(300, 1, { itemID = 900 }, {})
        end })
        build()
        local UI = wns.WorkshopUI
        local order = { id = 1, output = "i:502", name = "Potion", commission = 1000, rewards = 200, cost = 300,
            profit = 900, customer = "Bob", time = WoWMock.now, fulfilledAt = WoWMock.now, char = "xLN-Blackrock",
            profession = "Alchemy", status = "fulfilled" }
        UI.OpenOrder(order)
        local page = UI.OrderPage()
        assert.equals(order, page.order)
        assert.is_true(page.empty:IsShown())                        -- no craft record, no own reagents
        wns.Orders.ClearCost = function(o) o.cost, o.manual, o.profit = 0, true, 1200 end
        UI.OpenOrder(order)
        local salvage = wns.Salvage.Rows({})
        assert.equals(1, #salvage)
        UI.OpenSalvage(salvage[1])
        local sp = UI.SalvagePage()
        assert.equals(salvage[1], sp.data)
        assert.equals(1, #sp.yields)
        assert.equals("i:950", sp.yields[1].key)
    end)
end)

describe("Workshop UI on WoW: Forever (no crafting orders)", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, wns

    before_each(function()
        ns, wns = load_workshop({ client = "forever", before = function()
            WoWMock.recipes[100] = { name = "Potion", profession = "Alchemy", schematic = { reagentSlotSchematics = {} } }
        end })
    end)

    it("offers no crafting orders view and opens the overview for a saved orders view", function()
        local UI = wns.WorkshopUI
        local ids = {}
        for _, v in ipairs(UI.VIEWS) do ids[v.id] = true end
        assert.is_nil(ids.orders)
        assert.is_true(ids.overview and ids.recipes and ids.salvage and ids.professions)
        GoblinomicsWorkshopDB.settings.view = "orders"   -- saved on retail, same account
        local tab = ns.UI.GetTab("workshop")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        assert.equals("overview", UI.state.view)
        assert.is_true(UI.CurrentPage().frame:IsShown())
    end)

    it("leaves crafting orders out of the profit split, the chart and the dashboard card", function()
        local UI = wns.WorkshopUI
        local keys = {}
        for i, s in ipairs(UI.Sources()) do keys[i] = s.key end
        assert.same({ "sales", "salvage" }, keys)
        local text = UI.BreakdownText({ sales = 1000, orders = 0, salvage = 500, total = 1500 }, " | ")
        assert.truthy(text:find("Sold crafts", 1, true))
        assert.truthy(text:find("Salvage", 1, true))
        assert.is_nil(text:find("Crafting orders", 1, true))

        local tab = ns.UI.GetTab("workshop")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        local page = UI.CurrentPage()
        assert.truthy(page.legend:GetText():find("Salvage", 1, true))
        assert.is_nil(page.legend:GetText():find("Crafting orders", 1, true))
        assert.equals("No sales in this period.", page.chartEmpty.text:GetText())
        local _, lines = wns.WorkshopSummary.ChartTooltip({ day = WoWMock.now, total = 1500,
            values = { sales = 1000, orders = 0, salvage = 500 } })
        assert.equals(3, #lines)                                    -- sold crafts, salvage, total
        assert.is_nil(table.concat(lines, "\n"):find("Crafting orders", 1, true))

        local card
        for _, w in ipairs(ns.UI.SortedWidgets()) do if w.id == "workshop.crafting" then card = w end end
        local f = CreateFrame("Frame")
        card.build(f)
        card.refresh(f, {})
        assert.truthy(f.lines:GetText():find("Sold crafts", 1, true))
        assert.is_nil(f.lines:GetText():find("Crafting orders", 1, true))
    end)
end)
