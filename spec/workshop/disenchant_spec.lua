local fake = require("spec.support.sources")
local S = require("spec.workshop.support")

-- Disenchanting as salvage: the item from the bag use before the cast (or the
-- bag change after it), the yield from the disenchant loot.
describe("Workshop: disenchanting", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, wns
    local DE = 13262
    local BAG = S.link(222, "Weavercloth Bag")

    before_each(function()
        ns, wns = load_workshop()
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:222"] = 1500, ["i:950"] = 400, ["i:951"] = 2000 } }))
        WoWMock.bags[0] = { numSlots = 4, [1] = { itemID = 222, hyperlink = BAG, stackCount = 1 } }
    end)

    local function loot(id, qty, kind)
        ns.Bus.Emit("LOOT_RECEIVED", { itemKey = "i:" .. id, link = S.link(id), quantity = qty or 1,
            source = { kind = kind or "disenchant" } })
    end

    local function disenchant(yield, opts)
        opts = opts or {}
        if opts.click then C_Container.UseContainerItem(0, 1) end
        WoWMock.advance(0.3)
        WoWMock.fire("UNIT_SPELLCAST_START", "player", "Cast-1", DE)
        WoWMock.advance(1.5)
        if opts.removedEarly then ns.Bus.Emit("ITEMS_DELTA", { changes = opts.removedEarly }) end
        WoWMock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", DE)
        if opts.locked then
            WoWMock.bags[0][1].isLocked = true
            WoWMock.fire("ITEM_LOCK_CHANGED", 0, 1)
            WoWMock.bags[0][1].isLocked = nil
        end
        if opts.removed then ns.Bus.Emit("ITEMS_DELTA", { changes = opts.removed }) end
        for _, y in ipairs(yield) do loot(y[1], y[2]) end
        WoWMock.advance(3.1)
    end

    it("records the disenchanted item, its cost and the yield as salvage", function()
        disenchant({ { 950, 3 }, { 951, 1 } }, { locked = true })
        local r = GoblinomicsWorkshopDB.crafts[1]
        assert.equals("salvage", r.kind)
        assert.equals("disenchant", r.method)
        assert.equals("i:222", r.input)
        assert.equals(1500, r.cost)
        assert.equals(3 * 400 + 2000, r.yield)
        assert.same({ { "i:950", 3 }, { "i:951", 1 } }, r.outputs)
        local row = wns.Salvage.Rows({})[1]
        assert.equals("i:222", row.input)
        assert.equals("disenchant", row.method)
        assert.equals("Disenchant", row.name)
        assert.equals(0, #wns.Stats.Recipes({}))   -- not a recipe row
    end)

    it("counts later sales of the dust for the disenchanted item", function()
        disenchant({ { 950, 3 } }, { locked = true })
        wns.Lots.Sell("i:950", 3, 1800)
        local row = wns.Salvage.Rows({})[1]
        assert.equals(1800, row.revenue)
        assert.equals(300, row.profit)
        assert.equals(300, wns.Stats.Breakdown({}).salvage)
    end)

    it("takes the bag item used right before the cast (spell + click, TSM macro)", function()
        WoWMock.bags[0][1].hyperlink = "|cnIQ3:|Hitem:222::::::::81:64::13:1:12249:0::::Player-581-0AF7409A:|h[Bag]|h|r"
        disenchant({ { 950, 2 } }, { click = true })
        assert.equals("i:222::1:12249", GoblinomicsWorkshopDB.crafts[1].input)
    end)

    it("takes the item that left the bags, also before the cast's success event", function()
        disenchant({ { 950, 2 } }, { removed = {
            { itemKey = "i:222", delta = -1 }, { itemKey = "i:950", delta = -1 } } })
        assert.equals("i:222", GoblinomicsWorkshopDB.crafts[1].input)
        disenchant({ { 950, 1 } }, { removedEarly = { { itemKey = "i:222", delta = -1 } } })
        assert.equals("i:222", GoblinomicsWorkshopDB.crafts[2].input)
    end)

    it("ignores item locks long after the cast", function()
        disenchant({ { 950, 1 } })
        WoWMock.bags[0][1].isLocked = true
        WoWMock.fire("ITEM_LOCK_CHANGED", 0, 1)
        assert.is_nil(GoblinomicsWorkshopDB.crafts[1].input)
    end)

    it("keeps the yield without a known item, and ignores other loot and other spells", function()
        disenchant({ { 950, 1 } })
        assert.is_nil(GoblinomicsWorkshopDB.crafts[1].input)
        assert.is_true(GoblinomicsWorkshopDB.crafts[1].incomplete)
        WoWMock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 12345)
        loot(950, 1)
        WoWMock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-3", DE)
        loot(950, 1, "creature")
        WoWMock.advance(3.1)
        assert.equals(1, #GoblinomicsWorkshopDB.crafts)
    end)

    it("closes the previous cast when the next one succeeds", function()
        WoWMock.fire("UNIT_SPELLCAST_START", "player", "Cast-1", DE)
        WoWMock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", DE)
        loot(950, 2)
        WoWMock.advance(1)
        disenchant({ { 951, 1 } }, { locked = true })
        assert.equals(2, #GoblinomicsWorkshopDB.crafts)
        assert.same({ { "i:950", 2 } }, GoblinomicsWorkshopDB.crafts[1].outputs)
        assert.same({ { "i:951", 1 } }, GoblinomicsWorkshopDB.crafts[2].outputs)
    end)
end)
