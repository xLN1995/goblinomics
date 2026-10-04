local fake = require("spec.support.sources")
local S = require("spec.workshop.support")

describe("Workshop: craft tracker and lots", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local wns

    before_each(function()
        local ns
        ns, wns = load_workshop({ before = function()
            WoWMock.recipes[100] = { name = "Potion", profession = "Alchemy", qualityItemIDs = { 501, 502 },
                schematic = { reagentSlotSchematics = {
                    { reagentType = 1, dataSlotIndex = 1, quantityRequired = 3, reagents = { { itemID = 11 } } } } } }
        end })
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:11"] = 100 } }))
    end)

    it("merges several events of one craft and counts resourcefulness once per operation", function()
        S.craft(100, {}, { {
            S.result({ id = 502, quality = 2, op = 900, returned = { { 11, 1 } } }),
            S.result({ id = 502, quality = 2, op = 900, qty = 1, returned = { { 11, 1 } } }),
        } })
        local r = GoblinomicsWorkshopDB.crafts[1]
        assert.equals(1, #GoblinomicsWorkshopDB.crafts)
        assert.equals(1, r.crafts)
        assert.same({ "i:502", 2, 2 }, r.outputs[1])
        assert.equals(300 - 100, r.cost)
    end)

    it("ignores results without a craft call and enchants on gear", function()
        WoWMock.fire("TRADE_SKILL_ITEM_CRAFTED_RESULT", S.result({ id = 502 }))
        WoWMock.advance(0.2)
        S.craft(100, {}, { { { isEnchant = true, quantity = 1, operationID = 5 } } }, { call = function()
            C_TradeSkillUI.CraftEnchant(100, 1, {}, {})
        end })
        assert.equals(0, #GoblinomicsWorkshopDB.crafts)
    end)

    it("takes the recipe of a recraft from the item GUID", function()
        WoWMock.recraftRecipes["Item-1"] = 100
        S.craft(100, {}, { { S.result({ id = 502, quality = 2 }) } }, { call = function()
            C_TradeSkillUI.RecraftRecipe("Item-1", {}, nil, false)
        end })
        assert.equals("recraft", GoblinomicsWorkshopDB.crafts[1].kind)
        assert.equals(100, GoblinomicsWorkshopDB.crafts[1].recipe)
    end)

    it("matches sales FIFO over characters and ignores items that were not crafted", function()
        S.craft(100, {}, { { S.result({ id = 502, quantity = 1 }) } })
        GoblinomicsWorkshopDB.lots[1].char = "Alt-Blackrock"
        WoWMock.advance(10)
        S.craft(100, {}, { { S.result({ id = 502, qty = 2 }) } })   -- 300 for 2 items
        assert.equals(2, wns.Lots.Sell("i:502", 2, 1000))
        local m = GoblinomicsWorkshopDB.matches
        assert.equals(300, m[1].cost)                 -- the older lot first
        assert.equals(150, m[2].cost)
        assert.equals(1, GoblinomicsWorkshopDB.lots[1].qty)
        assert.equals(0, wns.Lots.Sell("i:999", 1, 500))
    end)

    it("matches a sale with other bonus IDs after the exact variant", function()
        S.craft(100, {}, { { S.result({ id = 502, qty = 2 }) } })
        GoblinomicsWorkshopDB.lots[1].key = "i:502::2:10397:10398"
        WoWMock.advance(10)
        S.craft(100, {}, { { S.result({ id = 502 }) } })
        assert.equals(2, wns.Lots.Sell("i:502", 2, 1000))
        local m = GoblinomicsWorkshopDB.matches
        assert.equals(GoblinomicsWorkshopDB.crafts[2].id, m[1].craft)   -- exact key first
        assert.equals(GoblinomicsWorkshopDB.crafts[1].id, m[2].craft)
        assert.equals(1, GoblinomicsWorkshopDB.lots[1].qty)
    end)

    it("keeps old lots out of the open stock but matches late sales", function()
        S.craft(100, {}, { { S.result({ id = 502 }) } })
        WoWMock.advance(91 * 86400)
        assert.equals(0, #wns.Lots.Open())
        assert.equals(1, wns.Lots.Sell("i:502", 1, 900))
    end)
end)
