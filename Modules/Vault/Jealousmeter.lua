if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/Jealousmeter.lua
-- Gallywix Jealousmeter logic (pure). Levels:
--   0..8   regular tiers (Unimpressed .. Greed Frenzy); tier 8 runs up to the top
--   9      Hostile Takeover, reached at the top of the ladder: the gold cap of
--          9,999,999 g on retail, 1,000 g (an epic mount) on WoW: Forever
--   10..12 prestige x2, x5, x10 of the top (frames around the Hostile Takeover face)
-- Progress inside a level is linear in absolute gold between the level's threshold
-- and the next one. Levels have no names; the faces identify them. Hysteresis: a level is kept until the
-- value drops below 98 % of its threshold, so values oscillating around a
-- threshold do not flip the level. A level-up toast fires only above the highest
-- level ever reached (once per level).
local _, ns = ...

local J = {}
ns.Jealousmeter = J

local COPPER_PER_GOLD = 10000
J.HYSTERESIS = 0.98
J.MAX_LEVEL = 12

-- Ladders in gold: eight tiers, then the top level (prestige at x2, x5 and x10 of it).
J.SETS = {
    retail  = { cap = 9999999, tiers = { 10000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000 } },
    forever = { cap = 1000,    tiers = { 0.5, 1, 5, 10, 25, 50, 100, 250 } },
}

--- Select a ladder ("retail" | "forever"): J.SET, J.CAP and J.THRESHOLDS (gold per level).
function J.Use(id)
    local set = J.SETS[id] or J.SETS.retail
    J.SET = J.SETS[id] and id or "retail"
    J.CAP = set.cap
    local t = { [0] = 0 }
    for i = 1, 8 do t[i] = set.tiers[i] end
    t[9], t[10], t[11], t[12] = set.cap, 2 * set.cap, 5 * set.cap, 10 * set.cap
    J.THRESHOLDS = t
end
J.Use(ns.API and ns.API.Flavor and ns.API.Flavor.id or "retail")

J.KEYS = {
    [0] = "unimpressed", "amused", "curious", "impressed", "displeased", "envious",
    "seething", "covetous", "greedfrenzy", "hostiletakeover",
}

J.PATH = "Interface\\AddOns\\Goblinomics_Vault\\Media\\Jealousmeter\\"

--- Highest level whose threshold the gold value reaches.
function J.RawLevel(gold)
    local level = 0
    for l = 1, J.MAX_LEVEL do
        if gold >= J.THRESHOLDS[l] then level = l else break end
    end
    return level
end

--- Level for a copper value, keeping `previous` inside the hysteresis band.
function J.Level(copper, previous)
    local gold = math.max(0, copper or 0) / COPPER_PER_GOLD
    local raw = J.RawLevel(gold)
    if previous and raw < previous and previous > 0 and gold >= J.THRESHOLDS[previous] * J.HYSTERESIS then
        return previous
    end
    return raw
end

--- Face tier (0..9) and prestige (0..3) of a level.
function J.Face(level)
    if level >= 9 then
        return 9, level - 9
    end
    return level, 0
end

function J.Texture(level, small)
    local tier = J.Face(level)
    return J.PATH .. "tier" .. tier .. "_" .. J.KEYS[tier] .. (small and "_64" or "")
end

--- Full display info for a copper value and a level (from J.Level).
function J.Info(copper, level)
    local gold = math.max(0, copper or 0) / COPPER_PER_GOLD
    local tier, prestige = J.Face(level)
    local info = { level = level, tier = tier, prestige = prestige, gold = gold, progress = 1 }
    if level < J.MAX_LEVEL then
        local lo, hi = J.THRESHOLDS[level], J.THRESHOLDS[level + 1]
        info.progress = math.max(0, math.min(1, (gold - lo) / (hi - lo)))
        info.next = hi
        info.toNext = math.max(0, hi - gold)
    end
    return info
end

--- True when level is a new high (the toast fires); highest < 0 means "never seen".
function J.IsNewHigh(level, highest)
    return highest ~= nil and highest >= 0 and level > highest
end
