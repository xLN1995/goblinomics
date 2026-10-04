if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/Reagents.lua
-- Which reagents a craft really consumed and what they cost.
-- The reagent table passed to CraftRecipe & co. is nested in 12.x
-- ({ reagent = { itemID }, quantity, dataSlotIndex }) and leaves out basic
-- reagents without quality tiers; those come from GetRecipeSchematic (basic
-- slots not covered by the table, reagents[1] x quantityRequired), as
-- Journalator and CraftSim rebuild them. Salvage uses schematic.quantityMax of
-- the salvaged item. Reagent slots the customer supplied for an order are left
-- out completely, whatever quality the customer chose: the client leaves those
-- slots out of the craft call, and the schematic would otherwise fill them with
-- the first quality (in-game finding, M6).
-- Costs: market price at the time of the craft, else destroy, else vendor;
-- items without any price mark the result as incomplete. Resourcefulness
-- returns count with their full value as saved cost. Bought reagents cost what
-- was paid (Purchases), crafted intermediates their craft cost (Lots).
local _, ns = ...

local Reagents = {}
ns.Reagents = Reagents

local BASIC = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
-- The reagents of a claimed order are the customer's (Journalator reads them all
-- that way); only entries explicitly marked as the crafter's are excluded. A
-- check for source == Customer alone missed customer reagents in game (M6).
local CRAFTER = Enum and Enum.CraftingOrderReagentSource and Enum.CraftingOrderReagentSource.Crafter

local function IsCustomer(entry)
    return not (CRAFTER ~= nil and entry.source == CRAFTER)
end
Reagents.IsCustomer = IsCustomer

local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end

--- itemID and quantity of a reagent entry in any of the known shapes.
function Reagents.Entry(entry)
    if type(entry) ~= "table" then return nil end
    local info = entry.reagentInfo or entry
    local reagent = info.reagent or info
    if type(reagent) == "table" and type(reagent.reagent) == "table" then reagent = reagent.reagent end
    local itemID = type(reagent) == "table" and reagent.itemID or nil
    if itemID == 0 or IsSecret(itemID) then itemID = nil end
    return itemID, info.quantity or entry.quantity or 0, info.dataSlotIndex or entry.dataSlotIndex
end

local function Add(map, itemID, qty)
    if not itemID or not qty or qty <= 0 then return end
    local key = "i:" .. itemID
    map[key] = (map[key] or 0) + qty
end

--- Slots supplied by the customer: dataSlotIndex set, schematic index set, item set.
local function CustomerSlots(order)
    local data, index, items = {}, {}, {}
    if type(order) ~= "table" then return data, index, items end
    for _, r in ipairs(order.reagents or {}) do
        if IsCustomer(r) then
            local itemID, _, dataSlot = Reagents.Entry(r)
            if dataSlot then data[dataSlot] = true end
            if r.slotIndex then index[r.slotIndex] = true end
            if itemID then items[itemID] = true end
        end
    end
    return data, index, items
end

--- Reagents consumed by `crafts` crafts: { [itemKey] = quantity }.
-- call = { recipeID, isRecraft, reagents, salvageItemID }; order = claimed order or nil
function Reagents.Consumed(call, crafts, order)
    crafts = crafts or 1
    local consumed = {}
    local customerData, customerIndex, customerItems = CustomerSlots(order)
    local schematic = C_TradeSkillUI.GetRecipeSchematic
        and C_TradeSkillUI.GetRecipeSchematic(call.recipeID, call.isRecraft == true)
    local slots = type(schematic) == "table" and schematic.reagentSlotSchematics or {}
    -- a slot belongs to the customer when its index, data slot or any quality of its item matches
    local customerSlotItems = {}
    for i, slot in ipairs(slots) do
        local isCustomer = customerIndex[i] or (slot.dataSlotIndex and customerData[slot.dataSlotIndex])
        for _, r in ipairs(slot.reagents or {}) do
            if r.itemID and customerItems[r.itemID] then isCustomer = true end
        end
        if isCustomer then
            if slot.dataSlotIndex then customerData[slot.dataSlotIndex] = true end
            for _, r in ipairs(slot.reagents or {}) do
                if r.itemID then customerSlotItems[r.itemID] = true end
            end
        end
    end
    for itemID in pairs(customerItems) do customerSlotItems[itemID] = true end

    local covered = {}
    for _, entry in ipairs(call.reagents or {}) do
        local itemID, qty, slot = Reagents.Entry(entry)
        if slot then covered[slot] = true end
        local customer = (slot and customerData[slot]) or (itemID and customerSlotItems[itemID])
        if not customer then Add(consumed, itemID, qty * crafts) end
    end
    for _, slot in ipairs(slots) do
        local first = slot.reagents and slot.reagents[1]
        if slot.reagentType == BASIC and first and first.itemID and not covered[slot.dataSlotIndex]
            and not (slot.dataSlotIndex and customerData[slot.dataSlotIndex]) then
            Add(consumed, first.itemID, (slot.quantityRequired or 0) * crafts)
        end
    end
    if call.salvageItemID and type(schematic) == "table" then
        Add(consumed, call.salvageItemID, (schematic.quantityMax or 1) * crafts)
    end
    return consumed
end

--- Resourcefulness returns of result events, once per operationID: { [itemKey] = quantity }.
function Reagents.Returned(results)
    local returned, seen = {}, {}
    for _, r in ipairs(results or {}) do
        local op = r.operationID
        if not (op and seen[op]) then
            if op then seen[op] = true end
            for _, entry in ipairs(r.resourcesReturned or {}) do
                local itemID, qty = Reagents.Entry(entry)
                Add(returned, itemID, qty)
            end
        end
    end
    return returned
end

--- Stored form of Cost lines:
-- { { key, consumed, unit (per net item), market unit, from purchases, from crafts, returned, cost } }
function Reagents.Compact(lines)
    local reagents = {}
    for i, l in ipairs(lines) do
        reagents[i] = { l.key, l.qty, l.unit, l.market, l.purchased, l.crafted, l.returned, l.cost }
    end
    return reagents
end

--- Market value of outputs { { key = , qty = } } (unknown prices count 0).
function Reagents.Value(outputs)
    local value = 0
    for _, o in ipairs(outputs) do value = value + (Reagents.UnitPrice(o.key) or 0) * o.qty end
    return value
end

--- Unit price for costs: market, else destroy, else vendor (nil = unknown).
function Reagents.UnitPrice(key)
    local Price = ns.API.Price
    return Price:Get(key, "market") or Price:Get(key, "destroy") or Price:Get(key, "vendor")
end

--- Cost of the consumed reagents. Per item the net consumption (consumed minus
-- resourcefulness returns) is taken from purchase lots first (what was paid,
-- Purchases), then from crafted lots (intermediates at their craft cost, Lots),
-- the rest at market price. Returns above the consumption (customer reagents of
-- an order) are a pure gain at market value.
-- opts = { time, market = { [key] = unit } (replay: market price of that time) }
-- Returns lines { { key, qty, unit, market, purchased, crafted, returned, cost } }
-- sorted by cost, total cost, saved (value of all returns), incomplete.
function Reagents.Cost(consumed, returned, opts)
    opts = opts or {}
    returned = returned or {}
    local t = opts.time or time()
    local lines, total, saved, incomplete = {}, 0, 0, false
    local function Market(key)
        return (opts.market and opts.market[key]) or Reagents.UnitPrice(key)
    end
    for key, qty in pairs(consumed) do
        local market = Market(key)
        local back = math.min(returned[key] or 0, qty)
        local net = qty - back
        local purchased, purchaseCost = 0, 0
        if net > 0 and ns.Purchases then purchased, purchaseCost = ns.Purchases.Take(key, net, t) end
        local crafted, craftedCost = 0, 0
        if net - purchased > 0 and ns.Lots then crafted, craftedCost = ns.Lots.TakeReagent(key, net - purchased, t) end
        local rest = net - purchased - crafted
        if rest > 0 and not market then incomplete = true end
        local cost = purchaseCost + craftedCost + rest * (market or 0)
        lines[#lines + 1] = { key = key, qty = qty, unit = net > 0 and cost / net or (market or 0), market = market or 0,
            purchased = purchased, crafted = crafted, returned = back, cost = cost }
        total = total + cost
    end
    for key, qty in pairs(returned) do
        local market = Market(key) or 0
        saved = saved + market * qty
        local excess = qty - (consumed[key] or 0)
        if excess > 0 then total = total - market * excess end
    end
    table.sort(lines, function(a, b)
        if a.cost == b.cost then return a.key < b.key end
        return a.cost > b.cost
    end)
    return lines, total, saved, incomplete
end
