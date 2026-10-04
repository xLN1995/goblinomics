if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Disenchant.lua
-- Disenchanting as salvage. Disenchant is a spell cast on a bag item, not a
-- profession salvage call, so the operation is put together from
--   1. the bag item used right before the cast starts (post-hook on
--      C_Container.UseContainerItem: the targeting spell takes the item from it)
--   2. else the single item that left the bags after the cast (ITEMS_DELTA), for
--      secure macros that do not pass the hook (TSM's destroy button)
--   3. the loot of the cast (LOOT_RECEIVED with source "disenchant", Core/Loot)
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

local module
local hooked = false
local lastUse   -- { key, time }
local casting   -- input key of the running cast
local op        -- { input, time, outputs, byKey, removed }

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function OnUseItem(bag, slot)
    if not module then return end
    local info = C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
    local link = info and info.hyperlink
    if not link or IsSecret(link) then return end
    lastUse = { key = ns.API.ItemKey.FromLink(link), time = GetTime() }
end

--- The item that left the bags: exactly one unit of exactly one item that is no yield.
local function RemovedInput(o)
    local input
    for key, n in pairs(o.removed) do
        if not o.byKey[key] then
            if input or n ~= 1 then return nil end
            input = key
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
    casting = lastUse and GetTime() - lastUse.time <= USE_WINDOW and lastUse.key or nil
end

local function OnSpellSucceeded(_, unit, _, spellID)
    if unit ~= "player" or IsSecret(spellID) or spellID ~= SPELL then return end
    if op then Disenchant.Flush() end
    local this = { input = casting, time = time(), outputs = {}, byKey = {}, removed = {} }
    op, casting, lastUse = this, nil, nil
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
    if not op or op.input then return end
    for _, c in ipairs(p.changes or {}) do
        if c.delta < 0 then op.removed[c.itemKey] = (op.removed[c.itemKey] or 0) - c.delta end
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
    module, lastUse, casting, op = nil, nil, nil, nil
end
