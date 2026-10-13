if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Modules/Workshop/WorkshopProfessions.lua
-- "Concentration & cooldowns" view of the Workshop and its dashboard card. A switch
-- shows either concentration or cooldowns, a dropdown the expansion (the current one
-- by default, the same for both and for the notices). Every character with an entry,
-- the one due first on top; under it the professions (icon, computed concentration
-- as a bar, "full in") or the recipe cooldowns ("ready in", charges). A click on a
-- character folds it. The profession and character filters apply, the period does
-- not. While shown it refreshes once a minute; nothing is asked from the game.
local _, ns = ...

local View = {}
ns.WorkshopProfessions = View

local collapsed = {}   -- charKey -> true
View.collapsed = collapsed

local function Settings() return ns.Workshop.db.settings end

local function ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    return c and c.colorStr or "ffffffff"
end
View.ClassColor = ClassColor

--- "full" / "full in 3h 12m" style text for a due time.
function View.DueText(at, now, readyText, inText)
    local API = ns.API
    if not at then return "" end
    if at <= now then return API.Theme.CODE.good .. readyText .. "|r" end
    return API.Lf(inText, API.Format:Remaining(at - now))
end

--- "  - Midnight" style tag (a middle dot, or "Engineering, Wrath of the Lich King") in grey after a row's name.
function View.ExpansionTag(expansion, profession)
    local Theme = ns.API.Theme
    local parts = {}
    if profession then parts[#parts + 1] = profession end
    if expansion then parts[#parts + 1] = expansion end
    if #parts == 0 then return "" end
    return "  " .. Theme.Colorize("\194\183 " .. table.concat(parts, ", "), Theme.colors.textDim)
end

--- Tooltip lines of a profession or cooldown row (title, lines).
function View.TooltipLines(data, now, valuePerPoint)
    local API, L = ns.API, ns.L
    local Date = function(t) return API.Format:Date(t, "stamp") end
    local lines = {}
    if data.kind == "profession" then
        local p = data.profession
        lines[#lines + 1] = L["Concentration"] .. ": " .. (p.current or 0) .. " / " .. (p.max or 1000)
        if p.fullAt then
            lines[#lines + 1] = p.fullAt <= now and L["Full"] or API.Lf("Full at %s", Date(p.fullAt))
        end
        if p.cycleSec and p.cycleSec > 0 then
            lines[#lines + 1] = API.Lf("%s points per hour", API.Format:Number(3600 / p.cycleSec * (p.perCycle or 1), 1))
        end
        if valuePerPoint and valuePerPoint > 0 then
            lines[#lines + 1] = API.Lf("Worth now: %s (%s per point)",
                API.Money.Format(math.floor((p.current or 0) * valuePerPoint), { abbreviate = true }),
                API.Money.Format(math.floor(valuePerPoint), { abbreviate = true }))
        end
        if p.readAt then lines[#lines + 1] = API.Lf("Read %s ago", API.Format:Remaining(now - p.readAt)) end
        lines[#lines + 1] = L["Log in with the character to read it again."]
        return (p.name or "?") .. (p.expansion and (" - " .. p.expansion) or ""), lines
    end
    local cd = data.cooldown
    if cd.readyAt then
        lines[#lines + 1] = cd.readyAt <= now and L["ready"] or API.Lf("Ready at %s", Date(cd.readyAt))
    end
    if cd.maxCharges then
        lines[#lines + 1] = API.Lf("%d/%d charges", cd.charges or 0, cd.maxCharges)
        if cd.fullAt and cd.fullAt > now then lines[#lines + 1] = API.Lf("All charges at %s", Date(cd.fullAt)) end
    end
    if cd.count and cd.count > 1 then
        lines[#lines + 1] = API.Lf("Shares its cooldown with %d other recipes", cd.count - 1)
    end
    if cd.profession or cd.expansion then
        lines[#lines + 1] = table.concat({ cd.profession, cd.expansion }, ", ")
    end
    return cd.name or "?", lines
end

function View.Tooltip(owner, data)
    if data.kind ~= "profession" and data.kind ~= "cooldown" then return end
    local value
    if data.kind == "profession" then
        local byProfession = ns.Concentration.ByProfession()
        local entry = byProfession[data.profession.name]
        value = entry and entry.value
    end
    local title, lines = View.TooltipLines(data, time(), value)
    ns.API.Widgets.ShowTooltip(owner, title, lines)
end

--- Flat rows for the list from Professions.Overview: mode "concentration" or
-- "cooldowns", with the Workshop's profession and character filters.
function View.Rows(overview, filter, mode)
    filter = filter or {}
    local rows = {}
    for _, e in ipairs(overview) do
        if not filter.char or filter.char == e.key then
            local entries, dueAt = {}, nil
            local source = mode == "cooldowns" and e.cooldowns or e.professions
            for _, x in ipairs(source) do
                local profession = mode == "cooldowns" and x.profession or x.name
                if not filter.profession or not profession or filter.profession == profession then
                    entries[#entries + 1] = x
                    local at = mode == "cooldowns" and x.readyAt or x.fullAt
                    if at and (not dueAt or at < dueAt) then dueAt = at end
                end
            end
            if #entries > 0 then
                rows[#rows + 1] = { kind = "char", entry = e, dueAt = dueAt }
                if not collapsed[e.key] then
                    local kind = mode == "cooldowns" and "cooldown" or "profession"
                    for _, x in ipairs(entries) do
                        rows[#rows + 1] = { kind = kind, entry = e, profession = kind == "profession" and x or nil,
                            cooldown = kind == "cooldown" and x or nil }
                    end
                end
            end
        end
    end
    -- the character due first on top, for the entries shown
    local groups = {}
    for _, r in ipairs(rows) do
        if r.kind == "char" then groups[#groups + 1] = {} end
        local group = groups[#groups]
        group[#group + 1] = r
    end
    table.sort(groups, function(a, b)
        local x, y = a[1].dueAt or math.huge, b[1].dueAt or math.huge
        if x ~= y then return x < y end
        return a[1].entry.name < b[1].entry.name
    end)
    local out = {}
    for _, g in ipairs(groups) do for _, r in ipairs(g) do out[#out + 1] = r end end
    return out
end

--- Current mode of the view ("concentration" or "cooldowns").
function View.Mode()
    return Settings().professionsMode == "cooldowns" and "cooldowns" or "concentration"
end

function View.Build(parent)
    local API, L = ns.API, ns.L
    local Theme, W = API.Theme, API.Widgets
    local C, S = Theme.colors, Theme.space
    local page = { frame = CreateFrame("Frame", nil, parent) }
    local f = page.frame
    f:SetAllPoints(parent)

    local function changed()
        ns.WorkshopUI.Refresh()
        API.Emit("WORKSHOP_PROFESSIONS", {})
    end
    page.mode = W.Segmented(f, { { value = "concentration", label = L["Concentration"] },
        { value = "cooldowns", label = L["Cooldowns"] } }, View.Mode, function(value)
            Settings().professionsMode = value
            ns.WorkshopUI.Refresh()
        end, { min = 90 })
    page.mode:SetPoint("TOPLEFT", 0, 0)
    page.expansion = W.Dropdown(f, function()
        local current = ns.Professions.CurrentExpansion(ns.Workshop.db.root)
        local list = { { value = "current", label = L["Current expansion"] .. (current and (" (" .. current .. ")") or "") } }
        for _, name in ipairs(ns.Professions.Expansions(ns.Workshop.db.root)) do
            list[#list + 1] = { value = name, label = name }
        end
        list[#list + 1] = { value = "all", label = L["All expansions"] }
        return list
    end, function() return Settings().professionsExpansion or "current" end, function(value)
        Settings().professionsExpansion = value ~= "current" and value or nil
        changed()
    end, { size = "L" })
    page.expansion:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    local hint = Theme.Text(f, "small", C.textDim)
    hint:SetPoint("TOPLEFT", 0, -(S.CONTROL_H + S.SM))
    hint:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")
    page.hint = hint

    local function InitRow(row, data)
        if not row.label then
            W.RowBackground(row)
            row.toggle = Theme.Text(row, "body", C.textDim)
            row.toggle:SetPoint("LEFT", 2, 0)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(16, 16)
            row.icon:SetPoint("LEFT", 24, 0)
            row.label = Theme.Text(row, "body", C.text)
            row.label:SetWordWrap(false)
            row.status = Theme.Text(row, "body", C.text)
            row.status:SetPoint("RIGHT", -S.SM, 0)
            row.status:SetJustifyH("RIGHT")
            row.status:SetWidth(150)
            row.bar = W.ProgressBar(row, 180, 14)
            row.bar:SetPoint("RIGHT", row.status, "LEFT", -S.GAP, 0)
            row:SetScript("OnClick", function(self)
                local d = self.data
                if d.kind ~= "char" then return end
                collapsed[d.entry.key] = not collapsed[d.entry.key] or nil
                ns.WorkshopUI.Refresh()
            end)
            row:SetScript("OnEnter", function(self) View.Tooltip(self, self.data) end)
            row:SetScript("OnLeave", W.HideTooltip)
        end
        row.data = data
        local now = time()
        local e = data.entry
        row.label:ClearAllPoints()
        row.label:SetPoint("RIGHT", row.bar, "LEFT", -S.GAP, 0)
        if data.kind == "char" then
            row.zebra:Show()
            row.toggle:SetText(collapsed[e.key] and "+" or "-")
            row.icon:Hide()
            row.bar:Hide()
            row.label:SetPoint("LEFT", 16, 0)
            row.label:SetText("|c" .. ClassColor(e.class) .. e.name .. "|r")
            local due = data.dueAt
            row.status:SetText(due and (due <= now and (Theme.CODE.good .. L["something is ready"] .. "|r")
                or API.Lf("next in %s", API.Format:Remaining(due - now))) or "")
            return
        end
        row.zebra:Hide()
        row.toggle:SetText("")
        row.label:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        if data.kind == "profession" then
            local p = data.profession
            row.icon:SetTexture(p.icon or 134400)
            row.icon:Show()
            row.label:SetText((p.name or "?") .. View.ExpansionTag(p.expansion))
            row.bar:Show()
            row.bar:SetMinMaxValues(0, p.max or 1000)
            row.bar:SetValue(p.current or 0)
            row.bar:SetLabels(tostring(p.current or 0), tostring(p.max or 1000))
            row.status:SetText(View.DueText(p.fullAt, now, L["full"], "full in %s"))
        else
            local cd = data.cooldown
            row.icon:SetTexture(cd.icon or 134400)
            row.icon:Show()
            row.label:SetText((cd.name or "?") .. (cd.count > 1 and (" " .. Theme.Colorize("(+" .. (cd.count - 1) .. ")",
                C.textDim)) or "") .. View.ExpansionTag(cd.expansion, cd.profession))
            if cd.maxCharges then
                row.bar:Show()
                row.bar:SetMinMaxValues(0, cd.maxCharges)
                row.bar:SetValue(cd.charges or 0)
                row.bar:SetLabels(API.Lf("%d/%d charges", cd.charges or 0, cd.maxCharges), "")
            else
                row.bar:Hide()
            end
            row.status:SetText(View.DueText(cd.readyAt, now, L["ready"], "ready in %s"))
        end
    end

    page.list = W.ScrollList(f, { rowHeight = S.ROW, init = InitRow })
    page.list.box:SetPoint("TOPLEFT", 0, -(S.CONTROL_H + S.SM + S.ROW))
    page.list.box:SetPoint("BOTTOMRIGHT", 0, 0)
    page.empty = W.EmptyState(page.list.box, L["No profession data yet: open a profession window once on each character."])

    -- once a minute while visible
    local ticking = false
    local function Tick()
        if not f:IsVisible() then ticking = false return end
        page.Refresh(ns.WorkshopUI.Filter())
        ns.Workshop:After(60, Tick)
    end

    function page.Refresh(filter)
        local root = ns.Workshop.db.root
        local mode = View.Mode()
        page.mode:Refresh()
        page.hint:SetText(mode == "cooldowns" and L["Recipes with a daily cooldown or charges, found when a profession window opens."]
            or L["Concentration is read when you log in or open a profession window, and computed from then on."])
        local rows = View.Rows(ns.Professions.Overview(root, Settings(), time()), filter, mode)
        page.rows = rows
        page.list:SetData(rows)
        page.empty:SetShown(#rows == 0)
        if not ticking then
            ticking = true
            ns.Workshop:After(60, Tick)
        end
    end
    return page
end

-- Dashboard card: the next due entries over all characters ---------------------------------
local function RegisterCard()
    local API, L = ns.API, ns.L
    local Theme = API.Theme
    local C = Theme.colors
    local ROWS = 5
    API.UI:RegisterWidget({
        id = "workshop.concentration", order = 42, size = "quarter", height = 120,
        events = { "WORKSHOP_PROFESSIONS" },
        title = function() return L["Concentration & cooldowns"] end,
        build = function(f)
            f.lines = {}
            for i = 1, ROWS do
                local left = Theme.Text(f, "small", C.text)
                left:SetPoint("TOPLEFT", 12, -26 - (i - 1) * 16)
                left:SetPoint("RIGHT", f, "RIGHT", -84, 0)
                left:SetWordWrap(false)
                local right = Theme.Text(f, "small", C.textDim)
                right:SetPoint("TOPRIGHT", -12, -26 - (i - 1) * 16)
                right:SetJustifyH("RIGHT")
                f.lines[i] = { left = left, right = right }
            end
            f.empty = Theme.Text(f, "small", C.textDim)
            f.empty:SetPoint("TOPLEFT", 12, -26)
            f.empty:SetPoint("RIGHT", f, "RIGHT", -12, 0)
            f.empty:SetJustifyH("LEFT")
            f.empty:SetText(L["Open a profession window once on each character."])
            f:EnableMouse(true)
            f:SetScript("OnMouseUp", function()
                API.UI:Show("workshop")
                ns.WorkshopUI.Show("professions")
            end)
        end,
        refresh = function(f)
            local now = time()
            local due = ns.Professions.Due(ns.Workshop.db.root, Settings(), now)
            for i, line in ipairs(f.lines) do
                local d = due[i]
                line.left:SetText(d and ("|c" .. ClassColor(d.class) .. d.name .. "|r  " .. (d.label or "")) or "")
                line.right:SetText(d and View.DueText(d.at, now, d.kind == "cooldown" and L["ready"] or L["full"], "in %s")
                    or "")
            end
            f.empty:SetShown(#due == 0)
        end,
    })
end

function View.Enable()
    ns.WorkshopUI.AddView({ id = "professions", noPeriod = true,
        label = function() return ns.L["Concentration & cooldowns"] end,
        build = function(parent) return View.Build(parent) end })
    RegisterCard()
end
