describe("Flips: auction house hints and dashboard card", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, fns, lns

    before_each(function()
        ns, fns, lns = load_flips()
        WoWMock.items[3001] = { name = "Ore" }
    end)

    local function buy(key, qty, total)
        lns.Store.Add({ time = WoWMock.now, char = "xLN-Blackrock", category = "AH", sub = "purchase",
            amount = -total, itemKey = key, quantity = qty })
    end

    it("shows cost basis, break-even and the profit at the entered price when selling", function()
        buy("i:3001", 10, 2000)                        -- 200 each
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        local hint = fns.AuctionHints.Sell("i:3001", 300, 10)
        assert.equals(3, #hint.lines)
        assert.equals(300 * 0.95 - 200, hint.gain)
        assert.is_true(fns.AuctionHints.Sell("i:3001", 150, 10).gain < 0)
        assert.equals(2, #fns.AuctionHints.Sell("i:3001").lines)   -- no price entered yet
        assert.is_nil(fns.AuctionHints.Sell("i:9999", 300, 1))
    end)

    it("sums the flip record of every variant of an item for the buy line and the tooltip", function()
        buy("i:3001", 10, 1000)
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        lns.AuctionLog.Sale("i:3001", "Ore", 6, 1800, 1710)
        local r = fns.AuctionHints.Record("i:3001")
        assert.equals(6, r.soldQty)
        assert.equals(4, r.openQty)
        assert.equals((1710 - 600) / 6, r.perUnit)
        assert.is_string(fns.AuctionHints.Buy("i:3001", "Ore"))
        assert.is_nil(fns.AuctionHints.Buy("i:9999", "None"))
        assert.equals(3, #fns.AuctionHints.TooltipLines("i:3001"))
    end)

    it("registers the dashboard card with profit, open stock and the top items", function()
        local widgets = {}
        for _, w in ipairs(ns.UI.SortedWidgets()) do widgets[w.id] = w end
        assert.is_table(widgets["flips.summary"])
        buy("i:3001", 10, 1000)
        lns.AuctionLog.Post("i:3001", 10, 0, nil, 300)
        lns.AuctionLog.Sale("i:3001", "Ore", 5, 1500, 1425)
        local s = fns.Cards.Summary(ns.Periods.Context(7))
        assert.equals(925, s.totals.profit)
        assert.equals(1, s.openItems)
        assert.equals("i:3001", s.top[1].key)
        local f = CreateFrame("Frame")
        widgets["flips.summary"].build(f)
        widgets["flips.summary"].refresh(f, ns.Periods.Context(7))
    end)
end)
