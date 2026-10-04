if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/CraftTracker.lua
-- Craft capture (pattern from CraftSim's craft log):
--   1. post-hooks on C_TradeSkillUI.CraftRecipe / CraftEnchant / RecraftRecipe /
--      RecraftRecipeForOrder / CraftSalvage store a pending operation (recipe,
--      reagent table, order, salvage item); the result event has no recipeID
--   2. TRADE_SKILL_CRAFT_BEGIN / UNIT_SPELLCAST_SUCCEEDED count executed crafts
--   3. TRADE_SKILL_ITEM_CRAFTED_RESULT events are buffered 0.1 s (one craft can
--      fire several events), then one record per batch: outputs by item key,
--      resourcefulness and concentration once per operationID
--   4. reagents from Reagents.Consumed, costs at the market price of this moment
--   5. outputs become FIFO lots; order crafts go to Orders instead
-- Enchants applied to gear (no item result) are dropped.
local _, ns = ...

local Tracker = {}
ns.CraftTracker = Tracker

local BUFFER = 0.1
local PENDING_TTL = 600

local ESTIMATE_WINDOW = 1

local module
local pending          -- current operation
local lastEstimate     -- CRAFT_COST_ESTIMATE from a connector (CraftSim)
local buffer = {}      -- result tables of the running batch
local flushScheduled = false
local hooked = false

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

local function OrderSnapshot(orderID)
    if not orderID or orderID == 0 then return nil end
    local order = C_CraftingOrders and C_CraftingOrders.GetClaimedOrder and C_CraftingOrders.GetClaimedOrder()
    if type(order) ~= "table" then return { orderID = orderID } end
    return {
        orderID = order.orderID or orderID, customer = order.customerName, spellID = order.spellID,
        tip = order.tipAmount, consortiumCut = order.consortiumCut, rewards = order.npcOrderRewards,
        reagents = order.reagents, orderType = order.orderType,
    }
end

local function Begin(op)
    if not module or not op.recipeID or IsSecret(op.recipeID) then return end
    op.time = GetTime()
    op.crafts, op.used = 0, 0
    pending = op
    -- the connector's hook may run before or after this one
    local e = lastEstimate
    if e and e.recipeID == op.recipeID and op.time - e.time <= ESTIMATE_WINDOW then
        op.craftSimCost, op.craftSimFallback = e.perCraft, e.perItem
    end
end
Tracker.Begin = Begin

local function OnCraftRecipe(recipeID, amount, reagents, _, orderID)
    Begin({ kind = (orderID and orderID ~= 0) and "order" or "craft", recipeID = recipeID, amount = amount,
        reagents = reagents, order = OrderSnapshot(orderID) })
end

local function OnCraftEnchant(recipeID, amount, reagents)
    Begin({ kind = "enchant", recipeID = recipeID, amount = amount, reagents = reagents })
end

local function OnRecraft(itemGUID, reagents)
    local recipeID = C_TradeSkillUI.GetOriginalCraftRecipeID and C_TradeSkillUI.GetOriginalCraftRecipeID(itemGUID)
    Begin({ kind = "recraft", recipeID = recipeID, amount = 1, reagents = reagents, isRecraft = true })
end

local function OnRecraftForOrder(orderID, itemGUID, reagents)
    local order = OrderSnapshot(orderID)
    local recipeID = (order and order.spellID)
        or (C_TradeSkillUI.GetOriginalCraftRecipeID and C_TradeSkillUI.GetOriginalCraftRecipeID(itemGUID))
    Begin({ kind = "order", recipeID = recipeID, amount = 1, reagents = reagents, isRecraft = true, order = order })
end

local function OnSalvage(recipeID, amount, itemLocation, reagents)
    local itemID = itemLocation and C_Item.GetItemID and C_Item.GetItemID(itemLocation)
    Begin({ kind = "salvage", recipeID = recipeID, amount = amount, reagents = reagents, salvageItemID = itemID })
end

local function OnCraftBegin(_, spellID)
    if pending and spellID == pending.recipeID then pending.begun = true end
end

local function OnSpellSucceeded(_, unit, _, spellID)
    if unit == "player" and pending and spellID == pending.recipeID then
        pending.crafts = pending.crafts + 1
    end
end

-- Outputs, concentration and ingenuity of a batch (once per operationID).
local function Summarize(results)
    local outputs, byKey = {}, {}
    local concentration, ingenuity, seen = 0, 0, {}
    for _, r in ipairs(results) do
        local key = (r.hyperlink and not IsSecret(r.hyperlink) and ns.API.ItemKey.FromLink(r.hyperlink))
            or (r.itemID and ("i:" .. r.itemID))
        if key and (r.quantity or 0) > 0 then
            local o = byKey[key]
            if not o then
                o = { key = key, qty = 0, quality = r.craftingQuality, link = r.hyperlink }
                byKey[key] = o
                outputs[#outputs + 1] = o
            end
            o.qty = o.qty + r.quantity
        end
        local op = r.operationID
        if not (op and seen[op]) then
            if op then seen[op] = true end
            concentration = concentration + (r.concentrationSpent or 0)
            ingenuity = ingenuity + (r.ingenuityRefund or 0)
        end
    end
    return outputs, concentration, ingenuity
end

--- Compact copy of the order's reagents for later checks: { { itemID, quantity, source } }.
function Tracker.OrderReagents(order)
    if type(order) ~= "table" or type(order.reagents) ~= "table" then return nil end
    local list = {}
    for _, r in ipairs(order.reagents) do
        local itemID, qty = ns.Reagents.Entry(r)
        list[#list + 1] = { itemID, qty, r.source }
    end
    return #list > 0 and list or nil
end

--- Value of the quality below the reached one per unit (for the concentration value).
local function BelowValue(op, outputs)
    local o = outputs[1]
    if not o or not o.quality or o.quality < 2 then return nil end
    local key = ns.Recipes.QualityItemKey(op.recipeID, o.quality - 1, op.reagents)
    return key and ns.Reagents.UnitPrice(key) or nil
end

function Tracker.Flush()
    flushScheduled = false
    local results = buffer
    buffer = {}
    local op = pending
    if not op or #results == 0 then return end
    local kept = {}
    for _, r in ipairs(results) do
        -- enchants on gear have no item; enchants on vellum produce a scroll
        if not (r.isEnchant and not r.hyperlink and not r.itemID) then kept[#kept + 1] = r end
    end
    if #kept == 0 or ns.Recipes.IsIgnored(op.recipeID) then return end
    local crafts = op.crafts - op.used
    if crafts <= 0 then crafts = 1 end
    op.used = op.used + crafts

    local outputs, concentration, ingenuity = Summarize(kept)
    local call = { recipeID = op.recipeID, isRecraft = op.isRecraft, reagents = op.reagents,
        salvageItemID = op.salvageItemID }
    local consumed = ns.Reagents.Consumed(call, crafts, op.order)
    local returned = ns.Reagents.Returned(kept)
    local lines, cost, saved, incomplete = ns.Reagents.Cost(consumed, returned, { time = time() })
    local info = ns.Recipes.Info(op.recipeID) or {}
    local reagents = ns.Reagents.Compact(lines)
    local record = {
        id = ns.NextId(), time = time(), char = module.db.charKey, recipe = op.recipeID, name = info.name,
        profession = info.profession, kind = op.kind, crafts = crafts, reagents = reagents,
        cost = cost, saved = saved, incomplete = incomplete or nil,
        concentration = concentration > 0 and concentration or nil, ingenuity = ingenuity > 0 and ingenuity or nil,
        order = op.order and op.order.orderID or nil,
        orderReagents = Tracker.OrderReagents(op.order),
        craftSimCost = op.craftSimCost and op.craftSimCost * crafts or nil,
    }
    record.outputs = {}
    for i, o in ipairs(outputs) do record.outputs[i] = { o.key, o.qty, o.quality } end
    if concentration > 0 then
        record.below = BelowValue(op, outputs)
        record.reached = outputs[1] and ns.Reagents.UnitPrice(outputs[1].key) or nil
    end
    -- no own prices at all: CraftSim's estimate as a fallback
    if incomplete and cost == 0 and op.craftSimFallback then
        local made = 0
        for _, o in ipairs(outputs) do made = made + o.qty end
        record.cost, record.costSource = op.craftSimFallback * math.max(1, made), "craftsim"
    end
    if op.kind == "salvage" then
        record.yield = ns.Reagents.Value(outputs)
        record.input = op.salvageItemID and ("i:" .. op.salvageItemID) or nil
    end
    table.insert(module.db.root.crafts, record)
    if op.kind == "order" then
        if ns.Orders then ns.Orders.OnCraft(record, op.order) end
    elseif ns.Lots then
        ns.Lots.Add(record)
    end
    ns.API.Emit("WORKSHOP_CRAFT", record)
    return record
end

local function OnResult(_, result)
    if type(result) ~= "table" or IsSecret(result) then return end
    if not pending or GetTime() - pending.time > PENDING_TTL then return end
    buffer[#buffer + 1] = result
    if not flushScheduled then
        flushScheduled = true
        module:After(BUFFER, Tracker.Flush)
    end
end

function Tracker.Pending() return pending end

function Tracker.Enable(m)
    module = m
    if not hooked and C_TradeSkillUI then
        hooked = true
        local function Hook(name, fn)
            if type(C_TradeSkillUI[name]) == "function" then
                hooksecurefunc(C_TradeSkillUI, name, function(...) if module then fn(...) end end)
            end
        end
        Hook("CraftRecipe", OnCraftRecipe)
        Hook("CraftEnchant", OnCraftEnchant)
        Hook("RecraftRecipe", OnRecraft)
        Hook("RecraftRecipeForOrder", OnRecraftForOrder)
        Hook("CraftSalvage", OnSalvage)
    end
    m:On("CRAFT_COST_ESTIMATE", function(_, e)
        lastEstimate = { recipeID = e.recipeID, perCraft = e.perCraft, perItem = e.perItem, time = GetTime() }
        if pending and pending.recipeID == e.recipeID and GetTime() - pending.time <= ESTIMATE_WINDOW then
            pending.craftSimCost, pending.craftSimFallback = e.perCraft, e.perItem
        end
    end)
    m:RegisterEvent("TRADE_SKILL_CRAFT_BEGIN", OnCraftBegin)
    m:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", OnSpellSucceeded)
    m:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", OnResult)
end

function Tracker.Disable()
    pending, buffer, flushScheduled = nil, {}, false
end
