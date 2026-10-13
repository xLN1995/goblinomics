if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/WorkshopUI.lua
-- Workshop tab: sub-tabs Overview, Recipes, Crafting orders, Salvage (and views
-- other parts add, e.g. concentration and cooldowns), one filter row below them
-- (period, profession, character), the selected view below that. A recipe opens
-- its details (cost per craft, history) in a dialog. Shared helpers for the
-- views live here (money, item labels, quality marks, key figure cards). Plus the
-- "Workshop" settings section and the dashboard card.
local _, ns = ...

local UI = {}
ns.WorkshopUI = UI

local OWNER = "Goblinomics_Workshop.Tab"
local ALL = "all"

local API, L
local module
local tab = {}
local state = { view = "overview", period = 30, profession = ALL, char = ALL, expanded = {},
    sort = "profit", reverse = false, search = "" }
UI.state = state

-- Helpers shared by the pages --------------------------------------------------------
local function Money(copper, opts)
    if copper == nil then return "-" end
    opts = opts or {}
    opts.abbreviate = true
    return API.Money.Format(math.floor(copper + 0.5), opts)
end
UI.Money = Money

function UI.ShortName(charKey) return charKey and (charKey:match("^([^%-]+)") or charKey) or "-" end

function UI.QualityMark(q, size)
    if not q or q == 0 then return "" end
    if CreateAtlasMarkup then
        return CreateAtlasMarkup("Professions-Icon-Quality-Tier" .. q .. "-Small", size or 16, size or 16)
    end
    return "Q" .. q
end

--- label (link or name with the speculative logo), link, itemID
function UI.ItemLabel(key)
    local id = key and tonumber(key:match("^i:(%d+)"))
    local name, link
    if id then name, link = C_Item.GetItemInfo(id) end
    return (link or name or key or "?") .. (key and API.ItemMarks:Inline(key) or ""), link, id
end

function UI.ItemIcon(key)
    local id = key and tonumber(key:match("^i:(%d+)"))
    return id and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or 134400
end

--- Small stat block: dim label above a value; returns the value fontstring.
function UI.Stat(parent, x, y, label, width)
    local Theme = API.Theme
    local l = Theme.Text(parent, 10, Theme.colors.textDim)
    l:SetPoint("TOPLEFT", x, y)
    l:SetText(label:upper())
    local v = Theme.Text(parent, "title", Theme.colors.text)
    v:SetPoint("TOPLEFT", x, y - 13)
    if width then v:SetWidth(width) end
    v:SetWordWrap(false)
    return v
end

function UI.Section(parent, text, x, y)
    local Theme = API.Theme
    local fs = Theme.Text(parent, "caption", Theme.colors.textDim)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text:upper())
    return fs
end

--- Card with 3-4 large key figures side by side; returns card, { key = value fontstring } and its height.
-- items = { { key, label } }; every figure gets `width` (default 140).
function UI.KeyFigures(parent, items, width)
    local Theme = API.Theme
    local C, S = Theme.colors, Theme.space
    local card = API.Widgets.Card(parent)
    local height = S.PAD * 2 + 34
    card:SetHeight(height)
    local values = {}
    for i, item in ipairs(items) do
        local x = (i - 1) * ((width or 140) + S.GAP)
        local l = Theme.Text(card.body, "caption", C.textDim)
        l:SetPoint("TOPLEFT", x, 0)
        l:SetText(item[2]:upper())
        local v = Theme.Text(card.body, "value", C.text)
        v:SetPoint("TOPLEFT", x, -14)
        v:SetWidth(width or 140)
        v:SetWordWrap(false)
        values[item[1]] = v
    end
    return card, values, height
end

--- "Sold crafts x, Crafting orders y (, Salvage z)" with coloured amounts.
function UI.BreakdownText(b, separator)
    local parts = {
        L["Sold crafts"] .. " " .. Money(b.sales, { color = true, sign = true }),
        L["Crafting orders"] .. " " .. Money(b.orders, { color = true, sign = true }),
    }
    if b.salvage ~= 0 then
        parts[#parts + 1] = L["Salvage"] .. " " .. Money(b.salvage, { color = true, sign = true })
    end
    return table.concat(parts, separator or "\n")
end

--- Filter for the stats from the current state.
function UI.Filter()
    return { from = API.Periods:From(state.period), profession = state.profession ~= ALL and state.profession or nil,
        char = state.char ~= ALL and state.char or nil }
end

-- Views ------------------------------------------------------------------------------
-- Sub-tabs of the Workshop; build(parent) returns { frame, Refresh(filter) }.
-- noPeriod: the period filter does not apply (it is hidden for that view).
local VIEWS = {
    { id = "overview", label = function() return L["Overview"] end,
        build = function(parent) return ns.WorkshopSummary.Build(parent) end },
    { id = "recipes", label = function() return L["Recipes"] end,
        build = function(parent) return ns.WorkshopRecipes.Build(parent) end },
    { id = "orders", label = function() return L["Crafting orders"] end,
        build = function(parent) return ns.WorkshopDetail.BuildOrders(parent) end },
    { id = "salvage", label = function() return L["Salvage"] end,
        build = function(parent) return ns.WorkshopDetail.BuildSalvage(parent) end },
}
UI.VIEWS = VIEWS

local function View(id)
    for _, v in ipairs(VIEWS) do if v.id == id then return v end end
    return VIEWS[1]
end

--- Register a further view (e.g. concentration and cooldowns), shown after the others.
function UI.AddView(spec)
    for i, v in ipairs(VIEWS) do
        if v.id == spec.id then VIEWS[i] = spec return end
    end
    VIEWS[#VIEWS + 1] = spec
end

local function Page(id)
    tab.pages = tab.pages or {}
    local page = tab.pages[id]
    if not page then
        page = View(id).build(tab.content)
        tab.pages[id] = page
    end
    return page
end

function UI.Show(id)
    state.view = View(id).id
    if module then module.db.settings.view = state.view end
    UI.Refresh()
end

function UI.Refresh()
    if not tab.content then return end
    local view = View(state.view)
    state.view = view.id
    tab.views:Refresh()
    tab.period:SetShown(not view.noPeriod)
    for id, page in pairs(tab.pages or {}) do page.frame:SetShown(id == view.id) end
    local page = Page(view.id)
    page.frame:Show()
    page.Refresh(UI.Filter())
    if tab.detail and tab.detail:IsShown() then UI.RefreshRecipe() end
end

function UI.CurrentPage()
    return tab.pages and tab.pages[state.view]
end

-- Recipe details: a dialog with the recipe page (cost per craft, history).
function UI.OpenRecipe(recipe, quality)
    state.detail = { recipe = recipe, quality = quality }
    if not tab.detail then
        tab.detail = API.Widgets.Dialog({ title = L["Recipe"], width = 560, height = 470, name = "GoblinomicsWorkshopRecipe" })
        tab.detailPage = ns.WorkshopDetail.BuildRecipe(tab.detail.body)
    end
    tab.detail:Show()
    UI.RefreshRecipe()
end

function UI.RefreshRecipe()
    if not tab.detailPage or not state.detail then return end
    tab.detailPage.Refresh(UI.Filter(), state.detail)
end

function UI.DetailPage() return tab.detailPage end

-- Order details: a dialog with the order page; the button counts it without own cost.
function UI.OpenOrder(order)
    if not tab.order then
        tab.order = API.Widgets.Dialog({ title = L["Crafting orders"], width = 520, height = 420,
            name = "GoblinomicsWorkshopOrder", buttons = {
                { text = L["Count without own cost"], width = 180, onClick = function()
                    local o = tab.orderPage.order
                    if o and not o.manual then
                        ns.Orders.ClearCost(o)
                        tab.orderPage.Refresh(o)
                        tab.order.buttons[1]:Hide()
                    end
                end },
                { text = L["Close"], primary = true, onClick = function() tab.order:Hide() end },
            } })
        tab.orderPage = ns.WorkshopDetail.BuildOrder(tab.order.body)
    end
    tab.order.buttons[1]:SetShown(not order.manual)
    tab.order:Show()
    tab.orderPage.Refresh(order)
end

function UI.OrderPage() return tab.orderPage end

-- Salvage details: a dialog with the salvaged item's yields and their use.
function UI.OpenSalvage(row)
    if not tab.salvage then
        tab.salvage = API.Widgets.Dialog({ title = L["Salvage"], width = 520, height = 420,
            name = "GoblinomicsWorkshopSalvage" })
        tab.salvagePage = ns.WorkshopDetail.BuildSalvageItem(tab.salvage.body)
    end
    tab.salvage:Show()
    tab.salvagePage.Refresh(row)
end

function UI.SalvagePage() return tab.salvagePage end

local function Choices(field)
    local seen = {}
    local list = { { value = ALL, label = field == "profession" and L["All professions"] or L["All characters"] } }
    for _, r in ipairs(module.db.root.crafts) do
        local v = field == "profession" and r.profession or r.char
        if v and not seen[v] then
            seen[v] = true
            list[#list + 1] = { value = v, label = field == "profession" and v or UI.ShortName(v) }
        end
    end
    table.sort(list, function(a, b)
        if a.value == ALL then return true end
        if b.value == ALL then return false end
        return a.label < b.label
    end)
    return list
end

--- Header: the sub-tabs, below them one filter row for every view (period left,
-- profession and character right); the views fill the space below.
local function BuildTab(page)
    local W = API.Widgets
    local Theme = API.Theme
    local S = Theme.space
    local filterY = -(S.CONTROL_H + S.SM)
    local headerH = 2 * S.CONTROL_H + S.SM
    state.view = module.db.settings.view or state.view
    tab.views = W.Segmented(page, function()
        local list = {}
        for _, v in ipairs(VIEWS) do list[#list + 1] = { value = v.id, label = v.label() } end
        return list
    end, function() return state.view end, function(value) UI.Show(value) end, { min = 80 })
    tab.views:SetPoint("TOPLEFT", 0, 0)
    tab.period = API.Periods:Control(page, function() return state.period end, function(value)
        state.period = value
        UI.Refresh()
    end, true)
    tab.period:SetPoint("TOPLEFT", 0, filterY)
    local x = -S.GUTTER
    local function dropdown(choices, field)
        local d = W.Dropdown(page, choices, function() return state[field] end, function(value)
            state[field] = value
            UI.Refresh()
        end, { size = "M" })
        d:SetPoint("TOPRIGHT", page, "TOPRIGHT", x, filterY)
        x = x - S.DROP_M - S.SM
    end
    dropdown(function() return Choices("char") end, "char")
    dropdown(function() return Choices("profession") end, "profession")

    tab.content = CreateFrame("Frame", nil, page)
    tab.content:SetPoint("TOPLEFT", 0, -(headerH + S.GAP))
    tab.content:SetPoint("BOTTOMRIGHT", -S.GUTTER, 0)
    UI.Refresh()
end

-- Settings ---------------------------------------------------------------------------
local function BuildSettings(parent, y)
    local settings = module.db.settings
    local form = API.Form.New(parent, y)
    local function number(label, description, field)
        form:Number({ label = label, description = description, min = 1,
            get = function() return settings[field] end,
            set = function(n) settings[field] = n end })
    end
    form:Group(L["Retention"])
    number(L["Keep craft details (days)"], L["Older crafts and sales are kept as totals per recipe."], "retentionDays")
    number(L["Open stock for (days)"],
        L["Crafted items that are not sold after this time leave the open stock; a later sale still counts."], "lotDays")
    number(L["Concentration value over (days)"], L["Period for the gold value of one concentration point."],
        "concentrationDays")
    form:Note(L["Realized profit needs the Ledger module: it reports the auction house sales."])

    local function changed()
        API.Emit("WORKSHOP_PROFESSIONS", {})
    end
    form:Group(L["Concentration & cooldowns"],
        L["Concentration is read when you log in or open a profession window, and computed from then on."])
    form:Slider({ label = L["Notify at concentration"],
        description = L["A notice comes when a character's concentration reaches this value."],
        min = 100, max = 1000, step = 50,
        get = function() return settings.concentrationThreshold end,
        set = function(v)
            settings.concentrationThreshold = v
            changed()
        end })
    form:Toggle({ label = L["Toast while playing"],
        description = L["When a character's concentration is full or a cooldown is ready."],
        get = function() return settings.notifyToast end,
        set = function(on) settings.notifyToast = on end })
    form:Toggle({ label = L["Overview at login"],
        description = L["A window with every character when something is full or ready after login."],
        get = function() return settings.notifyChat end,
        set = function(on) settings.notifyChat = on end })
    form:Toggle({ label = L["Line in the minimap tooltip"], description = L["How many are ready and when the next one is."],
        get = function() return settings.notifyTooltip end,
        set = function(on) settings.notifyTooltip = on end })
    form:Group(L["Market"], L["Your own list of products with their price trend."])
    form:Slider({ label = L["Warn at a price drop of (%)"],
        description = L["Compared with the 14-day price; only items you have in stock."], min = 5, max = 50, step = 1,
        get = function() return settings.pulseThreshold end,
        set = function(v) settings.pulseThreshold = v; API.Emit("WORKSHOP_PULSE", {}) end })
    form:Toggle({ label = L["Toast on a price drop"], description = L["Once per item and day."],
        get = function() return settings.pulseToast end,
        set = function(on) settings.pulseToast = on end })
    form:Toggle({ label = L["Price drops in chat at login"], description = L["One line with every warned item."],
        get = function() return settings.pulseChat end,
        set = function(on) settings.pulseChat = on end })

    local chars = {}
    for charKey, c in pairs(module.db.root.chars) do
        if type(c) == "table" and (next(c.professions or {}) or next(c.cooldowns or {})) then chars[#chars + 1] = charKey end
    end
    table.sort(chars)
    if #chars > 0 then
        form:Group(L["Characters"], L["Switched off characters are left out of concentration and cooldowns."])
        for _, charKey in ipairs(chars) do
            form:Toggle({ label = UI.ShortName(charKey), description = charKey,
                get = function() return not settings.professionsHidden[charKey] end,
                set = function(on)
                    settings.professionsHidden[charKey] = (not on) or nil
                    changed()
                end })
        end
    end
    return form:Finish()
end

-- Dashboard card ---------------------------------------------------------------------
local function RegisterCard()
    local Theme = API.Theme
    local C = Theme.colors
    API.UI:RegisterWidget({
        id = "workshop.crafting", order = 40, size = "quarter", height = 120,
        events = { "WORKSHOP_CRAFT", "WORKSHOP_MATCH", "WORKSHOP_ORDER" },
        title = function() return L["Crafting"] end,
        build = function(f)
            f.value = Theme.Text(f, 16, C.gold)
            f.value:SetPoint("TOPLEFT", 12, -28)
            f.lines = Theme.Text(f, 10, C.textDim)
            f.lines:SetPoint("TOPLEFT", 12, -52)
            f.lines:SetPoint("RIGHT", f, "RIGHT", -12, 0)
            f.lines:SetJustifyH("LEFT")
        end,
        refresh = function(f, context)
            local filter = { from = context.from }
            local b = ns.Stats.Breakdown(filter)
            f.value:SetText(Money(b.total, { color = true, sign = true }))
            local best
            for _, r in ipairs(ns.Stats.Recipes(filter)) do
                if r.sold > 0 then best = r break end
            end
            f.lines:SetText(table.concat({
                L["Sold crafts"] .. " " .. Money(b.sales, { color = true, sign = true }),
                L["Crafting orders"] .. " " .. Money(b.orders, { color = true, sign = true }),
                best and (L["Best"] .. ": " .. (best.output and (UI.ItemLabel(best.output)) or best.name)) or "",
            }, "\n"))
        end,
    })
end

function UI.Enable(m)
    module = m
    API, L = ns.API, ns.L
    API.UI:RegisterTab({
        id = "workshop", title = function() return L["Workshop"] end, order = 40,
        build = BuildTab,
        onShow = function()
            UI.Refresh()
            for _, event in ipairs({ "WORKSHOP_CRAFT", "WORKSHOP_MATCH", "WORKSHOP_ORDER", "WORKSHOP_PROFESSIONS",
                "WORKSHOP_PULSE" }) do
                API.On(event, UI.Refresh, OWNER)
            end
        end,
        onHide = function()
            for _, event in ipairs({ "WORKSHOP_CRAFT", "WORKSHOP_MATCH", "WORKSHOP_ORDER", "WORKSHOP_PROFESSIONS",
                "WORKSHOP_PULSE" }) do
                API.Off(event, OWNER)
            end
        end,
    })
    API.UI:RegisterSettings({ id = "workshop", title = function() return L["Workshop"] end, order = 50,
        build = BuildSettings, description = function() return L["How long craft details and open stock are kept."] end })
    RegisterCard()
end
