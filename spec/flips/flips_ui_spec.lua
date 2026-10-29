local fake = require("spec.support.sources")

describe("Flips UI", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, fns, lns

    before_each(function()
        ns, fns, lns = load_flips()
        WoWMock.items[3001] = { name = "Ore" }
        WoWMock.items[3002] = { name = "Gem" }
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:3001"] = 320 } }))
    end)

    local function buy(key, qty, total, char)
        lns.Store.Add({ time = WoWMock.now, char = char or "xLN-Blackrock", category = "AH", sub = "purchase",
            amount = -total, itemKey = key, quantity = qty })
    end

    local function flip(key, name, qty, cost, gross)
        buy(key, qty, cost)
        lns.AuctionLog.Post(key, qty, 0, nil, gross / qty)
        lns.AuctionLog.Sale(key, name, qty, gross, math.floor(gross * 0.95))
    end

    local function build()
        local tab = ns.UI.GetTab("flips")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        return tab
    end

    it("registers the tab and the settings section", function()
        assert.is_table(ns.UI.GetTab("flips"))
        local section = ns.UI.GetSettings("flips")
        assert.is_table(section)
        assert.is_true(section.build(CreateFrame("Frame"), 0) > 60)
    end)

    it("filters by search and open stock and sorts by a column", function()
        flip("i:3001", "Ore", 10, 1000, 3000)     -- profit 1850
        flip("i:3002", "Gem", 1, 5000, 4000)      -- profit -1200
        buy("i:3002", 2, 1000)
        lns.AuctionLog.Post("i:3002", 2, 0, nil, 900)
        build()
        local UI = fns.FlipsUI
        local items = UI.Apply(fns.Stats.Summary(UI.Window()))
        assert.equals("i:3001", items[1].key)            -- by profit
        UI.SortBy("profit")                              -- reversed
        items = UI.Apply(fns.Stats.Summary(UI.Window()))
        assert.equals("i:3002", items[1].key)
        UI.state.openOnly = true
        items = UI.Apply(fns.Stats.Summary(UI.Window()))
        assert.equals(1, #items)
        assert.equals("i:3002", items[1].key)
        UI.state.openOnly = false
        UI.state.search = "ore"
        items = UI.Apply(fns.Stats.Summary(UI.Window()))
        assert.equals(1, #items)
        assert.equals("i:3001", items[1].key)
    end)

    it("opens the detail view with lots, market comparison and actions", function()
        buy("i:3001", 10, 2000)
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        lns.AuctionLog.Sale("i:3001", "Ore", 4, 1200, 1140)
        build()
        fns.FlipsUI.ShowDetail("i:3001")
        local lots = fns.Stats.Lots("i:3001")
        assert.equals(1, #lots)
        assert.equals(4, lots[1].soldQty)
        assert.equals(1140 - 800, lots[1].profit)
        assert.equals(200, fns.FlipsDetail.CostBasis("i:3001"))
        assert.equals(211, fns.FlipsDetail.BreakEven(200))      -- 200 / 0.95, rounded up
        fns.Store.WriteOff(lots[1].id, "loss")
        fns.Changed()
        assert.equals(1140 - 2000, fns.Stats.Lots("i:3001")[1].profit)
        fns.Store.IgnoreKey("i:3001")
        buy("i:3001", 5, 500)
        assert.equals(1, #GoblinomicsFlipsDB.lots)              -- no new lot for an ignored item
        fns.FlipsUI.ShowOverview()
    end)
end)
