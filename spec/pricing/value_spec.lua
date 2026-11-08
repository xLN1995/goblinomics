-- Valuation rule (one wealth figure): market price, vendor price for items that
-- cannot go to the auction house, speculative below the sale-rate threshold,
-- bound items count nothing.
local fake = require("spec.support.sources")

describe("Pricing: valuation rule", function()
    local ns, Value, values

    local function set(role, key, v)
        values[role] = values[role] or {}
        values[role][key] = v
        ns.Price.Invalidate()
    end

    before_each(function()
        ns = load_core({ login = true, money = 1 })
        ns.Price.Config().speculativeMinValue = 0   -- test prices are far below 1000 gold
        Value = ns.Value
        values = { market = {}, destroy = {}, saleRate = {} }
        ns.Price.RegisterSource(fake("tsm", 10, values))
    end)

    it("uses the market price and ignores destroy values", function()
        set("market", "i:1", 500); set("destroy", "i:1", 900); set("saleRate", "i:1", 0.5)
        WoWMock.items[1] = { sellPrice = 100 }
        local r = Value.Evaluate("i:1")
        assert.same({ 500, "market", "market" }, { r.unit, r.rule, r.tier })
        assert.equals(100, r.vendorUnit)
    end)

    it("uses the vendor price when it is higher than the market price", function()
        set("market", "i:2", 50); WoWMock.items[2] = { sellPrice = 80 }
        local r = Value.Evaluate("i:2")
        assert.same({ 80, "vendor", "vendor" }, { r.unit, r.rule, r.tier })
    end)

    it("falls back to the vendor price without a market price", function()
        WoWMock.items[3] = { sellPrice = 25 }
        local r = Value.Evaluate("i:3")
        assert.same({ 25, "vendor", "vendor" }, { r.unit, r.rule, r.tier })
        assert.is_true(r.gaps.market)
    end)

    it("marks items below the speculative threshold, market with unknown sale rate", function()
        set("market", "i:10", 10000)
        set("saleRate", "i:10", 0.049)
        assert.equals("speculative", Value.Evaluate("i:10").tier)
        set("saleRate", "i:10", 0.2)
        assert.equals("market", Value.Evaluate("i:10").tier)
        values.saleRate["i:10"] = nil
        ns.Price.Invalidate()
        local r = Value.Evaluate("i:10")
        assert.equals("market", r.tier)
        assert.is_true(r.gaps.saleRate)
        ns.Price.Config().speculativeThreshold = 0.3
        set("saleRate", "i:10", 0.2)
        assert.equals("speculative", Value.Evaluate("i:10").tier)
    end)

    it("never marks items below the minimum value (1000 gold each by default) as speculative", function()
        local cfg = ns.Price.Config()
        local defaults = ns.CORE_DB_SPEC.defaults.pricing
        assert.equals(10000000, defaults.speculativeMinValue)
        cfg.speculativeMinValue = defaults.speculativeMinValue
        set("market", "i:10", 9999999)                                  -- just below 1000 gold
        set("saleRate", "i:10", 0.01)
        assert.equals("market", Value.Evaluate("i:10").tier)
        set("market", "i:10", 10000000)
        assert.equals("speculative", Value.Evaluate("i:10").tier)
    end)

    it("counts bound items with nothing and keeps their vendor price for information", function()
        set("market", "i:20", 99999); WoWMock.items[20] = { sellPrice = 200 }
        local r = Value.Evaluate("i:20", { bound = true })
        assert.same({ 0, "bound", 200 }, { r.unit, r.tier, r.vendorUnit })
        assert.is_nil(r.gaps.market)
    end)

    it("marks items without any price", function()
        local r = Value.Evaluate("i:30")
        assert.same({ 0, "none", "none" }, { r.unit, r.rule, r.tier })
        assert.is_true(r.gaps.market)
        assert.equals("pending", r.gaps.vendor)
    end)

    it("multiplies by quantity and classifies", function()
        set("market", "i:40", 100); set("saleRate", "i:40", 0.01)
        assert.equals(2000, Value.Evaluate("i:40", { quantity = 20 }).total)
        assert.same({ "speculative", "market" }, { Value.Classify("i:40") })
    end)
end)

describe("Pricing: speculative minimum on WoW: Forever", function()
    it("needs only 10 gold instead of 1,000", function()
        local ns = load_core({ boot = true, client = "forever" })
        assert.equals(100000, ns.CORE_DB_SPEC.defaults.pricing.speculativeMinValue)
        assert.equals(100000, ns.Price.Config().speculativeMinValue)
    end)
end)
