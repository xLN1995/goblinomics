if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/ProfessionPopup.lua
-- Small window with concentration and cooldowns of every character: a header per
-- character (class colour, "2 ready" / "next in 3h"), under it one bar per
-- profession line ("full in") and the recipe cooldowns as chips, two per row
-- (ready or the time left). Opens after login when something is full or ready
-- (setting notifyChat) and with /gob conc. Waits while in combat or in the
-- restricted mode. While shown it refreshes once a minute and on changes.
local _, ns = ...

local Popup = {}
ns.ProfessionPopup = Popup

local OWNER = "Goblinomics_Workshop.Popup"
local WIDTH = 440
local MAX_ROWS = 14
local CHIPS = 2          -- cooldown chips per row
local BAR_W, STATUS_W = 150, 70

local module, frame
local waiting = false
local generation = 0

local function Settings() return module.db.settings end

-- Rows ------------------------------------------------------------------------------------------
--- Flat rows from Professions.Overview (already sorted, the character due first on
-- top): { kind = "char", entry, ready, dueAt }, { kind = "profession", entry,
-- profession } and { kind = "cooldowns", entry, cooldowns = { up to CHIPS } }.
-- ready counts what is full or ready; dueAt is the next entry still to come.
function Popup.Rows(overview, now)
    local rows = {}
    for _, e in ipairs(overview) do
      if #e.professions > 0 or #e.cooldowns > 0 then
        local ready, dueAt = 0, nil
        local function Count(at)
            if not at then return end
            if at <= now then ready = ready + 1 elseif not dueAt or at < dueAt then dueAt = at end
        end
        for _, p in ipairs(e.professions) do Count(p.fullAt) end
        for _, cd in ipairs(e.cooldowns) do Count(cd.readyAt) end
        rows[#rows + 1] = { kind = "char", entry = e, ready = ready, dueAt = dueAt }
        for _, p in ipairs(e.professions) do
            rows[#rows + 1] = { kind = "profession", entry = e, profession = p }
        end
        for i = 1, #e.cooldowns, CHIPS do
            local chunk = {}
            for j = i, math.min(i + CHIPS - 1, #e.cooldowns) do chunk[#chunk + 1] = e.cooldowns[j] end
            rows[#rows + 1] = { kind = "cooldowns", entry = e, cooldowns = chunk }
        end
      end
    end
    return rows
end

--- Window height for n rows (between 1 and MAX_ROWS shown, more scroll).
function Popup.Height(n)
    local S = ns.API.Theme.space
    local shown = math.max(1, math.min(MAX_ROWS, n))
    return 36 + S.PAD + shown * S.ROW + S.CONTROL_H + 2 * S.PAD
end

-- Frame -----------------------------------------------------------------------------------------
local function Chip(parent)
    local API = ns.API
    local Theme, W = API.Theme, API.Widgets
    local C, S = Theme.colors, Theme.space
    local chip = CreateFrame("Button", nil, parent)
    chip:SetHeight(S.ROW - 4)
    chip.icon = chip:CreateTexture(nil, "ARTWORK")
    chip.icon:SetSize(16, 16)
    chip.icon:SetPoint("LEFT", 0, 0)
    chip.time = Theme.Text(chip, "small", C.text)
    chip.time:SetPoint("RIGHT", -S.XS, 0)
    chip.time:SetJustifyH("RIGHT")
    chip.label = Theme.Text(chip, "small", C.text)
    chip.label:SetPoint("LEFT", chip.icon, "RIGHT", S.XS, 0)
    chip.label:SetPoint("RIGHT", chip.time, "LEFT", -S.XS, 0)
    chip.label:SetJustifyH("LEFT")
    chip.label:SetWordWrap(false)
    chip:SetScript("OnEnter", function(self)
        if self.cooldown then ns.WorkshopProfessions.Tooltip(self, { kind = "cooldown", cooldown = self.cooldown }) end
    end)
    chip:SetScript("OnLeave", W.HideTooltip)
    return chip
end

local function InitRow(row, data)
    local API, L = ns.API, ns.L
    local Theme, W = API.Theme, API.Widgets
    local C, S = Theme.colors, Theme.space
    local View = ns.WorkshopProfessions
    if not row.label then
        W.RowBackground(row)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(16, 16)
        row.icon:SetPoint("LEFT", S.PAD, 0)
        row.label = Theme.Text(row, "body", C.text)
        row.label:SetWordWrap(false)
        row.label:SetJustifyH("LEFT")
        row.status = Theme.Text(row, "body", C.text)
        row.status:SetPoint("RIGHT", -S.SM, 0)
        row.status:SetJustifyH("RIGHT")
        row.status:SetWidth(STATUS_W)
        row.bar = W.ProgressBar(row, BAR_W, 14)
        row.bar:SetPoint("RIGHT", row.status, "LEFT", -S.SM, 0)
        row.chips = {}
        for i = 1, CHIPS do row.chips[i] = Chip(row) end
        row:SetScript("OnEnter", function(self)
            if self.data.kind == "profession" then View.Tooltip(self, self.data) end
        end)
        row:SetScript("OnLeave", W.HideTooltip)
    end
    row.data = data
    local now = time()
    local e = data.entry
    row.label:ClearAllPoints()
    row.icon:Hide()
    row.bar:Hide()
    row.status:SetText("")
    for _, chip in ipairs(row.chips) do chip:Hide() end
    row.label:Show()
    if data.kind == "char" then
        row.zebra:Show()
        row.label:SetPoint("LEFT", S.SM, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", -(S.SM + 140), 0)
        row.label:SetText("|c" .. View.ClassColor(e.class) .. e.name .. "|r")
        row.status:SetWidth(140)
        row.status:SetText(data.ready > 0 and (Theme.CODE.good .. API.Lf("%d ready", data.ready) .. "|r")
            or (data.dueAt and API.Lf("next in %s", API.Format:Remaining(data.dueAt - now)) or ""))
        return
    end
    row.zebra:Hide()
    row.status:SetWidth(STATUS_W)
    if data.kind == "profession" then
        local p = data.profession
        row.icon:SetTexture(p.icon or 134400)
        row.icon:Show()
        row.label:SetPoint("LEFT", row.icon, "RIGHT", S.SM, 0)
        row.label:SetPoint("RIGHT", row.bar, "LEFT", -S.SM, 0)
        row.label:SetText(p.name or "?")
        row.bar:Show()
        row.bar:SetMinMaxValues(0, p.max or 1000)
        row.bar:SetValue(p.current or 0)
        row.bar:SetLabels(tostring(p.current or 0), tostring(p.max or 1000))
        row.status:SetText(View.DueText(p.fullAt, now, L["full"], "in %s"))
        return
    end
    -- cooldowns: chips side by side from the icon column on
    row.label:Hide()
    local rowW = row:GetWidth() or 0
    local width = (rowW > 0 and rowW or (WIDTH - 2 * S.DIALOG_PAD - S.PAD)) - S.PAD - S.SM
    local chipW = math.floor((width - (CHIPS - 1) * S.GAP) / CHIPS)
    for i, chip in ipairs(row.chips) do
        local cd = data.cooldowns[i]
        chip.cooldown = cd
        if cd then
            chip:ClearAllPoints()
            chip:SetPoint("LEFT", row, "LEFT", S.PAD + (i - 1) * (chipW + S.GAP), 0)
            chip:SetWidth(chipW)
            chip.icon:SetTexture(cd.icon or 134400)
            local ready = cd.readyAt and cd.readyAt <= now
            chip.icon:SetDesaturated(not ready)
            chip.label:SetText(ready and cd.name or Theme.Colorize(cd.name or "?", C.textDim))
            chip.time:SetText(View.DueText(cd.readyAt, now, L["ready"], "%s"))
            chip:Show()
        end
    end
end

local function Build()
    local API, L = ns.API, ns.L
    local W, Theme = API.Widgets, API.Theme
    local S = Theme.space
    frame = W.Dialog({ name = "GoblinomicsProfessionPopup", width = WIDTH, height = Popup.Height(1),
        title = L["Concentration & cooldowns"],
        onClose = function() generation = generation + 1 end,
        buttons = {
            { text = L["Open Workshop"], onClick = function()
                frame:Hide()
                API.UI:Show("workshop")
                ns.WorkshopUI.Show("professions")
            end },
            { text = L["Close"], primary = true, onClick = function() frame:Hide() end },
        } })
    frame.list = W.ScrollList(frame.body, { rowHeight = S.ROW, init = InitRow })
    frame.list.box:SetPoint("TOPLEFT", 0, 0)
    frame.list.box:SetPoint("BOTTOMRIGHT", -S.PAD, 0)
    frame.empty = W.EmptyState(frame.list.box, L["No profession data yet: open a profession window once on each character."])
end

--- Fill the window from the stored data; sizes it to its rows.
function Popup.Refresh()
    if not (frame and frame:IsShown()) then return end
    local rows = Popup.Rows(ns.Professions.Overview(module.db.root, Settings(), time()), time())
    frame.rows = rows
    frame:SetHeight(Popup.Height(#rows))
    frame.list:SetData(rows)
    frame.empty:SetShown(#rows == 0)
end

-- once a minute while shown
local function Tick(mine)
    if mine ~= generation or not Popup.IsOpen() then return end
    Popup.Refresh()
    module:After(60, function() Tick(mine) end)
end

local function Blocked()
    return InCombatLockdown() or ns.API.IsRestricted()
end

local function Resume()
    waiting = false
    module:UnregisterEvent("PLAYER_REGEN_ENABLED", OWNER)
    ns.API.Off("RESTRICTED_LEAVE", OWNER)
    Popup.Open()
end

--- Show the window; in combat or the restricted mode it opens afterwards.
function Popup.Open()
    if not module then return end
    if Blocked() then
        if not waiting then
            waiting = true
            module:RegisterEvent("PLAYER_REGEN_ENABLED", Resume, OWNER)
            ns.API.On("RESTRICTED_LEAVE", Resume, OWNER)
        end
        return
    end
    if not frame then Build() end
    local wasShown = frame:IsShown()
    frame:Show()
    Popup.Refresh()
    if not wasShown then
        generation = generation + 1
        local mine = generation
        module:After(60, function() Tick(mine) end)
    end
end

function Popup.IsOpen()
    return frame ~= nil and frame:IsShown()
end

function Popup.Toggle()
    if Popup.IsOpen() then frame:Hide() else Popup.Open() end
end

function Popup.Enable(m)
    module = m
    local API = ns.API
    API.On("WORKSHOP_PROFESSIONS", Popup.Refresh, OWNER)
    API.RegisterCommand("conc", Popup.Toggle, ns.L["- concentration and cooldowns of every character"])
end

function Popup.Disable()
    generation = generation + 1
    waiting = false
    if frame then frame:Hide() end
    if ns.API then
        ns.API.Off("WORKSHOP_PROFESSIONS", OWNER)
        ns.API.Off("RESTRICTED_LEAVE", OWNER)
    end
end
