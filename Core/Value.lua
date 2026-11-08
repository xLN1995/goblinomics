if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Value.lua
-- Valuation rule (one wealth figure):
--   tradable with a market price -> market price (the vendor price when that is
--            higher: nobody sells below it); tier "speculative" when the sale
--            rate is below the speculative threshold and the item is worth at
--            least speculativeMinValue (1000 gold, 10 on WoW: Forever) each, else "market"
--   tradable without a market price -> vendor price, tier "vendor" (grey junk
--            and other items that cannot go to the auction house)
--   bound -> tier "bound", unit 0 (not part of the wealth); vendorUnit is kept
--            for information
--   no price -> tier "none"
-- No destroy value, no AH cut. Every call returns a new table.
local _, ns = ...

local Value = {}
ns.Value = Value
local Price = ns.Price

local function Fetch(result, key, role)
    local value, source, pending = Price.Get(key, role)
    if value then
        result.prices[role] = value
        result.sources[role] = source
    else
        result.gaps[role] = pending and "pending" or true
    end
    return value
end

--- opts = { bound = boolean, quantity = number }
function Value.Evaluate(itemKey, opts)
    opts = opts or {}
    local quantity = opts.quantity or 1
    local cfg = Price.Config()
    local r = { unit = 0, total = 0, vendorUnit = 0, rule = "none", tier = "none", prices = {}, sources = {}, gaps = {} }
    local vendor = Fetch(r, itemKey, "vendor")
    r.vendorUnit = vendor or 0
    if opts.bound then
        r.tier = "bound"
        r.rule = vendor and "vendor" or "none"
        return r
    end
    local market = Fetch(r, itemKey, "market")
    if market and market >= (vendor or 0) then
        r.unit, r.rule = market, "market"
        local rate = Fetch(r, itemKey, "saleRate")
        r.saleRate = rate
        local minValue = cfg.speculativeMinValue or 0
        r.tier = (rate ~= nil and rate < cfg.speculativeThreshold and market >= minValue) and "speculative" or "market"
    elseif vendor and vendor > 0 then
        r.unit, r.rule, r.tier = vendor, "vendor", "vendor"
    end
    r.total = r.unit * quantity
    return r
end

--- tier, rule
function Value.Classify(itemKey, opts)
    local r = Value.Evaluate(itemKey, opts)
    return r.tier, r.rule
end

ns.API.Value = {
    Evaluate = function(_, itemKey, opts) return Value.Evaluate(itemKey, opts) end,
    Classify = function(_, itemKey, opts) return Value.Classify(itemKey, opts) end,
}
