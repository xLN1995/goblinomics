-- M8: TSM Accounting history into the Ledger.
describe("Import: TSM Accounting", function()
    after_each(function()
        _G.TradeSkillMasterDB = nil
        assert.same({}, WoWMock.errors)
    end)

    local _, ins, mods
    local now

    local function csv(header, rows) return header .. "\n" .. table.concat(rows, "\n") end

    before_each(function()
        _, ins, mods = load_import({ before = function(core)
            core.coreDB.root.chars["Alt-Blackrock"] = { name = "Alt" }
        end })
        now = WoWMock.now
        local t = function(offset) return tostring(now + offset) end
        _G.TradeSkillMasterDB = {
            ["r@Blackrock@internalData@csvSales"] = csv("itemString,stackSize,quantity,price,otherPlayer,player,time,source", {
                "i:2589,5,5,2000,Buyer-Realm,xLN," .. t(-86400) .. ",Auction",
                "i:2589,20,20,5,Merchant,xLN," .. t(-80000) .. ",Vendor",
            }),
            ["r@Blackrock@internalData@csvBuys"] = csv("itemString,stackSize,quantity,price,otherPlayer,player,time,source", {
                "i:2592,10,10,700,Seller-Realm,xLN," .. t(-3 * 86400) .. ",Auction",
                "i:2592,1,1,700,Seller-Realm,xLN," .. t(-30 * 86400) .. ",Auction",
            }),
            ["r@Blackrock@internalData@csvIncome"] = csv("type,amount,otherPlayer,player,time", {
                "Crafting Order,190000,Customer,xLN," .. t(-7200),
                "Money Transfer,5000,Alt,xLN," .. t(-7000),
                "Money Transfer,3000,Stranger,xLN," .. t(-6000),
            }),
            ["r@Blackrock@internalData@csvExpense"] = csv("type,amount,otherPlayer,player,time", {
                "Repair Bill,20484,Merchant,xLN," .. t(-5000),
                "Postage,30,Alt,xLN," .. t(-4000),
            }),
            ["r@Blackrock@internalData@csvExpired"] = csv("itemString,stackSize,quantity,player,time", {
                "i:2589,3,3,xLN," .. t(-50000),
            }),
            ["r@Blackrock@internalData@csvCancelled"] = csv("itemString,stackSize,quantity,player,time", {}),
            ["s@xLN - Horde - Blackrock@internalData@goldLog"] = "ignored",
        }
    end)

    it("parses CSV with header and finds the realms", function()
        local rows = ins.TSM.ParseCSV("a,b,c\n1,,3\n4,5,6")
        assert.same({ a = "1", b = "", c = "3" }, rows[1])
        assert.equals(2, #rows)
        local realms = ins.TSM.Realms(_G.TradeSkillMasterDB)
        assert.is_string(realms.Blackrock.csvSales)
        assert.equals("BurningLegion", ins.Import.Realm("Burning Legion - Horde"))
    end)

    it("maps every kind of record", function()
        local batch = ins.TSM.Build(_G.TradeSkillMasterDB)
        local by = {}
        for _, e in ipairs(batch.entries) do by[e.category .. "/" .. e.sub .. "/" .. e.amount] = e end
        assert.is_table(by["AH/sale/10000"])                     -- TSM prices of sales are already net
        assert.equals("xLN-Blackrock", by["AH/sale/10000"].char)
        assert.equals("i:2589", by["AH/sale/10000"].itemKey)
        assert.is_table(by["Vendor/sell/100"])
        assert.is_table(by["AH/purchase/-7000"])
        assert.is_table(by["Crafting/commission/190000"])
        assert.is_table(by["Transfer/alt/5000"])                 -- own character
        assert.is_table(by["Mail/in/3000"])
        assert.is_table(by["Repair/repair/-20484"])
        assert.is_table(by["Mail/postage/-30"])
        local kinds = {}
        for _, e in ipairs(batch.events) do kinds[e.kind] = (kinds[e.kind] or 0) + 1 end
        assert.same({ sale = 1, purchase = 2, expired = 1 }, kinds)
        local detect = ins.Import.Detect("tsm")
        assert.is_true(detect.available)
        assert.equals(10, detect.count)
        assert.equals(now - 30 * 86400, detect.from)
    end)

    it("imports once, fills the auction log and purchase lots, and can be undone", function()
        -- the Ledger already booked the auction sale itself (net, a minute later)
        mods.ledger.Store.Add({ time = now - 86400 + 60, char = "xLN-Blackrock", category = "AH", sub = "sale",
            amount = 9510, itemKey = "i:2589", quantity = 5 })
        local preview
        ins.Import.Preview("tsm", function(r) preview = r end)
        assert.equals(8, preview.added)
        assert.equals(1, preview.duplicates)
        local result, record
        ins.Import.Run("tsm", function(r, rec) result, record = r, rec end)
        assert.equals(8, result.added)
        assert.equals(4, result.events)
        assert.equals(1, #ins.Import.List())
        local stats = mods.ledger.AuctionLog.Stats("i:2589")
        assert.equals(1, stats.sold)
        assert.equals(1, stats.expired)
        -- the purchase three days ago is a lot, the one from 30 days ago is too old
        assert.equals(10, mods.workshop.Purchases.Available("i:2592"))
        local again
        ins.Import.Run("tsm", function(r) again = r end)
        assert.equals(0, again.added)
        assert.equals(1, #ins.Import.List())
        local removed, events = ins.Import.Undo(record.id)
        assert.equals(8, removed)
        assert.equals(4, events)
        assert.equals(0, #ins.Import.List())
        assert.equals(1, #mods.ledger.Store.Query({}))
    end)

    it("maps characters by name alone with region-wide names (WoW: Forever)", function()
        local Import = ins.Import
        assert.equals("Alt-Blackrock", Import.CharKey("Alt", "Blackrock"))
        assert.equals("Alt-Other", Import.CharKey("Alt-Other", "Blackrock"))
        WoWMock.regionalNames = true
        WoWMock.gameRules[Enum.GameRule.PvPRuleset] = true
        Goblinomics.API.v1.DB.List()[1].root.chars["Nimble-PvP"] = { name = "Nimble" }
        assert.equals("Nimble-PvP", Import.CharKey("Nimble", "CAMWOWEU5Realm6PvP"))
        assert.equals("Nimble-PvP", Import.CharKey("Nimble-CAMWOWEU5Realm6PvP", "x"))
        assert.equals("Stranger-PvP", Import.CharKey("Stranger", "CAMWOWEU5Realm6PvP"))
    end)
end)
