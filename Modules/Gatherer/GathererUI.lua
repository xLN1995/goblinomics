if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Gatherer/GathererUI.lua
-- Gatherer tab (the detailed view): the running session with the full
-- breakdown, the farm list, and for the selected farm its statistics, for raid
-- and dungeon farms the lockouts of every character per difficulty (who can
-- still run it), and the session history (click: summary, right-click: delete).
-- Also the "Gatherer" settings section.
local _, ns = ...
local CODE = setmetatable({}, { __index = function(_, k) return ns.API.Theme.CODE[k] end })

local UI = {}
ns.GathererUI = UI

local OWNER = "Goblinomics_Gatherer.Tab"
local SESSION_H = 108
local LIST_W = 250
local LOCK_ROWS, LOCK_ROW_H, LOCK_NAME_W, LOCK_MAX_COLS = 5, 18, 110, 6

local API, L
local module
local tab = {}
local state = { selected = nil }
local ticker

local function Money(copper, opts)
    opts = opts or {}
    opts.abbreviate = true
    return API.Money.Format(copper, opts)
end

local function ShortName(charKey)
    return charKey and (charKey:match("^([^%-]+)") or charKey) or "-"
end

local function SetEnabled(button, on)
    button:SetEnabled(on)
    button:SetAlpha(on and 1 or 0.4)
end

--- Rows of the farm list: every farm, plus ad-hoc sessions when there are any.
function UI.FarmRows()
    local rows = {}
    for _, farm in ipairs(ns.Farms.List()) do
        local stats = ns.Farms.Stats(farm.id)
        rows[#rows + 1] = { id = farm.id, name = farm.name, category = farm.category, runs = stats.runs,
            avgGPH = stats.avgGPH }
    end
    local adhoc = ns.Farms.Stats(nil)
    if adhoc.runs > 0 then
        rows[#rows + 1] = { id = ns.Farms.AD_HOC, name = L["Ad-hoc sessions"], runs = adhoc.runs, avgGPH = adhoc.avgGPH }
    end
    return rows
end

--- Rows of the history list of a farm id (AD_HOC for ad-hoc sessions).
function UI.HistoryRows(id)
    local rows = {}
    local farmId = id ~= ns.Farms.AD_HOC and id or nil
    for _, summary in ipairs(ns.Farms.History(farmId)) do
        rows[#rows + 1] = { summary = summary, farmId = farmId, index = #rows + 1 }
    end
    return rows
end

-- Current session ---------------------------------------------------------------
local function BuildSessionPanel(page)
    local Theme = API.Theme
    local C = Theme.colors
    local p = CreateFrame("Frame", nil, page)
    p:SetPoint("TOPLEFT", 0, API.Theme.space.CONTENT_TOP)
    p:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    p:SetHeight(SESSION_H)
    Theme.Backdrop(p, C.panel, C.border)
    p.title = Theme.Text(p, "caption", C.textDim)
    p.title:SetPoint("TOPLEFT", 12, -10)
    p.title:SetPoint("RIGHT", -12, 0)
    p.title:SetWordWrap(false)
    p.cells = {}
    local columns = { 10, 200 }
    for col = 1, 2 do
        for row = 1, 4 do
            local label = Theme.Text(p, 11, C.textDim)
            label:SetPoint("TOPLEFT", columns[col], -30 - (row - 1) * 18)
            local value = Theme.Text(p, 12, C.text)
            value:SetPoint("TOPLEFT", columns[col] + 90, -30 - (row - 1) * 18)
            value:SetWidth(90)
            value:SetJustifyH("RIGHT")
            p.cells[#p.cells + 1] = { label = label, value = value }
        end
    end
    p.items = {}
    for row = 1, 4 do
        local fs = Theme.Text(p, 11, C.text)
        fs:SetPoint("TOPLEFT", 460, -30 - (row - 1) * 18)
        fs:SetPoint("RIGHT", -10, 0)
        fs:SetWordWrap(false)
        p.items[row] = fs
    end
    return p
end

local function RefreshSession()
    local p = tab.session
    if not p then return end
    local s = ns.Session.Active()
    for _, cell in ipairs(p.cells) do cell.label:SetText(""); cell.value:SetText("") end
    for _, fs in ipairs(p.items) do fs:SetText("") end
    if not s then
        p.title:SetText(L["No active session. Start one with the button above or /gob farm start [name]."])
        return
    end
    local farm = s.farmId and ns.Farms.Get(s.farmId) or nil
    local duration = ns.Session.Duration(s)
    local status = s.runningSince and "" or ("  " .. CODE.dim .. (s.autoPaused and L["Auto-paused"] or L["Paused"]) .. "|r")
    local v = ns.Session.Evaluate(s)
    local nodes = ns.NodeTracker.Text(s.nodes, duration, v.total)
    p.title:SetText(("%s  %s%s%s"):format(farm and farm.name or L["Ad-hoc session"],
        ns.Valuation.FormatDuration(duration), nodes and ("  " .. CODE.dim .. nodes .. "|r") or "", status))
    local gph = Money(v.gph)
    local repair = ns.Session.RepairRate() and Money(-v.repair) or L["unknown"]
    local cells = {
        { L["Market Value"], Money(v.market) }, { L["Raw Gold"], Money(v.rawGold) },
        { L["Vendor"], Money(v.vendor) }, { L["Speculative"], CODE.dim .. Money(v.speculative) .. "|r" },
        { L["Repair"], repair }, { L["Total"], CODE.gold .. Money(v.total) .. "|r" },
        { L["Realized"], Money(v.realized, { color = true }) }, { L["GPH"], gph },
    }
    if not API.Price:HasRole("saleRate") then table.remove(cells, 4) end   -- speculative needs TSM
    for i = 1, #p.cells do
        local cell = cells[i]
        p.cells[i].label:SetText(cell and cell[1] or "")
        p.cells[i].value:SetText(cell and cell[2] or "")
    end
    for row = 1, 4 do
        local item = v.items[row]
        if item then
            p.items[row]:SetText(("%s%s x%d  %s"):format(s.links[item.key] or ns.Valuation.ItemName(item.key),
                API.ItemMarks:Inline(item.key), item.quantity, item.value > 0 and Money(item.value) or "-"))
        end
    end
end

-- Farm list and detail ----------------------------------------------------------------
local function InitFarmRow(row, data)
    if not row.name then
        local Theme = API.Theme
        API.Widgets.RowBackground(row)
        row.zebra:Hide()
        row.name = Theme.Text(row, "body", Theme.colors.text)
        row.name:SetPoint("LEFT", 10, 0)
        row.name:SetPoint("RIGHT", -110, 0)
        row.name:SetWordWrap(false)
        row.runs = Theme.Text(row, "small", Theme.colors.textDim)
        row.runs:SetPoint("RIGHT", -76, 0)
        row.runs:SetJustifyH("RIGHT")
        row.gph = Theme.Text(row, "small", Theme.colors.text)
        row.gph:SetPoint("RIGHT", -4, 0)
        row.gph:SetWidth(70)
        row.gph:SetJustifyH("RIGHT")
        row:SetScript("OnClick", function(self) UI.Select(self.data.id) end)
    end
    row.data = data
    local selected = data.id == state.selected
    API.Widgets.MarkSelected(row, selected)
    row.name:SetText(data.name)
    row.runs:SetText(tostring(data.runs))
    row.gph:SetText(data.runs > 0 and Money(data.avgGPH) or "-")
end

local historyColumns   -- Widgets.Columns: date, character, duration, total, GPH

local function InitHistoryRow(row, data)
    if not row.cells then
        historyColumns:Cells(row)
        API.Widgets.RowBackground(row)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(self, button)
            local d = self.data
            if button == "RightButton" then
                API.Widgets.Confirm({
                    title = L["Delete session"], text = L["Delete this session from the history?"],
                    confirmText = L["Delete"],
                    onConfirm = function() ns.Farms.DeleteSummary(d.farmId, d.summary) end,
                })
            else
                ns.Summary.Show(d.summary)
            end
        end)
        row:SetScript("OnEnter", function(self)
            API.Widgets.ShowTooltip(self, L["Session"], { L["Click: summary. Right-click: delete."] })
        end)
        row:SetScript("OnLeave", API.Widgets.HideTooltip)
    end
    row.data = data
    local s = data.summary
    local c = row.cells
    row.zebra:SetShown((data.index or 0) % 2 == 0)
    c.date:SetText(s.started and API.Format:Date(s.started, "stamp") or "-")
    c.char:SetText(ShortName(s.char))
    c.duration:SetText(ns.Valuation.FormatDuration(s.duration))
    c.total:SetText(Money(s.total or 0))
    c.gph:SetText(Money(s.gph or 0))
end

local function DetailLines(id)
    if not id then return L["Create a farm or select one."], "", "" end
    if id == ns.Farms.AD_HOC then
        local stats = ns.Farms.Stats(nil)
        return L["Ad-hoc sessions"], API.Lf("Runs: %d   Average GPH: %s   Best GPH: %s", stats.runs,
            Money(stats.avgGPH), Money(stats.bestGPH)), ""
    end
    local farm = ns.Farms.Get(id)
    if not farm then return "", "", "" end
    local stats = ns.Farms.Stats(id)
    local title = ("%s  " .. CODE.dim .. "%s|r"):format(farm.name, ns.CategoryName(farm.category))
    local line = API.Lf("Runs: %d   Average GPH: %s   Best GPH: %s", stats.runs, Money(stats.avgGPH),
        Money(stats.bestGPH))
    if stats.nodes > 0 then
        line = line .. "   " .. API.Lf("Nodes per hour: %s   Gold per node: %s", stats.nodesPerHour or "-",
            Money(stats.goldPerNode or 0))
    end
    local expected = {}
    if farm.zone then
        local zone = API.Nodes:ZoneName(farm.zone) or ("#" .. farm.zone)
        local count = 0
        for _, n in ipairs(farm.nodes or {}) do
            for _, node in ipairs(API.Nodes:List(farm.zone, n.type)) do
                if node.id == n.id then count = count + 1 end
            end
        end
        -- without own runs only the known nodes, no gold estimate
        expected[#expected + 1] = zone .. (count > 0 and (": " .. API.Lf("%d known nodes", count)) or "")
            .. (stats.runs == 0 and ("  " .. L["not farmed yet"]) or "")
    end
    if farm.instance then expected[#expected + 1] = farm.instance.name end
    if #farm.expectedHighlights > 0 then
        local names = {}
        for i, key in ipairs(farm.expectedHighlights) do
            if i > 5 then names[#names + 1] = "..." break end
            names[#names + 1] = ns.Valuation.ItemName(key)
        end
        expected[#expected + 1] = L["Highlights"] .. ": " .. table.concat(names, ", ")
    end
    return title, line, table.concat(expected, "   ")
end

-- Lockout overview ------------------------------------------------------------------
local function ColumnWidth(grid)
    local n = math.max(1, math.min(#grid.columns, LOCK_MAX_COLS))
    return math.max(48, math.floor(300 / n))
end

local function InitLockRow(row, data)
    if not row.name then
        local Theme = API.Theme
        row.name = Theme.Text(row, 11, Theme.colors.text)
        row.name:SetPoint("LEFT", 4, 0)
        row.name:SetWidth(LOCK_NAME_W)
        row.name:SetWordWrap(false)
        row.cells = {}
        for i = 1, LOCK_MAX_COLS do
            local fs = Theme.Text(row, 11, Theme.colors.text)
            fs:SetJustifyH("CENTER")
            row.cells[i] = fs
        end
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.05)
        row:SetScript("OnEnter", function(self)
            local d, lines = self.data, {}
            local now = time()
            for _, col in ipairs(d.grid.columns) do
                local cell = d.row.cells[col.id]
                lines[#lines + 1] = ("%s: %s%s"):format(col.name, ns.Lockouts.CellText(cell, d.grid.total),
                    cell and ("  " .. CODE.dim .. API.Lf("reset in %s", ns.Lockouts.FormatRemaining(cell.resetAt - now))
                        .. "|r") or "")
            end
            API.Widgets.ShowTooltip(self, ShortName(d.row.char), lines)
        end)
        row:SetScript("OnLeave", API.Widgets.HideTooltip)
    end
    row.data = data
    local grid, r = data.grid, data.row
    local color = r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]
    local name = ShortName(r.char)
    row.name:SetText(color and ("|c%s%s|r"):format(color.colorStr, name) or name)
    local width = ColumnWidth(grid)
    for i = 1, LOCK_MAX_COLS do
        local fs, col = row.cells[i], grid.columns[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", LOCK_NAME_W + 8 + (i - 1) * width, 0)
        fs:SetWidth(width)
        fs:SetText(col and ns.Lockouts.CellText(r.cells[col.id], grid.total) or "")
    end
end

local function BuildLockouts(page, left, top)
    local Theme = API.Theme
    local C = Theme.colors
    local lock = {}
    lock.summary = Theme.Text(page, 11, C.textDim)
    lock.summary:SetPoint("TOPLEFT", left, top)
    lock.summary:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    lock.summary:SetWordWrap(false)
    lock.header = CreateFrame("Frame", nil, page)
    lock.header:SetPoint("TOPLEFT", left, top - 18)
    lock.header:SetPoint("RIGHT", page, "RIGHT", -API.Theme.space.GUTTER, 0)
    lock.header:SetHeight(18)
    lock.headerName = Theme.Text(lock.header, 11, C.textDim)
    lock.headerName:SetPoint("LEFT", 4, 0)
    lock.headerName:SetText(L["Character"])
    lock.headerCols = {}
    for i = 1, LOCK_MAX_COLS do
        local fs = Theme.Text(lock.header, 11, C.textDim)
        fs:SetJustifyH("CENTER")
        fs:SetWordWrap(false)
        lock.headerCols[i] = fs
    end
    lock.list = API.Widgets.ScrollList(page, { rowHeight = LOCK_ROW_H, init = InitLockRow })
    lock.list.box:SetPoint("TOPLEFT", left, top - 36)
    lock.list.box:SetPoint("RIGHT", page, "RIGHT", -API.Theme.space.GUTTER, 0)
    lock.list.box:SetHeight(LOCK_ROWS * LOCK_ROW_H)
    lock.empty = API.Widgets.EmptyState(lock.list.box, L["No lockout data yet: log in once with every character at max level."])
    lock.height = 36 + LOCK_ROWS * LOCK_ROW_H + 8
    return lock
end

--- Summary line: per difficulty how many characters can still run the instance.
function UI.LockoutSummary(grid)
    local parts = {}
    for _, col in ipairs(grid.columns) do
        parts[#parts + 1] = ("%s %d/%d"):format(col.name, col.free, col.count)
    end
    return L["Can still run"] .. ": " .. table.concat(parts, "  \194\183  ")
end

local function SetLockoutsShown(shown)
    local lock = tab.lock
    lock.summary:SetShown(shown)
    lock.header:SetShown(shown)
    lock.list.box:SetShown(shown)
    if not shown then
        -- the bar shows itself again on the next data update when it is scrollable
        lock.list.bar:Hide()
        lock.empty:Hide()
    end
end

local function RefreshLockouts(farm)
    local lock = tab.lock
    local grid = farm and ns.Lockouts.Grid(farm)
    SetLockoutsShown(grid ~= nil)
    local histTop = tab.detailTop - 60 - (grid and lock.height or 0)
    tab.histHeader:ClearAllPoints()
    tab.histHeader:SetPoint("TOPLEFT", tab.detailLeft, histTop)
    tab.histHeader:SetPoint("RIGHT", tab.page, "RIGHT", -API.Theme.space.GUTTER, 0)
    tab.history.box:ClearAllPoints()
    tab.history.box:SetPoint("TOPLEFT", tab.detailLeft, histTop - 20)
    tab.history.box:SetPoint("BOTTOMRIGHT", -API.Theme.space.GUTTER, 0)
    if not grid then return end
    lock.summary:SetText(#grid.rows > 0 and UI.LockoutSummary(grid) or "")
    local width = ColumnWidth(grid)
    for i = 1, LOCK_MAX_COLS do
        local fs, col = lock.headerCols[i], grid.columns[i]
        fs:ClearAllPoints()
        fs:SetPoint("LEFT", LOCK_NAME_W + 8 + (i - 1) * width, 0)
        fs:SetWidth(width)
        fs:SetText(col and col.name or "")
    end
    local data = {}
    for _, row in ipairs(grid.rows) do data[#data + 1] = { row = row, grid = grid } end
    lock.list:SetData(data)
    lock.empty:SetShown(#data == 0)
end

function UI.Refresh()
    if not tab.farms then return end
    local rows = UI.FarmRows()
    local found = false
    for _, r in ipairs(rows) do if r.id == state.selected then found = true end end
    if not found then state.selected = rows[1] and rows[1].id or nil end
    tab.farms:SetData(rows)
    local title, line, expected = DetailLines(state.selected)
    tab.detailTitle:SetText(title)
    tab.detailStats:SetText(line)
    tab.detailExpected:SetText(expected)
    local farm = state.selected and state.selected ~= ns.Farms.AD_HOC and ns.Farms.Get(state.selected) or nil
    RefreshLockouts(farm)
    tab.history:SetData(state.selected and UI.HistoryRows(state.selected) or {})
    local isFarm = state.selected ~= nil and state.selected ~= ns.Farms.AD_HOC
    SetEnabled(tab.edit, isFarm)
    SetEnabled(tab.delete, isFarm)
    SetEnabled(tab.export, isFarm)
    local active = ns.Session.Active() ~= nil
    tab.start:SetText(active and L["Stop session"] or L["Start session"])
    RefreshSession()
end

function UI.Select(id)
    state.selected = id
    UI.Refresh()
end

function UI.Selected() return state.selected end

local function StartOrStop()
    if ns.Session.Active() then
        ns.HUD.StopAndSummarize()
    else
        local id = state.selected
        ns.Session.Start(id ~= ns.Farms.AD_HOC and id or nil)
    end
end

local function BuildTab(page)
    local W = API.Widgets
    local Theme = API.Theme
    local C = Theme.colors
    local buttons = {
        { "new", L["New farm"], function() ns.FarmEditor.Open(nil) end },
        { "edit", L["Edit"], function() ns.FarmEditor.Open(ns.Farms.Get(state.selected)) end },
        { "delete", L["Delete"], function()
            local farm = ns.Farms.Get(state.selected)
            if not farm then return end
            W.Confirm({
                title = L["Delete farm"], text = API.Lf("Delete %s and its session history?", farm.name),
                confirmText = L["Delete"], onConfirm = function() ns.Farms.Delete(farm.id) end,
            })
        end },
        { "start", L["Start session"], StartOrStop },
        { "export", L["Export"], function() if ns.Strings then ns.Strings.ShowExport(state.selected) end end },
        { "import", L["Import"], function() if ns.Strings then ns.Strings.ShowImport() end end },
    }
    local x = 0
    for _, b in ipairs(buttons) do
        local width = b[1] == "start" and 120 or 100
        local button = W.Button(page, b[2], { width = width, onClick = b[3] })
        button:SetPoint("TOPLEFT", x, 0)
        x = x + width + 6
        tab[b[1]] = button
    end
    tab.session = BuildSessionPanel(page)

    local top = -34 - SESSION_H - 10
    local header = CreateFrame("Frame", nil, page)
    header:SetPoint("TOPLEFT", 0, top)
    header:SetSize(LIST_W, 18)
    local hName = Theme.Text(header, 11, C.textDim)
    hName:SetPoint("LEFT", 6, 0)
    hName:SetText(L["Farm"])
    local hRuns = Theme.Text(header, 11, C.textDim)
    hRuns:SetPoint("RIGHT", -76, 0)
    hRuns:SetText(L["Runs"])
    local hGph = Theme.Text(header, 11, C.textDim)
    hGph:SetPoint("RIGHT", -4, 0)
    hGph:SetText(L["Avg GPH"])
    tab.farms = W.ScrollList(page, { rowHeight = 22, init = InitFarmRow })
    tab.farms.box:SetPoint("TOPLEFT", 0, top - 20)
    tab.farms.box:SetPoint("BOTTOMLEFT", 0, 0)
    tab.farms.box:SetWidth(LIST_W)

    local left = LIST_W + API.Theme.space.MASTER_GAP
    tab.detailTitle = Theme.Text(page, "title", C.gold)
    tab.detailTitle:SetPoint("TOPLEFT", left, top)
    tab.detailTitle:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    tab.detailTitle:SetWordWrap(false)
    tab.detailStats = Theme.Text(page, 11, C.text)
    tab.detailStats:SetPoint("TOPLEFT", left, top - 20)
    tab.detailStats:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    tab.detailExpected = Theme.Text(page, 11, C.textDim)
    tab.detailExpected:SetPoint("TOPLEFT", left, top - 38)
    tab.detailExpected:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    tab.detailExpected:SetWordWrap(false)

    tab.page, tab.detailLeft, tab.detailTop = page, left, top
    tab.lock = BuildLockouts(page, left, top - 60)
    historyColumns = W.Columns({
        { key = "date", label = L["Date"], width = 96 }, { key = "char", label = L["Character"] },
        { key = "duration", label = L["Duration"], width = 62, align = "RIGHT" },
        { key = "total", label = L["Total"], width = 84, align = "RIGHT" },
        { key = "gph", label = L["GPH"], width = 78, align = "RIGHT" },
    })
    tab.histHeader = historyColumns:Header(page)
    tab.history = W.ScrollList(page, { rowHeight = API.Theme.space.ROW, init = InitHistoryRow })
    UI.Refresh()
end

local function StopTicker()
    if ticker then ticker:Cancel(); ticker = nil end
end

local function OnShow()
    UI.Refresh()
    API.On("GATHERER_SESSION", UI.Refresh, OWNER)
    API.On("GATHERER_FARMS", UI.Refresh, OWNER)
    StopTicker()
    ticker = C_Timer.NewTicker(1, function()
        if ns.Session.IsRunning() then RefreshSession() end
    end)
end

local function OnHide()
    API.Off("GATHERER_SESSION", OWNER)
    API.Off("GATHERER_FARMS", OWNER)
    StopTicker()
end

-- Settings ---------------------------------------------------------------------------
local function BuildSettings(parent, y)
    local Theme = API.Theme
    local C = Theme.colors
    local settings = module.db.settings
    local form = API.Form.New(parent, y)

    form:Group(L["Notifications"])
    form:Number({ label = L["Notify about loot from value (gold)"],
        description = L["During a session you get a notification for every loot stack worth at least this much."]
            .. " " .. L["0 = off. Each farm can set its own value."],
        get = function() return settings.highlightThreshold end,
        set = function(n) settings.highlightThreshold = n end })
    form:Sound({ label = L["Highlight sound"], description = L["Plays with a loot notification."],
        get = function() return settings.highlightSound end,
        set = function(value) settings.highlightSound = value end, default = ns.Highlights.DEFAULT_SOUND })
    form:Sound({ label = L["Sound for mounts and legendary items"], description = L["Plays for especially rare loot."],
        get = function() return settings.specialSound end,
        set = function(value) settings.specialSound = value end, default = ns.Highlights.DEFAULT_SPECIAL_SOUND })

    form:Group(L["Sessions"])
    form:Number({ label = L["Auto-pause after (minutes without loot)"],
        description = L["0 = off. The idle minutes before the pause do not count."],
        get = function() return settings.autoPauseMinutes end,
        set = function(n)
            settings.autoPauseMinutes = n
            ns.Session.ScheduleAutoPause()
        end })
    form:Toggle({ label = L["Lock the HUD"], description = L["The session HUD can no longer be moved."],
        get = function() return settings.hudLocked end,
        set = function(on) settings.hudLocked = on end })

    form:Group(L["Watchlist"], L["Items on the watchlist always get a notification, whatever their value."])
    local listText
    local function RefreshList()
        local names = {}
        for _, key in ipairs(ns.Highlights.Watchlist()) do names[#names + 1] = ns.Valuation.ItemName(key) end
        listText:SetText(#names > 0 and table.concat(names, ", ") or L["No items on the watchlist."])
    end
    form:Custom(30, function(box)
        listText = Theme.Text(box, 11, C.text)
        listText:SetPoint("TOPLEFT")
        listText:SetPoint("RIGHT", box, "RIGHT", 0, 0)
        listText:SetJustifyV("TOP")
    end)
    form:Text({ label = L["Add or remove"],
        description = L["Enter an item ID or link and press Enter to add it; the same item again removes it."],
        width = 200, get = function() return "" end,
        set = function(t)
            local key = ns.FarmEditor.ItemKeyFromText(t)
            if not key then return false, L["Enter an item ID or an item link."] end
            ns.Highlights.SetWatched(key, not ns.Highlights.IsWatched(key), nil)
            RefreshList()
            return true
        end })
    form:Buttons({ label = L["Share"], description = L["Export the watchlist as a string or import one."],
        buttons = {
            { text = L["Export watchlist"], width = 140, onClick = function() ns.Strings.ShowWatchlistExport() end },
            { text = L["Import"], width = 100, onClick = function() ns.Strings.ShowImport() end },
        } })
    RefreshList()
    API.On("GATHERER_FARMS", function(_, p) if p.action == "watchlist" then RefreshList() end end,
        "Goblinomics_Gatherer.Settings")
    return form:Finish()
end

-- Dashboard card ---------------------------------------------------------------------
--- Sessions in the period: { sessions, total, best = summary with the best GPH }.
function UI.FarmingSummary(from)
    local result = { sessions = 0, total = 0 }
    for id, list in pairs(module.db.root.history) do
        for _, s in ipairs(list) do
            if (s.started or 0) >= from then
                result.sessions = result.sessions + 1
                result.total = result.total + (s.total or 0)
                if (s.duration or 0) >= 300 and (not result.best or (s.gph or 0) > (result.best.gph or 0)) then
                    result.best = s
                    result.bestFarm = id
                end
            end
        end
    end
    return result
end

local function RegisterCard()
    local Theme = API.Theme
    local C = Theme.colors
    API.UI:RegisterWidget({
        id = "gatherer.farming", order = 41, size = "quarter", height = 120, events = { "GATHERER_SESSION" },
        title = function() return L["Farming"] end,
        build = function(f)
            f.value = Theme.Text(f, 16, C.gold)
            f.value:SetPoint("TOPLEFT", 12, -28)
            f.lines = Theme.Text(f, 10, C.textDim)
            f.lines:SetPoint("TOPLEFT", 12, -52)
            f.lines:SetPoint("RIGHT", f, "RIGHT", -12, 0)
            f.lines:SetJustifyH("LEFT")
        end,
        refresh = function(f, context)
            local s = UI.FarmingSummary(context.from)
            f.value:SetText(Money(s.total))
            local best = s.best
            local farm = best and best.farmName or (best and L["Ad-hoc session"])
            f.lines:SetText(table.concat({
                API.Lf("%d sessions", s.sessions),
                best and (L["Best"] .. ": " .. farm) or "",
                best and API.Lf("%s per hour", Money(best.gph)) or "",
            }, "\n"))
        end,
    })
end

function UI.Enable(m)
    module = m
    API, L = ns.API, ns.L
    API.UI:RegisterTab({
        id = "gatherer", title = function() return L["Gatherer"] end, order = 30,
        build = BuildTab, onShow = OnShow, onHide = OnHide,
    })
    API.UI:RegisterSettings({ id = "gatherer", title = function() return L["Gatherer"] end, order = 40,
        build = BuildSettings, description = function() return L["Loot notifications, sessions and the watchlist."] end })
    RegisterCard()
end

function UI.Disable()
    OnHide()
end
