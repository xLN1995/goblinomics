local fake = require("spec.support.sources")

describe("Vault: dashboard cards", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, vns

    local function day(offset) return os.date("%Y-%m-%d", WoWMock.now + offset * 86400) end

    before_each(function()
        ns, vns = load_vault({ money = 5000000 })
        ns.Price.RegisterSource(fake("tsm", 10, { market = {} }))
        WoWMock.advance(3)
        WoWMock.flush()
    end)

    local function history(entries)
        local h = GoblinomicsVaultDB.history
        for k in pairs(h) do h[k] = nil end
        for offset, e in pairs(entries) do h[day(offset)] = e end
    end

    it("computes the gold and wealth change against the day before the period", function()
        history({ [-8] = { gold = 1000000, wealth = 1200000, chars = { ["xLN-Blackrock"] = { gold = 1000000 } },
            warband = { gold = 0 } }, [-3] = { gold = 3000000, wealth = 3000000 } })
        local d = vns.VaultCards.Deltas(ns.Dashboard.Context(7))
        assert.equals(5000000 - 1000000, d.goldDelta)
        assert.is_false(d.partial)
        local recent = vns.VaultCards.Deltas(ns.Dashboard.Context(1))
        assert.equals(5000000 - 3000000, recent.goldDelta)
    end)

    it("says since when there is no day before the period", function()
        history({ [-3] = { gold = 2000000, wealth = 2000000 } })
        local d = vns.VaultCards.Deltas(ns.Dashboard.Context(7))
        assert.is_true(d.partial)
        assert.equals(day(-3), d.startKey)
    end)

    it("lists the gold change per character and warband", function()
        history({ [-8] = { gold = 1000000, chars = { ["xLN-Blackrock"] = { gold = 1000000 } }, warband = { gold = 0 } } })
        local list = vns.VaultCards.CharDeltas(ns.Dashboard.Context(7))
        assert.equals("xLN-Blackrock", list[1].key)
        assert.equals(4000000, list[1].delta)
        assert.equals("warband", list[2].key)
        assert.equals(0, list[2].delta)
    end)

    it("skips legacy days without gold and shows every character's gold", function()
        -- days before the one-wealth change only carry "wealth" (in-game finding, M7)
        history({ [-8] = { wealth = 1200000 }, [-2] = { wealth = 1500000 } })
        local d = vns.VaultCards.Deltas(ns.Dashboard.Context(7))
        assert.equals(0, d.goldDelta)
        assert.is_true(d.partial)
        local list = vns.VaultCards.CharDeltas(ns.Dashboard.Context(7))
        assert.equals("xLN-Blackrock", list[1].key)
        assert.equals(5000000, list[1].gold)
    end)

    it("shows no speculative part without a sale rate source", function()
        local parts = vns.VaultCards.WealthParts({ wealth = 1000, gold = 500, auctions = 100, items = 400, speculative = 150 })
        local by = {}
        for _, p in ipairs(parts) do by[p.key] = p end
        assert.is_nil(by.speculative)
        assert.equals(400, by.items.amount)
    end)

    it("splits the wealth for the bar and builds its history", function()
        ns.Price.RegisterSource(fake("tsm", 10, { market = {}, saleRate = {} }))
        local parts = vns.VaultCards.WealthParts({ wealth = 1000, gold = 500, auctions = 100, items = 400, speculative = 150 })
        local by = {}
        for _, p in ipairs(parts) do by[p.key] = p end
        assert.equals(500, by.gold.amount)
        assert.equals(250, by.items.amount)
        assert.equals(150, by.speculative.amount)
        assert.equals(0.5, by.gold.share)
        assert.is_nil(by.other)
        local linked = vns.VaultCards.WealthParts({ wealth = 1300, gold = 600, auctions = 100, items = 400, speculative = 0 })
        assert.equals(200, linked[#linked].amount)                 -- other accounts beyond their gold
        history({ [-3] = { wealth = 2000000 } })
        local values, keys = vns.VaultCards.WealthSeries(ns.Dashboard.Context(7))
        assert.equals(2, #values)
        assert.equals(day(-3), keys[1])
        assert.equals(vns.Networth.Get().wealth, values[2])
    end)

    it("picks Gallywix's mood from the wealth change", function()
        local C = vns.VaultCards
        assert.equals("ecstatic", C.Mood({ wealth = 1200, wealthDelta = 200 }))
        assert.equals("happy", C.Mood({ wealth = 1030, wealthDelta = 30 }))
        assert.equals("neutral", C.Mood({ wealth = 1000, wealthDelta = 0 }))
        assert.equals("grumpy", C.Mood({ wealth = 950, wealthDelta = -50 }))
        assert.equals("horrified", C.Mood({ wealth = 500, wealthDelta = -500 }))
        assert.is_string(C.Comment("happy"))
    end)

    it("builds and refreshes the three cards on the dashboard", function()
        local tab = ns.UI.GetTab("dashboard")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        local ids = {}
        for _, card in ipairs(ns.Dashboard.State().cards) do ids[#ids + 1] = card.spec.id end
        assert.same({ "vault.wealth", "vault.gallywix", "vault.chars", "vault.goals" }, ids)
        tab.onHide()
    end)
end)

describe("Vault: owners on WoW: Forever", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local function boot(client)
        local ns, vns = load_vault({ client = client, money = 5000000 })
        ns.Price.RegisterSource(fake("tsm", 10, { market = {} }))
        WoWMock.advance(3)
        WoWMock.flush()
        return ns, vns
    end

    local function keys(list)
        local out = {}
        for i, e in ipairs(list) do out[i] = e.key end
        return out
    end

    it("lists the warband bank on retail", function()
        local ns, vns = boot(nil)
        assert.same({ "xLN-Blackrock", "warband" }, keys(vns.VaultUI.Rows(vns.Networth.Get())))
        assert.same({ "xLN-Blackrock", "warband" }, keys(vns.VaultCards.CharDeltas(ns.Dashboard.Context(7))))
    end)

    it("knows no warband bank on Forever", function()
        local ns, vns = boot("forever")
        assert.same({ "xLN-Blackrock" }, keys(vns.VaultUI.Rows(vns.Networth.Get())))
        assert.same({ "xLN-Blackrock" }, keys(vns.VaultCards.CharDeltas(ns.Dashboard.Context(7))))
    end)
end)
