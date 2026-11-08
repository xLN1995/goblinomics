if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Vault/Goals.lua
-- Gold goals:
--   wealth    reach a wealth figure; progress against the current wealth, with a
--             forecast date from the linear trend of the last 30 days (from 7 days
--             of history on)
--   purchase  save up for something (name, amount); progress against the raw gold
--             of all characters and the warband bank
-- A goal that is reached shows a toast with sound once. Managed in a dialog
-- (dashboard card, Vault tab). Also the dashboard card "Goals & Jealousmeter".
local _, ns = ...

local Goals = {}
ns.Goals = Goals

local API = ns.API
local L = API.L
local TREND_DAYS = 30
local MIN_DAYS = 7

local vault
local dialog

local function List() return vault.db.root.goals end

function Goals.Add(kind, name, amount)
    if (kind ~= "wealth" and kind ~= "purchase") or type(amount) ~= "number" or amount <= 0 then return nil end
    name = name and strtrim(name) or ""
    if name == "" then name = kind == "wealth" and L["Wealth goal"] or L["Purchase goal"] end
    local goal = { id = time() .. "-" .. #List(), kind = kind, name = name, amount = math.floor(amount), created = time() }
    table.insert(List(), goal)
    API.Emit("VAULT_GOALS", { action = "add" })
    return goal
end

function Goals.Remove(goal)
    for i, g in ipairs(List()) do
        if g == goal then
            table.remove(List(), i)
            API.Emit("VAULT_GOALS", { action = "remove" })
            return true
        end
    end
    return false
end

--- current value and progress (0..1) of a goal.
function Goals.Progress(goal)
    local r = ns.Networth.Get()
    local current = 0
    if r then current = goal.kind == "wealth" and r.wealth or r.gold end
    return current, math.min(1, current / math.max(1, goal.amount))
end

--- Least-squares slope (copper per day) of the wealth over the last 30 days, or nil.
function Goals.Trend(now)
    now = now or time()
    local xs, ys = {}, {}
    for i = TREND_DAYS - 1, 0, -1 do
        local h = vault.db.root.history[date("%Y-%m-%d", now - i * 86400)]
        if h and h.wealth then
            xs[#xs + 1], ys[#ys + 1] = -i, h.wealth
        end
    end
    if #xs < MIN_DAYS then return nil end
    local n, sx, sy, sxx, sxy = #xs, 0, 0, 0, 0
    for i = 1, n do
        sx, sy = sx + xs[i], sy + ys[i]
        sxx, sxy = sxx + xs[i] * xs[i], sxy + xs[i] * ys[i]
    end
    local d = n * sxx - sx * sx
    if d == 0 then return nil end
    return (n * sxy - sx * sy) / d
end

--- Forecast time for a wealth goal (nil without enough history or a rising trend).
function Goals.Forecast(goal, now)
    if goal.kind ~= "wealth" then return nil end
    local current = Goals.Progress(goal)
    if current >= goal.amount then return nil end
    local slope = Goals.Trend(now)
    if not slope or slope <= 0 then return nil end
    return (now or time()) + math.ceil((goal.amount - current) / slope) * 86400
end

--- Mark reached goals (toast once).
function Goals.Check()
    local sound = API.Sounds:Resolve(vault.db.settings.jealousmeter.sound, "kit:UI_EPICLOOT_TOAST")
    for _, goal in ipairs(List()) do
        local current = Goals.Progress(goal)
        if not goal.reached and current >= goal.amount then
            goal.reached = time()
            API.UI:Toast({ title = L["Goal reached!"], text = goal.name .. "  " .. API.Money.Format(goal.amount,
                { abbreviate = true }), sound = sound ~= "none" and sound or nil })
        end
    end
end

-- Dialog -------------------------------------------------------------------------------
local ROWS = 8

local function BuildDialog()
    local W, Theme = API.Widgets, API.Theme
    local C, S = Theme.colors, Theme.space
    local d = W.Dialog({ name = "GoblinomicsGoalsDialog", title = L["Gold goals"], width = 460, height = 470,
        buttons = { { text = L["Close"], primary = true, onClick = function(b) b:GetParent():Hide() end } } })
    d.rows = {}
    for i = 1, ROWS do
        local row = CreateFrame("Frame", nil, d.body)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * (S.ROW + 2))
        row:SetPoint("RIGHT", d.body, "RIGHT", 0, 0)
        row:SetHeight(S.ROW)
        row.name = Theme.Text(row, "body", C.text)
        row.name:SetPoint("LEFT", 0, 0)
        row.name:SetWidth(150)
        row.name:SetWordWrap(false)
        row.delete = W.IconButton(row, "close", { onClick = function()
            if row.goal then Goals.Remove(row.goal); Goals.RefreshDialog() end
        end })
        row.delete:SetPoint("RIGHT", 0, 0)
        row.bar = W.ProgressBar(row, 200, 14)
        row.bar:SetPoint("LEFT", 158, 0)
        row.bar:SetPoint("RIGHT", row.delete, "LEFT", -S.SM, 0)
        d.rows[i] = row
    end
    d.empty = Theme.Text(d.body, "body", C.textDim)
    d.empty:SetPoint("TOPLEFT", 0, -4)
    d.empty:SetText(L["No goals yet"])
    local form = { kind = "wealth" }
    d.form = form
    local y = -ROWS * (S.ROW + 2) - S.GAP
    local line = d.body:CreateTexture(nil, "BORDER")
    line:SetColorTexture(unpack(C.border))
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 0, y)
    line:SetPoint("TOPRIGHT", 0, y)
    y = y - S.GAP
    local name = W.EditBox(d.body, { width = 200, get = function() return form.name or "" end,
        set = function(t) form.name = t; return true end })
    name:SetScript("OnTextChanged", function(self) form.name = self:GetText() end)
    d:Row(L["Name"], name, y)
    y = y - S.CONTROL_H - S.SM
    local kind = W.Segmented(d.body, { { value = "wealth", label = L["Wealth goal"] },
        { value = "purchase", label = L["Purchase goal"] } }, function() return form.kind end,
        function(v) form.kind = v end, { min = 90 })
    d:Row(L["Type"], kind, y)
    y = y - S.CONTROL_H - S.SM
    local amount = W.EditBox(d.body, { width = 120, get = function() return form.amount or "" end,
        set = function(t) form.amount = t; return true end })
    amount:SetNumeric(true)
    amount:SetScript("OnTextChanged", function(self) form.amount = self:GetText() end)
    d:Row(L["Amount (gold)"], amount, y)
    y = y - S.CONTROL_H - S.SM
    local add = W.Button(d.body, L["Add"], { auto = true, onClick = function()
        local gold = tonumber(form.amount)
        if gold and Goals.Add(form.kind, form.name, gold * 10000) then
            name:SetText("")
            amount:SetText("")
            form.name, form.amount = nil, nil
            Goals.RefreshDialog()
        end
    end })
    add:SetPoint("TOPLEFT", d.body, "TOPLEFT", 140, y)
    return d
end

function Goals.RefreshDialog()
    if not dialog then return end
    local list = List()
    for i, row in ipairs(dialog.rows) do
        local g = list[i]
        row.goal = g
        if g then
            local current, progress = Goals.Progress(g)
            row.name:SetText(g.name .. (g.reached and (" " .. API.Theme.Colorize("*", API.Theme.colors.accent)) or ""))
            row.bar:SetValue(progress)
            row.bar:SetLabels(API.Format:Percent(progress), API.Money.Format(current, { abbreviate = true })
                .. " / " .. API.Money.Format(g.amount, { abbreviate = true }))
            row:Show()
        else
            row:Hide()
        end
    end
    dialog.empty:SetShown(#list == 0)
end

function Goals.OpenDialog()
    dialog = dialog or BuildDialog()
    Goals.RefreshDialog()
    dialog:Show()
end

-- Dashboard card -------------------------------------------------------------------
local function RegisterCard()
    local W, Theme = API.Widgets, API.Theme
    local C = Theme.colors
    API.UI:RegisterWidget({
        id = "vault.goals", order = 43, size = "quarter", height = 120, events = { "NETWORTH_UPDATED", "VAULT_GOALS" },
        title = function() return L["Goals & Jealousmeter"] end,
        build = function(f)
            local S = Theme.space
            f.goals = {}
            for i = 1, 2 do
                local bar = W.ProgressBar(f, 100, 14)
                bar:SetPoint("TOPLEFT", S.PAD, S.CARD_BODY_Y - (i - 1) * 20)
                bar:SetPoint("RIGHT", f, "RIGHT", -S.PAD, 0)
                f.goals[i] = bar
            end
            f.none = Theme.Text(f, "small", C.textDim)
            f.none:SetPoint("TOPLEFT", S.PAD, S.CARD_BODY_Y)
            f.none:SetText(L["No goals yet"])
            -- the Jealousmeter line follows directly under the goals (no gap without goals)
            f.jealous = Theme.Text(f, "small", C.textDim)
            f.jealous:SetPoint("RIGHT", f, "RIGHT", -S.PAD, 0)
            f.manage = W.Button(f, L["Manage goals"], { auto = true, height = S.SMALL_H, onClick = Goals.OpenDialog })
            f.manage:SetPoint("BOTTOMLEFT", S.PAD, S.PAD)
        end,
        refresh = function(f)
            local list = List()
            for i, bar in ipairs(f.goals) do
                local g = list[i]
                bar:SetShown(g ~= nil)
                if g then
                    local _, progress = Goals.Progress(g)
                    bar:SetValue(progress)
                    bar:SetLabels(g.name, API.Format:Percent(progress))
                end
            end
            f.none:SetShown(#list == 0)
            local S = API.Theme.space
            local lines = math.max(1, math.min(#list, #f.goals))
            f.jealous:ClearAllPoints()
            f.jealous:SetPoint("TOPLEFT", S.PAD, S.CARD_BODY_Y - lines * 20 - S.XS)
            f.jealous:SetPoint("RIGHT", f, "RIGHT", -S.PAD, 0)
            local copper, level = 0, 0
            if ns.JealousmeterUI then copper, level = ns.JealousmeterUI.Current() end
            local info = ns.Jealousmeter.Info(copper, level)
            f.jealous:SetText(info.toNext and API.Lf("Jealousmeter: %s to the next face",
                API.Money.Format(math.floor(info.toNext * 10000 + 0.5), { abbreviate = true })) or L["Jealousmeter: maximum"])
        end,
    })
end

function Goals.Enable(module)
    vault = module
    if type(module.db.root.goals) ~= "table" then module.db.root.goals = {} end
    -- own owner: the Jealousmeter already listens to NETWORTH_UPDATED as the Vault
    -- module, and one owner keeps only one handler per event
    API.On("NETWORTH_UPDATED", Goals.Check, "Goblinomics_Vault.Goals")
    RegisterCard()
end

function Goals.Disable()
    API.Off("NETWORTH_UPDATED", "Goblinomics_Vault.Goals")
end
