local fake = require("spec.support.sources")
local S = require("spec.workshop.support")

describe("Workshop: profit breakdown", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, wns

    before_each(function()
        ns, wns = load_workshop({ before = function()
            WoWMock.recipes[100] = { name = "Potion", profession = "Alchemy", schematic = { reagentSlotSchematics = {
                { reagentType = 1, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 11 } } } } } }
            WoWMock.recipes[300] = { name = "Milling", profession = "Inscription", isSalvage = true,
                schematic = { quantityMax = 5, reagentSlotSchematics = {} } }
        end })
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:11"] = 100, ["i:900"] = 200, ["i:951"] = 3000 } }))
        WoWMock.claimedOrder = { orderID = 5, customerName = "C", tipAmount = 10000, consortiumCut = 1000, reagents = {} }
    end)

    it("splits the realized profit into sold crafts, crafting orders and salvage", function()
        S.craft(100, {}, { { S.result({ id = 502 }) } })                                   -- cost 300
        wns.Lots.Sell("i:502", 1, 1300)                                                   -- +1,000
        S.craft(100, {}, { { S.result({ id = 502 }) } }, { orderID = 5 })                 -- cost 300
        WoWMock.fire("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", 0, 5)                       -- 9,000 - 300
        S.craft(300, {}, { { S.result({ id = 951 }) } }, { call = function()
            C_TradeSkillUI.CraftSalvage(300, 1, { itemID = 900 }, {})
        end })                                                                            -- cost 1,000
        wns.Lots.Sell("i:951", 1, 1500)                                                   -- +500
        local b = wns.Stats.Breakdown({})
        assert.equals(1000, b.sales)
        assert.equals(8700, b.orders)
        assert.equals(500, b.salvage)
        assert.equals(10200, b.total)
        local text = wns.WorkshopUI.BreakdownText(b, " | ")
        assert.truthy(text:find("Sold crafts", 1, true))
        assert.truthy(text:find("Crafting orders", 1, true))
        assert.truthy(text:find("Salvage", 1, true))
        local keys = {}
        for i, s in ipairs(wns.WorkshopUI.Sources()) do keys[i] = s.key end
        assert.same({ "sales", "orders", "salvage" }, keys)
        local title, lines = wns.WorkshopSummary.ChartTooltip({ day = WoWMock.now, total = b.total,
            values = { sales = b.sales, orders = b.orders, salvage = b.salvage } })
        assert.is_string(title)
        assert.equals(4, #lines)                                    -- three sources and the total
        assert.truthy(lines[2]:find("Crafting orders", 1, true))
    end)

    it("counts a sale in its own window even when the item was crafted earlier", function()
        S.craft(100, {}, { { S.result({ id = 502 }) } })
        WoWMock.advance(10 * 86400)
        wns.Lots.Sell("i:502", 1, 1300)
        local week = wns.Stats.Breakdown({ from = WoWMock.now - 7 * 86400 })
        assert.equals(1000, week.sales)
        local row = wns.Stats.Recipes({ from = WoWMock.now - 7 * 86400 })[1]
        assert.equals(0, row.crafts)
        assert.equals(1, row.sold)
        assert.equals(0, wns.Stats.Breakdown({ from = WoWMock.now - 7 * 86400, profession = "Tailoring" }).sales)
    end)

    it("leaves salvage out of the recipe rows and out of the sales", function()
        S.craft(300, {}, { { S.result({ id = 951 }) } }, { call = function()
            C_TradeSkillUI.CraftSalvage(300, 1, { itemID = 900 }, {})
        end })
        wns.Lots.Sell("i:951", 1, 1500)
        assert.equals(0, #wns.Stats.Recipes({}))
        assert.equals(0, wns.Stats.Breakdown({}).sales)
    end)
end)
