if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Ledger/LedgerUI.lua
-- Ledger tab: filters (period, character, category, tag, item search), grouping
-- (day, item, category, character), totals without transfers, and a list with
-- collapsible group rows and booking rows. Settings section with the mail rule
-- editor and the remembered trade partners. The dashboard cards live in Cards.lua.
local _, ns = ...

local LUI = {}
ns.LedgerUI = LUI

local API = ns.API
local L = ns.L
local Money = API.Money
local Store = ns.Store
local ALL = "*"
local OWNER_TAB = "Goblinomics_Ledger.Tab"

local ledger
local tab = {}
local state = { period = 7, char = ALL, category = ALL, tag = ALL, search = "", group = "day", expanded = {} }

local function StartOfToday()
    local now = time()
    local t = date("*t", now)
    if type(t) ~= "table" then return now - now % 86400 end
    return now - ((t.hour or 0) * 3600 + (t.min or 0) * 60 + (t.sec or 0))
end
LUI.StartOfToday = StartOfToday

local function From(period) return API.Periods:From(period) end

local function Filter()
    return {
        from = From(state.period),
        char = state.char ~= ALL and state.char or nil,
        category = state.category ~= ALL and state.category or nil,
        tag = state.tag ~= ALL and state.tag or nil,
        search = state.search,
    }
end
LUI.Filter = Filter

local function ShortName(charKey)
    return charKey and (charKey:match("^([^-]+)") or charKey) or "-"
end

local function GroupKey(row)
    if state.group == "item" then return row.itemKey or "" end
    if state.group == "category" then return row.category end
    if state.group == "char" then return row.char or "" end
    return row.day
end

local function GroupLabel(key)
    if state.group == "item" then
        if key == "" then return L["(no item)"] end
        return Store.ItemName(key) or key
    end
    if state.group == "category" then return ns.CategoryName(key) end
    if state.group == "char" then return ShortName(key) end
    return key
end

--- Flat list data for the scroll list: group rows, expanded booking rows.
function LUI.BuildData(rows)
    local groups, order = {}, {}
    for _, row in ipairs(rows) do
        local key = GroupKey(row)
        local g = groups[key]
        if not g then
            g = { kind = "group", key = key, sum = 0, count = 0, rows = {} }
            groups[key] = g
            order[#order + 1] = g
        end
        if row.category ~= "Transfer" then g.sum = g.sum + row.amount end
        g.count = g.count + (row.count or 1)
        g.rows[#g.rows + 1] = row
    end
    if state.group ~= "day" then
        table.sort(order, function(a, b) return math.abs(a.sum) > math.abs(b.sum) end)
    end
    local data = {}
    for _, g in ipairs(order) do
        g.label = GroupLabel(g.key)
        data[#data + 1] = g
        if state.expanded[g.key] then
            for _, row in ipairs(g.rows) do data[#data + 1] = { kind = "tx", row = row } end
        end
    end
    return data
end

local function RowTooltip(owner, data)
    local C = API.Theme.colors
    local row = data.row
    if row.itemKey then
        API.Widgets.ShowItemTooltip(owner, API.ItemKey.ToItemString(row.itemKey))
    else
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(ns.CategoryName(row.category), unpack(C.gold))
    end
    local function Pair(label, value)
        GameTooltip:AddDoubleLine(label, value, C.textDim[1], C.textDim[2], C.textDim[3], 1, 1, 1)
    end
    if row.sub then Pair(L["Type"], row.sub) end
    if row.note then Pair(L["Note"], row.note) end
    if row.quantity and row.quantity > 1 and row.amount then
        Pair(L["Unit price"], Money.Format(math.floor(math.abs(row.amount) / row.quantity + 0.5)))
    end
    if (row.count or 1) > 1 then Pair(L["Bookings"], tostring(row.count)) end
    if row.aggregated then
        GameTooltip:AddLine(L["Daily aggregate (older than the retention window)"], C.textDim[1], C.textDim[2], C.textDim[3])
    end
    GameTooltip:Show()
end

-- One column spec for header and rows (Widgets.Columns): fixed columns left, the item
-- column takes the remaining width, quantity and amount on the right.
local columns   -- Widgets.Columns, built with the tab

local function InitRow(row, data)
    local Theme = API.Theme
    local C = Theme.colors
    if not row.cells then
        columns:Cells(row)
        API.Widgets.RowBackground(row)
        -- a group label spans from the left edge to the quantity column
        row.groupLabel = Theme.Text(row, "small", C.text)
        row.groupLabel:SetPoint("LEFT", Theme.space.SM, 0)
        row.groupLabel:SetPoint("RIGHT", row, "RIGHT", -(3 * Theme.space.SM + 94 + 36), 0)
        row.groupLabel:SetWordWrap(false)
        row.groupBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.groupBg:SetAllPoints()
        row.groupBg:SetColorTexture(unpack(C.zebra))
        row:SetScript("OnClick", function(self)
            local d = self.data
            if d.kind == "group" then
                state.expanded[d.key] = not state.expanded[d.key] or nil
                LUI.Refresh()
            end
        end)
        row:SetScript("OnEnter", function(self) if self.data.kind == "tx" then RowTooltip(self, self.data) end end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    row.data = data
    row.zebra:Hide()
    local c = row.cells
    if data.kind == "group" then
        row.groupBg:Show()
        for _, key in ipairs({ "time", "char", "category", "tag", "item" }) do c[key]:SetText("") end
        row.groupLabel:SetText((state.expanded[data.key] and "- " or "+ ") .. data.label)
        c.qty:SetText(tostring(data.count))
        c.amount:SetText(Money.Format(data.sum, { abbreviate = true, color = true, sign = true }))
    else
        local r = data.row
        row.groupBg:Hide()
        row.groupLabel:SetText("")
        c.time:SetText(r.time and date("%H:%M", r.time) or "-")
        c.char:SetText(ShortName(r.char))
        c.category:SetText(ns.BookingLabel(r.category, r.sub))
        c.tag:SetText(r.tag or "")
        c.item:SetText(r.itemKey and ((Store.ItemName(r.itemKey) or r.itemKey) .. API.ItemMarks:Inline(r.itemKey))
            or (r.note or ""))
        c.qty:SetText(r.quantity and tostring(r.quantity) or "")
        local transfer = r.category == "Transfer"
        c.amount:SetText(transfer and Theme.Colorize(Money.Format(r.amount, { abbreviate = true }), C.textDim)
            or Money.Format(r.amount, { abbreviate = true, color = true, sign = true }))
    end
end

function LUI.Refresh()
    if not tab.list then return end
    local rows = Store.Query(Filter())
    local income, expense, net = Store.Totals(rows)
    tab.totals:SetText(("%s %s   %s %s   %s %s"):format(
        L["Income"], Money.Format(income, { abbreviate = true, color = true }),
        L["Expenses"], Money.Format(expense, { abbreviate = true, color = true }),
        L["Net"], Money.Format(net, { abbreviate = true, color = true, sign = true })))
    tab.list:SetData(LUI.BuildData(rows))
end

local function Choices(list, withAll, allLabel)
    local out = withAll and { { value = ALL, label = allLabel or L["All"] } } or {}
    for _, item in ipairs(list) do out[#out + 1] = item end
    return out
end

local function BuildTab(page)
    local W, Theme = API.Widgets, API.Theme
    local S, C = Theme.space, Theme.colors
    -- first row: period and search; second row: the filters
    local period = API.Periods:Control(page, function() return state.period end, function(v)
        state.period = v
        state.expanded = {}
        LUI.Refresh()
    end, true)
    period:SetPoint("TOPLEFT", 0, 0)
    local search = W.EditBox(page, {
        width = S.DROP_M,
        get = function() return state.search end,
        set = function(text) state.search = text; LUI.Refresh(); return true end,
        tooltip = L["Search item, tag or note"],
    })
    search:SetPoint("TOPRIGHT", page, "TOPRIGHT", -S.GUTTER, 0)
    local x, rowY = 0, -(S.CONTROL_H + S.SM)
    local function dropdown(choices, field)
        local d = W.Dropdown(page, choices, function() return state[field] end, function(v)
            state[field] = v
            state.expanded = {}
            LUI.Refresh()
        end, { size = "M" })
        d:SetPoint("TOPLEFT", x, rowY)
        x = x + S.DROP_M + S.SM
        return d
    end
    dropdown(function()
        local list = {}
        local seen = {}
        for _, key in ipairs(ledger.db.root.charIndex) do
            if not seen[key] then
                seen[key] = true
                list[#list + 1] = { value = key, label = ShortName(key) }
            end
        end
        return Choices(list, true, L["All characters"])
    end, "char")
    dropdown(function()
        local list = {}
        for _, cat in ipairs(Store.CATEGORIES) do list[#list + 1] = { value = cat, label = ns.CategoryName(cat) } end
        return Choices(list, true, L["All categories"])
    end, "category")
    dropdown(function()
        local list = {}
        for _, tag in ipairs(Store.Tags()) do list[#list + 1] = { value = tag, label = tag } end
        return Choices(list, true, L["All tags"])
    end, "tag")
    dropdown(function()
        return { { value = "day", label = L["Group: day"] }, { value = "item", label = L["Group: item"] },
            { value = "category", label = L["Group: category"] }, { value = "char", label = L["Group: character"] } }
    end, "group")
    local top = rowY - S.CONTROL_H - S.GAP
    tab.totals = Theme.Text(page, "body", C.text)
    tab.totals:SetPoint("TOPLEFT", 0, top)
    columns = W.Columns({
        { key = "time", label = L["Time"], width = 42 }, { key = "char", label = L["Character"], width = 84 },
        { key = "category", label = L["Category"], width = 96 }, { key = "tag", label = L["Tag"], width = 72 },
        { key = "item", label = L["Item"] },
        { key = "qty", label = L["Qty"], width = 36, align = "RIGHT" },
        { key = "amount", label = L["Amount"], width = 94, align = "RIGHT" },
    })
    local header = columns:Header(page)
    header:SetPoint("TOPLEFT", 0, top - 24)
    header:SetPoint("RIGHT", page, "RIGHT", -S.GUTTER, 0)
    tab.list = W.ScrollList(page, { rowHeight = S.ROW, init = InitRow })
    tab.list.box:SetPoint("TOPLEFT", 0, top - 24 - S.HEADER_H - S.XS)
    tab.list.box:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
    LUI.Refresh()
end

-- Settings: mail rules and trade partners --------------------------------------------------
local MAX_RULE_ROWS, MAX_PARTNER_ROWS = 12, 8

local function RuleText(rule)
    return ("[%s] %s (%s) -> %s%s"):format(
        rule.field == "sender" and L["Sender"] or L["Subject"], rule.pattern,
        rule.mode == "lua" and "Lua" or L["Wildcard"], ns.CategoryName(rule.category or "Mail"),
        rule.tag and (" / " .. rule.tag) or "")
end

local function BuildSettings(parent, y)
    local W, Theme = API.Widgets, API.Theme
    local C = Theme.colors
    local settings = ledger.db.settings
    local ruleRows, partnerRows = {}, {}
    local refresh, more, noPartners
    local form = API.Form.New(parent, y)

    form:Group(L["Mail rules"], L["Gold from matching mails gets the rule's category and tag, e.g. Boosting."])
    form:Custom(MAX_RULE_ROWS * 24 + 18, function(box)
        for i = 1, MAX_RULE_ROWS do
            local row = CreateFrame("Frame", nil, box)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
            row:SetPoint("RIGHT", box, "RIGHT", 0, 0)
            row.toggle = W.Checkbox(row, "", function() return row.rule and row.rule.enabled ~= false end,
                function(on) if row.rule then row.rule.enabled = on end end, { width = 40 })
            row.toggle:SetPoint("LEFT")
            row.text = Theme.Text(row, 11, C.text)
            row.text:SetPoint("LEFT", 44, 0)
            row.text:SetPoint("RIGHT", -30, 0)
            row.text:SetWordWrap(false)
            row.delete = W.Button(row, "x", { width = 22, height = 20, onClick = function()
                table.remove(settings.mailRules, row.index)
                refresh()
            end })
            row.delete:SetPoint("RIGHT")
            ruleRows[i] = row
        end
        more = Theme.Text(box, 11, C.textDim)
        more:SetPoint("TOPLEFT", 0, -MAX_RULE_ROWS * 24)
    end)

    local form2 = { field = "subject", mode = "wildcard", category = "Mail", pattern = "", tag = "" }
    local S = Theme.space
    -- three rows so everything fits the card: field and pattern; mode, category, tag; add
    form:Custom(3 * S.CONTROL_H + 2 * S.SM, function(box)
        local field = W.Segmented(box, { { value = "subject", label = L["Subject"] }, { value = "sender", label = L["Sender"] } },
            function() return form2.field end, function(v) form2.field = v end, { min = 70 })
        field:SetPoint("TOPLEFT", 0, 0)
        local pattern = W.EditBox(box, { width = 200, get = function() return form2.pattern end,
            set = function(t) form2.pattern = t; return true end, tooltip = L["Pattern"],
            tooltipLines = { L["Wildcards: * any text, ? one character. Lua mode: Lua pattern."] } })
        pattern:SetPoint("LEFT", field, "RIGHT", S.SM, 0)
        pattern:SetPoint("RIGHT", box, "RIGHT", 0, 0)
        pattern:SetScript("OnTextChanged", function(self) form2.pattern = self:GetText() end)
        local rowY = -(S.CONTROL_H + S.SM)
        local mode = W.Segmented(box, { { value = "wildcard", label = L["Wildcard"] }, { value = "lua", label = "Lua" } },
            function() return form2.mode end, function(v) form2.mode = v end, { min = 50 })
        mode:SetPoint("TOPLEFT", 0, rowY)
        local catDrop = W.Dropdown(box, function()
            local list = {}
            for _, cat in ipairs(Store.CATEGORIES) do list[#list + 1] = { value = cat, label = ns.CategoryName(cat) } end
            return list
        end, function() return form2.category end, function(v) form2.category = v end, { size = "S" })
        catDrop:SetPoint("LEFT", mode, "RIGHT", S.SM, 0)
        local tag = W.EditBox(box, { width = 90, get = function() return form2.tag end,
            set = function(t) form2.tag = t; return true end, tooltip = L["Tag"] })
        tag:SetPoint("LEFT", catDrop, "RIGHT", S.SM, 0)
        tag:SetPoint("RIGHT", box, "RIGHT", 0, 0)
        tag:SetScript("OnTextChanged", function(self) form2.tag = self:GetText() end)
        local lastY = 2 * rowY
        local err = Theme.Text(box, "small", C.loss)
        err:SetPoint("TOPLEFT", 0, lastY - 5)
        err:SetPoint("RIGHT", box, "RIGHT", -160, 0)
        local add = W.Button(box, L["Add rule"], { auto = true, onClick = function()
            local rule = { field = form2.field, pattern = strtrim(form2.pattern or ""), mode = form2.mode,
                category = form2.category, tag = strtrim(form2.tag or "") ~= "" and strtrim(form2.tag) or nil }
            local ok, message = ns.Rules.Compile(rule)
            if not ok then
                err:SetText(message or "")
                return
            end
            err:SetText("")
            table.insert(settings.mailRules, rule)
            form2.pattern, form2.tag = "", ""
            pattern:SetText("")
            tag:SetText("")
            refresh()
        end })
        add:SetPoint("TOPRIGHT", box, "TOPRIGHT", 0, lastY)
    end)

    form:Group(L["Remembered trade partners"], L["Trades with these players get the remembered category."])
    form:Custom(MAX_PARTNER_ROWS * 24, function(box)
        for i = 1, MAX_PARTNER_ROWS do
            local row = CreateFrame("Frame", nil, box)
            row:SetHeight(22)
            row:SetPoint("TOPLEFT", 0, -(i - 1) * 24)
            row:SetPoint("RIGHT", box, "RIGHT", 0, 0)
            row.text = Theme.Text(row, 11, C.text)
            row.text:SetPoint("LEFT")
            row.delete = W.Button(row, "x", { width = 22, height = 20, onClick = function()
                ledger.db.root.tradePartners[row.partner] = nil
                refresh()
            end })
            row.delete:SetPoint("RIGHT")
            partnerRows[i] = row
        end
        noPartners = Theme.Text(box, 11, C.textDim)
        noPartners:SetPoint("TOPLEFT", 0, -2)
        noPartners:SetText(L["No trade partners remembered."])
    end)

    refresh = function()
        local rules = settings.mailRules
        for i, row in ipairs(ruleRows) do
            local rule = rules[i]
            row.rule, row.index = rule, i
            row:SetShown(rule ~= nil)
            if rule then
                row.text:SetText(RuleText(rule))
                row.toggle:Refresh()
            end
        end
        more:SetText(#rules > MAX_RULE_ROWS and L["More rules are active but not listed"] or
            (#rules == 0 and L["No rules yet"] or ""))
        local names = {}
        for name in pairs(ledger.db.root.tradePartners) do names[#names + 1] = name end
        table.sort(names)
        for i, row in ipairs(partnerRows) do
            local name = names[i]
            row.partner = name
            row:SetShown(name ~= nil)
            if name then
                local memo = ledger.db.root.tradePartners[name]
                row.text:SetText(("%s -> %s%s"):format(name, ns.CategoryName(memo.category),
                    memo.tag and (" / " .. memo.tag) or ""))
            end
        end
        noPartners:SetShown(#names == 0)
    end
    refresh()
    return form:Finish()
end

function LUI.Enable(module)
    ledger = module
    API.UI:RegisterTab({
        id = "ledger", title = function() return L["Ledger"] end, order = 20,
        build = BuildTab,
        onShow = function()
            LUI.Refresh()
            API.On("LEDGER_CHANGED", LUI.Refresh, OWNER_TAB)
        end,
        onHide = function() API.Off("LEDGER_CHANGED", OWNER_TAB) end,
    })
    API.UI:RegisterSettings({ id = "ledger", title = function() return L["Ledger"] end, order = 30, build = BuildSettings,
        description = function() return L["Mail rules and remembered trade partners."] end })
end
