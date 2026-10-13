if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/FarmEditor.lua
-- Dialog to create or edit a farm: name, category, for raid and dungeon farms
-- the instance (menu by expansion from the Encounter Journal), for gathering and
-- fishing farms the zone and its nodes (several at once, from the node source, e.g.
-- GatherMate2), highlight threshold and the expected highlights (items that always
-- notify the player when looted in a session of this farm). Items are added by
-- shift-clicking an item while the item box has focus (hook on the client's link
-- insertion, as AceGUI does), from the farm's last session or, for the rare finds,
-- from what the chosen nodes gave so far.
local _, ns = ...

local FarmEditor = {}
ns.FarmEditor = FarmEditor

local MAX_ITEM_ROWS = 8
local NODE_ROWS = 6
local HEIGHT = 530
local RARE_SHARE = 0.1   -- items below this share of a node's loot count as rare finds

local dialog
local form = {}
local hooked = false

local function ItemKeyFromText(text)
    local API = ns.API
    if type(text) ~= "string" then return nil end
    local link = text:match("|H(item:[^|]+)|h")
    if link then return API.ItemKey.FromLink("|H" .. link .. "|h") end
    local id = tonumber(strtrim(text))
    return id and ("i:" .. id) or nil
end
FarmEditor.ItemKeyFromText = ItemKeyFromText

local function AddItem(list, key)
    if key and not tContains(list, key) then list[#list + 1] = key end
end

local function OnInsertLink(text)
    if dialog and dialog:IsShown() and dialog.itemBox:HasFocus() then
        local key = ItemKeyFromText(text)
        if key then
            AddItem(form.expectedHighlights, key)
            dialog.itemBox:SetText("")
            FarmEditor.RefreshItems()
        end
        return true
    end
end

local function HookLinks()
    if hooked then return end
    hooked = true
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
    elseif ChatEdit_InsertLink then
        hooksecurefunc("ChatEdit_InsertLink", OnInsertLink)
    end
end

--- Label left, control from x = 140 at offset y in a parent frame (like the dialog's :Row).
local function Row(parent, label, control, y)
    local Theme = ns.API.Theme
    local fs = Theme.Text(parent, "body", Theme.colors.textDim)
    fs:SetPoint("TOPLEFT", 0, y - 4)
    fs:SetWidth(132)
    fs:SetWordWrap(false)
    fs:SetText(label or "")
    control:ClearAllPoints()
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", 140, y)
    return fs
end

local function Field(d, label, y, width, field, numeric, tooltipLines, parent)
    local W = ns.API.Widgets
    local box = W.EditBox(parent or d.body, {
        width = width,
        get = function() return form[field] and tostring(form[field]) or "" end,
        set = function(text) form[field] = text; return true end,
        tooltip = tooltipLines and label, tooltipLines = tooltipLines,
    })
    box:SetScript("OnTextChanged", function(self) form[field] = self:GetText() end)
    if numeric then box:SetNumeric(true) end
    if parent then Row(parent, label, box, y) else d:Row(label, box, y) end
    return box
end

--- Instance choices by expansion (submenus) for raids or dungeons of the category.
local function InstanceChoices()
    local L = ns.L
    local isRaid = form.category == "raid"
    local list = { { value = "none", label = L["None"] } }
    for _, expansion in ipairs(ns.Instances.Catalog(isRaid)) do
        local children = {}
        for _, inst in ipairs(expansion.instances) do children[#children + 1] = { value = inst.journalID, label = inst.name } end
        list[#list + 1] = { label = expansion.name, children = children }
    end
    return list
end

local function SetInstance(journalID)
    form.instance = nil
    if journalID ~= "none" then
        local isRaid = form.category == "raid"
        for _, expansion in ipairs(ns.Instances.Catalog(isRaid)) do
            for _, inst in ipairs(expansion.instances) do
                if inst.journalID == journalID then
                    form.instance = { journalID = inst.journalID, mapID = inst.mapID, name = inst.name, isRaid = isRaid }
                end
            end
        end
    end
    FarmEditor.RefreshInstance()
end

-- Zone and nodes ------------------------------------------------------------------------------
local function ZoneLabel(id)
    return ns.API.Nodes:ZoneName(id) or ("#" .. tostring(id))
end

--- The player's zone first, then every zone with known nodes by name.
local function ZoneChoices()
    local Nodes = ns.API.Nodes
    local current = Nodes:CurrentZone()
    local list, rest = {}, {}
    if current then
        list[1] = { value = current, label = ZoneLabel(current) .. " (" .. ns.L["current"] .. ")" }
    end
    for _, id in ipairs(Nodes:Zones()) do
        if id ~= current then rest[#rest + 1] = { value = id, label = ZoneLabel(id) } end
    end
    table.sort(rest, function(a, b) return a.label < b.label end)
    for _, c in ipairs(rest) do list[#list + 1] = c end
    return list
end

local function HasNode(nodeType, id)
    for _, n in ipairs(form.nodes) do
        if n.type == nodeType and n.id == id then return true end
    end
    return false
end

local function ToggleNode(nodeType, id)
    for i = #form.nodes, 1, -1 do
        if form.nodes[i].type == nodeType and form.nodes[i].id == id then
            table.remove(form.nodes, i)
            return
        end
    end
    form.nodes[#form.nodes + 1] = { type = nodeType, id = id }
end

--- Rows of the node list: a caption per type, then its nodes with their count.
function FarmEditor.NodeRows(zone)
    local rows = {}
    if not zone then return rows end
    for _, group in ipairs(ns.API.Nodes:Catalog(zone)) do
        rows[#rows + 1] = { kind = "type", label = group.label }
        for _, n in ipairs(group.nodes) do
            rows[#rows + 1] = { kind = "node", type = group.type, id = n.id, name = n.name, icon = n.icon, count = n.count }
        end
    end
    return rows
end

local function InitNodeRow(row, data)
    local Theme, W = ns.API.Theme, ns.API.Widgets
    local C, S = Theme.colors, Theme.space
    row.data = data
    if not row.name then
        row.toggle = W.Checkbox(row, "", function() return row.data.kind == "node" and HasNode(row.data.type, row.data.id) end,
            function()
                ToggleNode(row.data.type, row.data.id)
                dialog.fromNodes:SetShown(#form.nodes > 0)
            end, { width = 36 })
        row.toggle:SetPoint("LEFT", 0, 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", 40, 0)
        row.count = Theme.Text(row, "small", C.textDim)
        row.count:SetPoint("RIGHT", -S.SM, 0)
        row.count:SetJustifyH("RIGHT")
        row.name = Theme.Text(row, "body", C.text)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.name:SetPoint("RIGHT", row.count, "LEFT", -S.SM, 0)
    end
    row.name:ClearAllPoints()
    row.name:SetPoint("RIGHT", row.count, "LEFT", -S.SM, 0)
    if data.kind == "type" then
        row.toggle:Hide()
        row.icon:Hide()
        row.count:SetText("")
        row.name:SetPoint("LEFT", 0, 0)
        row.name:SetText(Theme.Colorize(data.label, C.textDim))
        return
    end
    row.toggle:Show()
    row.toggle:Refresh()
    row.icon:SetTexture(data.icon or 134400)
    row.icon:Show()
    row.name:SetPoint("LEFT", row.icon, "RIGHT", S.SM, 0)
    row.name:SetText(data.name)
    row.count:SetText(tostring(data.count))
end

local function Build()
    local API = ns.API
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local L = ns.L
    local d
    d = W.Dialog({ name = "GoblinomicsGathererFarmEditor", width = 480, height = HEIGHT,
        buttons = {
            { text = L["Cancel"], onClick = function() d:Hide() end },
            { text = L["Save"], primary = true, onClick = function() FarmEditor.Save() end },
        } })
    local step = S.CONTROL_H + S.SM
    local y = 0
    d.fields = {}
    d.fields.name = Field(d, L["Name"], y, 260, "name")
    y = y - step
    d.category = W.Dropdown(d.body, function()
        local list = {}
        for _, cat in ipairs(ns.CATEGORIES) do list[#list + 1] = { value = cat, label = ns.CategoryName(cat) } end
        return list
    end, function() return form.category end, function(v)
        form.category = v
        FarmEditor.RefreshInstance()
    end, { size = "L" })
    d:Row(L["Category"], d.category, y)
    y = y - step
    d.instance = W.Dropdown(d.body, InstanceChoices, function()
        return form.instance and form.instance.journalID or "none"
    end, SetInstance, { width = 260, placeholder = L["Choose instance"], emptyValue = "none",
        display = function() return form.instance and form.instance.name end, tooltip = L["Instance"],
        tooltipLines = { L["Choose the instance by expansion. The overview then shows its lockouts per character."] } })
    d.instanceLabel = d:Row(L["Dungeon"], d.instance, y)
    -- gathering and fishing: zone in the same row, the node list below it
    d.zone = W.Dropdown(d.body, ZoneChoices, function() return form.zone end, function(v)
        form.zone = v
        wipe(form.nodes)
        FarmEditor.RefreshNodes()
    end, { width = 260, placeholder = L["Choose zone"], display = function(v) return v and ZoneLabel(v) end })
    d.zoneLabel = d:Row(L["Zone"], d.zone, y)
    d.nodeHint = Theme.Text(d.body, "small", C.textDim)
    d.nodeHint:SetPoint("TOPLEFT", 140, y - 5)
    d.nodeHint:SetPoint("RIGHT", d.body, "RIGHT", 0, 0)
    d.nodeHint:SetJustifyH("LEFT")
    d.nodeHint:SetText(L["With GatherMate2 you can choose the zone and its nodes."])
    y = y - step
    d.nodeTop = y
    d.nodesLabel = Theme.Text(d.body, "body", C.textDim)
    d.nodesLabel:SetPoint("TOPLEFT", 0, y - 4)
    d.nodesLabel:SetText(L["Nodes"])
    d.nodeList = W.ScrollList(d.body, { rowHeight = S.ROW, init = InitNodeRow })
    d.nodeList.box:SetPoint("TOPLEFT", 140, y)
    d.nodeList.box:SetPoint("RIGHT", d.body, "RIGHT", -S.PAD, 0)
    d.nodeList.box:SetHeight(NODE_ROWS * S.ROW)
    d.nodeEmpty = W.EmptyState(d.nodeList.box, L["No known nodes in this zone."])

    -- everything below moves down while the node list is shown
    d.lower = CreateFrame("Frame", nil, d.body)
    d.lower:SetPoint("RIGHT", d.body, "RIGHT", 0, 0)
    d.lower:SetPoint("BOTTOM", d.body, "BOTTOM", 0, 0)
    local lower = d.lower
    y = 0
    d.fields.highlightThreshold = Field(d, L["Notify from value (gold)"], y, 110, "highlightThreshold", true, {
        L["During a session of this farm you get a notification for every loot stack worth at least this much."],
        L["Leave empty to use the value from the Gatherer settings."],
    }, lower)
    d.thresholdHint = Theme.Text(lower, "caption", C.textDim)
    d.thresholdHint:SetPoint("TOPLEFT", 140 + 110 + S.SM, y - 6)
    d.thresholdHint:SetPoint("RIGHT", lower, "RIGHT", 0, 0)
    y = y - step
    d.itemBox = W.EditBox(lower, { width = 170, get = function() return "" end, set = function(text)
        AddItem(form.expectedHighlights, ItemKeyFromText(text))
        FarmEditor.RefreshItems()
        return true
    end, tooltip = L["Expected highlights"],
        tooltipLines = { L["You get a notification whenever you loot one of these items in a session of this farm, whatever its value."],
            L["Click here, then shift-click an item, or type an item ID and press Enter."] } })
    Row(lower, L["Expected highlights"], d.itemBox, y)
    d.fromSession = W.Button(lower, L["From last session"], { auto = true, onClick = function()
        FarmEditor.AddFromLastSession()
    end, tooltip = L["From last session"],
        tooltipLines = { L["Adds every item of the farm's current or last session."] } })
    y = y - step
    -- the add buttons in their own row, so both fit next to each other
    d.fromSession:SetPoint("TOPLEFT", lower, "TOPLEFT", 140, y)
    d.fromNodes = W.Button(lower, L["From nodes"], { auto = true, onClick = function()
        FarmEditor.AddFromNodes()
    end, tooltip = L["From nodes"],
        tooltipLines = { L["Adds the rare finds of the chosen nodes, from what they gave you so far."] } })
    d.fromNodes:SetPoint("LEFT", d.fromSession, "RIGHT", S.SM, 0)
    y = y - step

    d.itemRows = {}
    for i = 1, MAX_ITEM_ROWS do
        local row = CreateFrame("Frame", nil, lower)
        row:SetHeight(S.ROW)
        row:SetPoint("TOPLEFT", 0, y - (i - 1) * (S.ROW + 2))
        row:SetPoint("RIGHT", lower, "RIGHT", 0, 0)
        row.name = Theme.Text(row, "body", C.text)
        row.name:SetPoint("LEFT", 0, 0)
        row.name:SetPoint("RIGHT", -30, 0)
        row.name:SetWordWrap(false)
        row.delete = W.IconButton(row, "close", { onClick = function()
            for j = #form.expectedHighlights, 1, -1 do
                if form.expectedHighlights[j] == row.key then table.remove(form.expectedHighlights, j) end
            end
            FarmEditor.RefreshItems()
        end })
        row.delete:SetPoint("RIGHT", 0, 0)
        d.itemRows[i] = row
    end
    d.more = Theme.Text(lower, "caption", C.textDim)
    d.more:SetPoint("TOPLEFT", 0, y - MAX_ITEM_ROWS * (S.ROW + 2))

    d.error = Theme.Text(d.body, "small", C.loss)
    d.error:SetPoint("BOTTOMLEFT", 0, 0)
    return d
end

--- Show the instance menu only for raid and dungeon farms; drop a choice of the other kind.
function FarmEditor.RefreshInstance()
    if not dialog then return end
    local L = ns.L
    local isInstance = ns.IsInstanceCategory(form.category)
    if form.instance and (not isInstance or form.instance.isRaid ~= (form.category == "raid")) then
        form.instance = nil
    end
    dialog.instanceLabel:SetShown(isInstance)
    dialog.instance:SetShown(isInstance)
    dialog.instanceLabel:SetText(form.category == "raid" and L["Raid"] or L["Dungeon"])
    dialog.instance:Refresh()
    FarmEditor.RefreshNodes()
end

--- Whether the node list is shown: a gathering or fishing farm and a node source.
function FarmEditor.ShowsNodes()
    return ns.Farms.HasNodes(form.category) and ns.API.Nodes:Available()
end

--- Zone row, node list (or the hint without a node source) and the layout below them.
function FarmEditor.RefreshNodes()
    if not dialog then return end
    local S = ns.API.Theme.space
    local hasNodes = ns.Farms.HasNodes(form.category)
    local shows = FarmEditor.ShowsNodes()
    dialog.zoneLabel:SetShown(hasNodes)
    dialog.zone:SetShown(shows)
    dialog.nodeHint:SetShown(hasNodes and not shows)
    dialog.nodesLabel:SetShown(shows)
    dialog.nodeList.box:SetShown(shows)
    dialog.nodeList.bar:SetShown(shows)
    dialog.zone:Refresh()
    local rows = shows and FarmEditor.NodeRows(form.zone) or {}
    dialog.nodeRows = rows
    dialog.nodeList:SetData(rows)
    dialog.nodeEmpty:SetShown(shows and #rows == 0)
    local extra = shows and (NODE_ROWS * S.ROW + S.SM) or 0
    dialog.lower:ClearAllPoints()
    dialog.lower:SetPoint("TOPLEFT", dialog.body, "TOPLEFT", 0, dialog.nodeTop - extra)
    dialog.lower:SetPoint("BOTTOMRIGHT", dialog.body, "BOTTOMRIGHT", 0, 0)
    dialog:SetHeight(HEIGHT + extra)
    dialog.fromNodes:SetShown(shows and #form.nodes > 0)
    -- without "From last session" (new farm) the node button takes its place
    dialog.fromNodes:ClearAllPoints()
    if dialog.fromSession:IsShown() then
        dialog.fromNodes:SetPoint("LEFT", dialog.fromSession, "RIGHT", S.SM, 0)
    else
        dialog.fromNodes:SetPoint("TOPLEFT", dialog.fromSession, "TOPLEFT", 0, 0)
    end
end

function FarmEditor.RefreshItems()
    if not dialog then return end
    local items = form.expectedHighlights
    for i = 1, MAX_ITEM_ROWS do
        local row, key = dialog.itemRows[i], items[i]
        row.key = key
        if key then
            row.name:SetText(ns.Valuation.ItemName(key) .. ns.API.ItemMarks:Inline(key))
            row:Show()
        else
            row:Hide()
        end
    end
    dialog.more:SetText(#items > MAX_ITEM_ROWS and ns.API.Lf("%d more items", #items - MAX_ITEM_ROWS) or "")
end

function FarmEditor.AddFromLastSession()
    local source
    local active = ns.Session.Active()
    if active and active.farmId == form.id then
        source = active.items
    else
        local last = form.id and ns.Farms.History(form.id)[1]
        source = last and last.items
    end
    if not source then return end
    local keys = {}
    for key in pairs(source) do keys[#keys + 1] = key end
    table.sort(keys)
    for _, key in ipairs(keys) do AddItem(form.expectedHighlights, key) end
    FarmEditor.RefreshItems()
end

--- Add the rare finds of the chosen nodes: items below RARE_SHARE of what they gave.
function FarmEditor.AddFromNodes()
    local loot = ns.NodeTracker.Loot(form.nodes)
    local total = 0
    for _, qty in pairs(loot) do total = total + qty end
    if total == 0 then return end
    local keys = {}
    for key, qty in pairs(loot) do
        if qty / total < RARE_SHARE then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do AddItem(form.expectedHighlights, key) end
    FarmEditor.RefreshItems()
end

--- Open for a farm (nil = new farm).
function FarmEditor.Open(farm)
    HookLinks()
    dialog = dialog or Build()
    local L = ns.L
    wipe(form)
    form.id = farm and farm.id or nil
    form.name = farm and farm.name or ""
    form.category = farm and farm.category or "gathering"
    form.instance = farm and farm.instance and CopyTable(farm.instance) or nil
    form.highlightThreshold = farm and farm.highlightThreshold or nil
    form.zone = farm and farm.zone or (not farm and ns.API.Nodes:Available() and ns.API.Nodes:CurrentZone()) or nil
    form.nodes = {}
    for _, n in ipairs(farm and farm.nodes or {}) do form.nodes[#form.nodes + 1] = { type = n.type, id = n.id } end
    form.expectedHighlights = {}
    for _, key in ipairs(farm and farm.expectedHighlights or {}) do form.expectedHighlights[#form.expectedHighlights + 1] = key end
    dialog:SetTitle(farm and L["Edit farm"] or L["New farm"])
    for field, box in pairs(dialog.fields) do
        box:SetText(form[field] and tostring(form[field]) or "")
    end
    dialog.category:Refresh()
    FarmEditor.RefreshInstance()
    dialog.error:SetText("")
    local default = ns.Highlights.Threshold(nil)
    dialog.thresholdHint:SetText(default > 0
        and ns.API.Lf("empty: %s (settings)", ns.API.Money.Format(default, { abbreviate = true }))
        or L["empty: off (settings)"])
    dialog.fromSession:SetShown(farm ~= nil)
    FarmEditor.RefreshNodes()
    FarmEditor.RefreshItems()
    dialog:Show()
end

--- Spec for Farms.Create/Update from the form.
function FarmEditor.Spec()
    return {
        name = form.name, category = form.category,
        instance = form.instance or false,
        highlightThreshold = tonumber(form.highlightThreshold) or 0,
        expectedHighlights = form.expectedHighlights,
        zone = form.zone or false, nodes = form.nodes,
    }
end

function FarmEditor.Save()
    local spec = FarmEditor.Spec()
    local farm, err
    if form.id then
        farm, err = ns.Farms.Update(form.id, spec)
    else
        farm, err = ns.Farms.Create(spec)
    end
    if not farm then
        dialog.error:SetText(err == "name" and ns.L["Please enter a name."] or tostring(err))
        return false
    end
    dialog:Hide()
    if ns.GathererUI then ns.GathererUI.Select(farm.id) end
    return true
end

FarmEditor.Form = function() return form end
