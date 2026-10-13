local fake = require("spec.support.sources")

describe("Gatherer UI", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, pns

    local function buildTab()
        local page = CreateFrame("Frame")
        ns.UI.GetTab("gatherer").build(page)
        return page
    end

    before_each(function()
        ns, pns = load_gatherer()
        ns.Price.RegisterSource(fake("tsm", 10, { market = { ["i:210796"] = 100000 } }))
    end)

    it("registers the tab and the settings section", function()
        assert.is_table(ns.UI.GetTab("gatherer"))
        local sections = {}
        for _, s in ipairs(ns.UI.SortedSettings()) do sections[#sections + 1] = s.id end
        assert.same({ "core", "pricing", "gatherer" }, sections)
        local height = ns.UI.SortedSettings()[3].build(CreateFrame("Frame"), 0)
        assert.is_true(height > 100)
    end)

    it("lists farms with statistics and ad-hoc sessions last", function()
        local farm = pns.Farms.Create({ name = "Herbs" })
        pns.Farms.AddSummary({ farmId = farm.id, started = 1, duration = 3600, total = 50000, gph = 50000 })
        pns.Farms.AddSummary({ started = 2, duration = 60, total = 1, gph = 60 })
        local rows = pns.GathererUI.FarmRows()
        assert.equals("Herbs", rows[1].name)
        assert.equals(50000, rows[1].avgGPH)
        assert.equals(pns.Farms.AD_HOC, rows[2].id)
        assert.equals(1, #pns.GathererUI.HistoryRows(pns.Farms.AD_HOC))
    end)

    it("builds the tab, selects the first farm and shows its history", function()
        local farm = pns.Farms.Create({ name = "Herbs", expectedGPH = 1000000 })
        pns.Farms.AddSummary({ farmId = farm.id, started = WoWMock.now, duration = 600, total = 9000, gph = 54000,
            char = "xLN-Blackrock", items = {} })
        buildTab()
        assert.equals(farm.id, pns.GathererUI.Selected())
        pns.Session.Start(farm.id)
        pns.GathererUI.Refresh()
        pns.GathererUI.Select(farm.id)
    end)

    it("puts the actions at their part: start and pause in the session panel, farm actions by the farm", function()
        local farm = pns.Farms.Create({ name = "Herbs" })
        buildTab()
        local tab = pns.GathererUI.tab
        local p = tab.session
        assert.equals("Start session", p.main.label:GetText())
        assert.equals("Herbs", p.target:GetText())
        assert.is_false(p.pause:IsShown())
        p.main:GetScript("OnClick")(p.main, "LeftButton")
        assert.equals(farm.id, pns.Session.Active().farmId)
        assert.equals("Stop session", p.main.label:GetText())
        assert.is_true(p.pause:IsShown())
        p.pause:GetScript("OnClick")(p.pause, "LeftButton")
        assert.is_false(pns.Session.IsRunning())
        assert.equals("Resume", p.pause.label:GetText())
        p.main:GetScript("OnClick")(p.main, "LeftButton")                -- stop
        assert.is_nil(pns.Session.Active())
        -- without a farm: edit, export and delete are off; the main button starts ad hoc
        pns.Farms.Delete(farm.id)
        pns.GathererUI.Select(nil)
        assert.is_true(tab.edit.disabled and tab.export.disabled and tab.delete.disabled)
        assert.equals("Ad-hoc session", p.target:GetText())
        assert.is_table(tab.new)   -- above the list, always there
        assert.is_table(tab.import)
    end)

    it("saves a new farm from the editor", function()
        pns.FarmEditor.Open(nil)
        local form = pns.FarmEditor.Form()
        form.name = "Ore run"
        form.category = "gathering"
        form.highlightThreshold = ""
        table.insert(form.expectedHighlights,
            pns.FarmEditor.ItemKeyFromText("|cffffffff|Hitem:210930::::::::80:::::|h[B]|h|r"))
        assert.is_true(pns.FarmEditor.Save())
        local farm = pns.Farms.FindByName("Ore run")
        assert.is_nil(farm.highlightThreshold)
        assert.same({ "i:210930" }, farm.expectedHighlights)
    end)

    it("explains the notification threshold with the value from the settings", function()
        pns.FarmEditor.Open(nil)
        local hint = _G.GoblinomicsGathererFarmEditor.thresholdHint:GetText()
        assert.truthy(hint:find("2,500", 1, true))
        GoblinomicsGathererDB.settings.highlightThreshold = 0
        pns.FarmEditor.Open(nil)
        assert.equals("empty: off (settings)", _G.GoblinomicsGathererFarmEditor.thresholdHint:GetText())
    end)

    it("keeps the editor open without a name", function()
        pns.FarmEditor.Open(nil)
        assert.is_false(pns.FarmEditor.Save())
        assert.is_true(_G.GoblinomicsGathererFarmEditor:IsShown())
    end)

    it("parses item IDs and links for the item box", function()
        assert.equals("i:123", pns.FarmEditor.ItemKeyFromText(" 123 "))
        assert.is_nil(pns.FarmEditor.ItemKeyFromText("abc"))
    end)

    it("shows the instance menu only for raid and dungeon farms and saves the choice", function()
        pns.FarmEditor.Open(nil)
        local dialog = _G.GoblinomicsGathererFarmEditor
        assert.is_false(dialog.instance:IsShown())
        local form = pns.FarmEditor.Form()
        form.name = "Raid"
        form.category = "raid"
        pns.FarmEditor.RefreshInstance()
        assert.is_true(dialog.instance:IsShown())
        assert.equals("Choose instance", dialog.instance.label:GetText())
        form.instance = { journalID = 1296, mapID = 2769, name = "Liberation of Undermine", isRaid = true }
        pns.FarmEditor.RefreshInstance()
        assert.equals("Liberation of Undermine", dialog.instance.label:GetText())
        assert.is_true(pns.FarmEditor.Save())
        assert.equals(2769, pns.Farms.FindByName("Raid").instance.mapID)
        pns.FarmEditor.Open(pns.Farms.FindByName("Raid"))
        form = pns.FarmEditor.Form()
        form.category = "dungeon"
        pns.FarmEditor.RefreshInstance()
        assert.is_nil(form.instance)
    end)

    it("shows the lockout grid for an instance farm in the tab", function()
        WoWMock.fire("UPDATE_INSTANCE_INFO")
        GoblinomicsGathererDB.chars["xLN-Blackrock"].lockouts = { { name = "Liberation of Undermine", mapID = 2769,
            difficultyID = 15, resetAt = WoWMock.now + 600, encounters = 8, progress = 5 } }
        local farm = pns.Farms.Create({ name = "Raid", category = "raid",
            instance = { journalID = 1296, mapID = 2769, name = "Liberation of Undermine", isRaid = true } })
        local page = buildTab()
        pns.GathererUI.Select(farm.id)
        local grid = pns.Lockouts.Grid(farm)
        assert.equals("Can still run: Normal 1/1  \194\183  Heroic 1/1  \194\183  Mythic 1/1",
            pns.GathererUI.LockoutSummary(grid))
        assert.truthy(page)
    end)

    it("summarises farming sessions for the dashboard", function()
        local farm = pns.Farms.Create({ name = "Herbs" })
        pns.Farms.AddSummary({ farmId = farm.id, farmName = "Herbs", started = WoWMock.now - 3600, duration = 1800,
            total = 50000, gph = 100000 })
        pns.Farms.AddSummary({ started = WoWMock.now - 10 * 86400, duration = 1800, total = 9, gph = 18 })
        local s = pns.GathererUI.FarmingSummary(WoWMock.now - 7 * 86400)
        assert.equals(1, s.sessions)
        assert.equals(50000, s.total)
        assert.equals("Herbs", s.best.farmName)
        local ids = {}
        for _, w in ipairs(ns.UI.SortedWidgets()) do ids[w.id] = true end
        assert.is_true(ids["gatherer.farming"])
    end)
end)
