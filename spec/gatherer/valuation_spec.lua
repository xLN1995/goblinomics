local fake = require("spec.support.sources")

describe("Gatherer: valuation", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, pns, V

    before_each(function()
        ns, pns = load_gatherer()
        ns.Price.Config().speculativeMinValue = 0   -- test prices are far below 1000 gold
        V = pns.Valuation
        ns.Price.RegisterSource(fake("tsm", 10, {
            market = { ["i:1"] = 10000, ["i:2"] = 100, ["i:3"] = 500000, ["i:4"] = 1000 },
            destroy = { ["i:4"] = 3000 },
            saleRate = { ["i:1"] = 0.5, ["i:3"] = 0.01 },
        }))
        WoWMock.items[2] = { sellPrice = 400 }
    end)

    it("puts every item into its bucket", function()
        local r = V.Compute({ items = { ["i:1"] = 2, ["i:2"] = 5, ["i:3"] = 1, ["i:4"] = 1, ["i:9"] = 7 },
            rawGold = 1000, repair = 500, duration = 1800, realized = 4000 })
        assert.equals(20000 + 1000, r.market)   -- market price only, no destroy value
        assert.equals(2000, r.vendor)
        assert.equals(500000, r.speculative)
        assert.equals(1, r.unpriced)
        assert.equals(21000 + 2000 + 1000 - 500, r.total)
        assert.equals(47000, r.gph)
        assert.equals(4000, r.realized)
        assert.equals("i:3", r.items[1].key)    -- sorted by value
    end)

    it("returns 0 GPH without duration", function()
        assert.equals(0, V.Compute({ items = {}, rawGold = 100, duration = 0 }).gph)
    end)

    it("formats durations and whole gold", function()
        assert.equals("00:00:00", V.FormatDuration(0))
        assert.equals("26:03:04", V.FormatDuration(93784))
        assert.equals("182,400g", V.Gold(1824000000))
        assert.equals("-1,120g", V.Gold(-11200000))
        assert.equals("0g", V.Gold(4000))
    end)

    it("adds repair, speculative and realized lines only where they apply", function()
        local v = V.Compute({ items = { ["i:3"] = 1 }, rawGold = 0, repair = 10000, duration = 60 })
        local labels = {}
        for _, line in ipairs(V.Lines({ duration = 60, valuation = v })) do labels[#labels + 1] = line[1] or "rule" end
        assert.same({ "Farm", "Duration", "Items", "Market Value", "Raw Gold", "Vendor", "Repair", "rule", "Total", "GPH",
            "Speculative (not in total)", "Realized" }, labels)
    end)
end)

describe("Gatherer: valuation on WoW: Forever", function()
    it("writes gold and silver in chat-safe text", function()
        local V = select(2, load_gatherer({ client = "forever" })).Valuation
        assert.equals("12g 34s", V.Gold(123456))
        assert.equals("12g", V.Gold(120000))
        assert.equals("40s", V.Gold(4000))
        assert.equals("-1,120g 5s", V.Gold(-11200500))
        assert.equals("0g", V.Gold(0))
    end)
end)
