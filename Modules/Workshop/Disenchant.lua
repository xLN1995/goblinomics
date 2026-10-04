if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Disenchant.lua
-- Disenchanting as salvage. Disenchant is a spell cast on a bag item, not a
-- profession salvage call, so the operation is put together from
--   1. the bag item the client locks when the cast starts: the spell's target,
--      however the cast was started (spell + click, TSM's "/cast; /use bag slot"
--      macro button, other macros)
--   2. else the bag item used right before the cast (post-hook on
--      C_Container.UseContainerItem)
--   3. else the single item that left the bags around the cast (ITEMS_DELTA)
--   4. the loot of the cast (LOOT_RECEIVED with source "disenchant", Core/Loot)
-- One record per cast with kind "salvage" and method "disenchant": the item's
-- cost (purchase, crafted lot, else market price) against the yield. The yield
-- becomes lots, so later sales of the dust count for the disenchanted item.
local _, ns = ...

local Disenchant = {}
ns.Disenchant = Disenchant

local SPELL = 13262
local ENCHANTING = 333   -- skill line
local USE_WINDOW = 1     -- item use -> cast start
local LOOT_WINDOW = 3    -- cast success -> loot and bag change
local REMOVED_TTL = 10   -- bag removals kept for the fallback

local module
local hooked = false
local lastUse   -- { key, time }
local casting   -- input key of the running cast
local castAt    -- GetTime() of the running cast's start
local op        -- { input, time, since, outputs, byKey }
local removed = {}   -- recent bag removals { key, n, at }

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function OnUseItem(bag, slot)
    if not module then return end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    local link = info and info.hyperlink
    if not link or IsSecret(link) then return end
    lastUse = { key = ns.API.ItemKey.FromLink(link), time = GetTime() }
end

local function BagIDs()
    local e = Enum and Enum.BagIndex
    if e and e.Backpack then return { e.Backpack, e.Bag_1, e.Bag_2, e.Bag_3, e.Bag_4 } end
    return { 0, 1, 2, 3, 4 }
end

--- The one locked bag item (the target of a starting cast), else nil.
local function LockedItem()
    local found
    for _, bag in ipairs(BagIDs()) do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.isLocked and info.hyperlink and not IsSecret(info.hyperlink) then
                if found then return nil end
                found = ns.API.ItemKey.FromLink(info.hyperlink)
            end
        end
    end
    return found
end

--- The item that left the bags since the cast: exactly one unit of exactly one item that is no yield.
local function RemovedInput(o)
    local input
    for _, r in ipairs(removed) do
        if r.at >= o.since and not o.byKey[r.key] then
            if input or r.n ~= 1 then return nil end
            input = r.key
        end
    end
    return input
end

local function Names()
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(SPELL) or ns.L["Disenchant"]
    local profession = C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillDisplayName
        and C_TradeSkillUI.GetTradeSkillDisplayName(ENCHANTING) or nil
    return name, profession
end

function Disenchant.Flush()
    local o = op
    op = nil
    if not o or #o.outputs == 0 then return nil end
    local input = o.input or RemovedInput(o)
    -- the item's own removal must not confuse the next cast
    for i, r in ipairs(removed) do
        if r.key == input then table.remove(removed, i); break end
    end
    local lines, cost, saved, incomplete = {}, 0, 0, false
    if input then
        lines, cost, saved, incomplete = ns.Reagents.Cost({ [input] = 1 }, {}, { time = o.time })
    end
    local name, profession = Names()
    local record = {
        id = ns.NextId(), time = o.time, char = module.db.charKey, recipe = SPELL, name = name,
        profession = profession, kind = "salvage", method = "disenchant", crafts = 1,
        reagents = ns.Reagents.Compact(lines), cost = cost, saved = saved,
        incomplete = (incomplete or not input) or nil, input = input,
        yield = ns.Reagents.Value(o.outputs), outputs = {},
    }
    for i, out in ipairs(o.outputs) do record.outputs[i] = { out.key, out.qty } end
    table.insert(module.db.root.crafts, record)
    ns.Lots.Add(record)
    ns.API.Emit("WORKSHOP_CRAFT", record)
    return record
end

local function OnCastStart(_, unit, _, spellID)
    if unit ~= "player" or IsSecret(spellID) or spellID ~= SPELL then return end
    castAt = GetTime()
    casting = LockedItem() or (lastUse and castAt - lastUse.time <= USE_WINDOW and lastUse.key) or nil
end

local function OnSpellSucceeded(_, unit, _, spellID)
    if unit ~= "player" or IsSecret(spellID) or spellID ~= SPELL then return end
    if op then Disenchant.Flush() end
    local since = (castAt and GetTime() - castAt <= 10) and castAt - 0.5 or GetTime() - 3
    local this = { input = casting, time = time(), since = since, outputs = {}, byKey = {} }
    op, casting, castAt, lastUse = this, nil, nil, nil
    module:After(LOOT_WINDOW, function()
        if op == this then Disenchant.Flush() end
    end)
end

local function OnLoot(_, p)
    if not op or not p.source or p.source.kind ~= "disenchant" then return end
    local out = op.byKey[p.itemKey]
    if not out then
        out = { key = p.itemKey, qty = 0 }
        op.byKey[p.itemKey] = out
        op.outputs[#op.outputs + 1] = out
    end
    out.qty = out.qty + p.quantity
end

local function OnItems(_, p)
    local now = GetTime()
    for i = #removed, 1, -1 do
        if now - removed[i].at > REMOVED_TTL then table.remove(removed, i) end
    end
    for _, c in ipairs(p.changes or {}) do
        if c.delta < 0 then removed[#removed + 1] = { key = c.itemKey, n = -c.delta, at = now } end
    end
end

function Disenchant.Enable(m)
    module = m
    if not hooked and C_Container and type(C_Container.UseContainerItem) == "function" then
        hooked = true
        hooksecurefunc(C_Container, "UseContainerItem", OnUseItem)
    end
    m:RegisterEvent("UNIT_SPELLCAST_START", OnCastStart, "Disenchant")
    m:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded, "Disenchant")
    m:On("LOOT_RECEIVED", OnLoot)
    m:On("ITEMS_DELTA", OnItems)
end

function Disenchant.Disable()
    module, lastUse, casting, castAt, op = nil, nil, nil, nil, nil
    removed = {}
end
