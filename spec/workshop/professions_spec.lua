-- Concentration and recipe cooldowns across characters: read once, then computed.
describe("Workshop: concentration and cooldowns", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    local ns, wns, P

    local function install()
        WoWMock.childProfessions = {
            { professionID = 2900, professionName = "Midnight Alchemy", parentProfessionID = 171,
                parentProfessionName = "Alchemy", expansionName = "Midnight" },
            { professionID = 2823, professionName = "Khaz Algar Alchemy", parentProfessionID = 171,
                parentProfessionName = "Alchemy", expansionName = "Khaz Algar" },
        }
        WoWMock.concentrationIDs = { [2900] = 3100, [2823] = 3050 }
        WoWMock.childSkillLine = 2900
        WoWMock.recipeIDs = { 700, 701, 702, 703, 704 }
        WoWMock.currencies = { [3100] = { quantity = 400, maxQuantity = 1000, rechargingCycleDurationMS = 360000,
            rechargingAmountPerCycle = 1 } }
        WoWMock.recipes[700] = { name = "Transmute: Ore", expansion = "Midnight" }
        WoWMock.recipes[701] = { name = "Transmute: Herbs", expansion = "Midnight" }
        WoWMock.recipes[702] = { name = "Potion", expansion = "Midnight" }
        WoWMock.recipes[703] = { name = "Experimental Flask", expansion = "Midnight" }
        WoWMock.recipes[704] = { name = "Jard's Peculiar Energy Source", profession = "Engineering",
            expansion = "Wrath of the Lich King" }
    end

    before_each(function()

        ns, wns = load_workshop({ before = install })
        P = wns.Professions
    end)

    local function char() return GoblinomicsWorkshopDB.chars["xLN-Blackrock"] end

    it("computes the current concentration and when it is full from one reading", function()
        local p = { amount = 400, max = 1000, cycleSec = 360, perCycle = 1, readAt = 1000 }
        assert.equals(400, P.Current(p, 1000))
        assert.equals(400, P.Current(p, 1359))
        assert.equals(401, P.Current(p, 1360))
        assert.equals(1000, P.Current(p, 1000 + 1000 * 360))
        assert.equals(1000 + 600 * 360, P.FullAt(p))
        assert.equals(1000 + 500 * 360, P.FullAt(p, 900))
        assert.equals(1000, P.FullAt({ amount = 1000, max = 1000, cycleSec = 360, readAt = 1000 }))
        assert.equals(1000 + 300 * 360, P.FullAt({ amount = 400, max = 1000, cycleSec = 360, perCycle = 2, readAt = 1000 }))
        assert.is_nil(P.Current(nil, 0))
    end)

    it("keeps every expansion's line from the profession window and shows the chosen one", function()
        WoWMock.currencies[3050] = { quantity = 1000, maxQuantity = 1000, rechargingCycleDurationMS = 360000 }
        WoWMock.fire("TRADE_SKILL_SHOW")
        WoWMock.advance(1)
        WoWMock.flush()
        local lines = char().professions
        assert.is_table(lines[2900])
        assert.equals("Khaz Algar", lines[2823].expansion)
        local root = GoblinomicsWorkshopDB
        assert.equals(1, #P.Overview(root, {}, WoWMock.now)[1].professions)                -- Midnight by default
        assert.equals(2, #P.Overview(root, { professionsExpansion = "all" }, WoWMock.now)[1].professions)
        local tww = P.Overview(root, { professionsExpansion = "Khaz Algar" }, WoWMock.now)[1].professions
        assert.equals(1000, tww[1].current)
        assert.same({ "Khaz Algar", "Midnight" }, root.expansionOrder)       -- learned from the window, oldest first
        assert.same({ "Midnight", "Khaz Algar" }, P.Expansions(root))       -- the names professions use, newest first
        assert.equals("Midnight", P.CurrentExpansion(root))
        assert.is_truthy(wns.WorkshopProfessions.ExpansionTag("Midnight"):find("Midnight"))
        assert.is_truthy(wns.WorkshopProfessions.ExpansionTag("Classic", "Engineering"):find("Engineering, Classic"))
        assert.equals("", wns.WorkshopProfessions.ExpansionTag(nil))
        assert.equals("Alchemy", lines[2900].name)
        assert.equals(400, lines[2900].amount)
        assert.equals(360, lines[2900].cycleSec)
        assert.equals(WoWMock.now, lines[2900].readAt)
    end)

    it("reads the stored currencies again at login without a window", function()
        char().professions = { [2900] = { name = "Alchemy", currencyID = 3100, amount = 10, readAt = 1 } }
        WoWMock.currencies[3100].quantity = 777
        P.ReadStored()
        assert.equals(777, char().professions[2900].amount)
        WoWMock.currencies[3100].quantity = 780
        WoWMock.fire("CURRENCY_DISPLAY_UPDATE", 3100)
        assert.equals(780, char().professions[2900].amount)
    end)

    it("finds cooldown recipes, groups shared cooldowns and counts charges", function()
        WoWMock.recipeCooldowns[700] = { 3600, true, 0, 0 }
        WoWMock.recipeCooldowns[701] = { 3600, true, 0, 0 }
        WoWMock.recipeCooldowns[703] = { 1800, false, 1, 3 }
        WoWMock.recipeCooldowns[704] = { 7200, true, 0, 0 }
        WoWMock.spellCharges[703] = { cooldownDuration = 7200 }
        WoWMock.fire("TRADE_SKILL_SHOW")
        WoWMock.advance(1)
        WoWMock.flush()
        local list = char().cooldowns
        assert.is_table(list[700])
        assert.is_nil(list[702])
        assert.equals(3, list[703].maxCharges)
        assert.equals("Wrath of the Lich King", list[704].expansion)
        assert.equals(3, #P.Overview(GoblinomicsWorkshopDB, { professionsExpansion = "all" }, WoWMock.now)[1].cooldowns)
        local e = P.Overview(GoblinomicsWorkshopDB, {}, WoWMock.now)[1]
        assert.equals(2, #e.cooldowns)                              -- the two transmutes are one entry, Jard's is older
        local transmute, flask
        for _, c in ipairs(e.cooldowns) do if c.maxCharges then flask = c else transmute = c end end
        assert.equals(2, transmute.count)
        assert.equals(WoWMock.now + 3600, transmute.readyAt)
        assert.equals(1, flask.charges)
        assert.equals(WoWMock.now + 1800 + 7200, flask.fullAt)
        local charges = P.CooldownState(list[703], WoWMock.now + 1800 + 10)
        assert.equals(2, charges)
    end)

    it("leaves cooldowns alone while they are secret", function()
        WoWMock.recipeCooldowns[700] = { 3600, true, 0, 0 }
        WoWMock.cooldownsSecret = true
        assert.is_false(P.ReadCooldown(700))
        WoWMock.cooldownsSecret = false
        assert.is_true(P.ReadCooldown(700))
    end)

    it("lists characters by the first due entry and leaves hidden ones out", function()
        local now = 100000
        local root = { chars = {
            ["Main-Realm"] = { name = "Main", professions = { [1] = { name = "Alchemy", amount = 900, max = 1000,
                cycleSec = 360, readAt = now } } },
            ["Alt-Realm"] = { name = "Alt", professions = { [2] = { name = "Smithing", amount = 999, max = 1000,
                cycleSec = 360, readAt = now } } },
            ["Bank-Realm"] = { name = "Bank" },
        } }
        local list = P.Overview(root, {}, now)
        assert.same({ "Alt-Realm", "Main-Realm" }, { list[1].key, list[2].key })
        assert.equals(now + 360, list[1].dueAt)
        list = P.Overview(root, { professionsHidden = { ["Alt-Realm"] = true } }, now)
        assert.equals(1, #list)
        local due = P.Due(root, { concentrationThreshold = 950 }, now)
        assert.equals("Alt-Realm", due[1].char)                      -- already above the threshold
        assert.equals(now, due[1].at)
        assert.equals(now + 50 * 360, due[2].at)
    end)

    it("shows the view in the Workshop and the dashboard card, filtered and foldable", function()
        local root = GoblinomicsWorkshopDB
        root.chars["Alt-Realm"] = { name = "Alt", class = "MAGE", professions = { [2901] = { name = "Blacksmithing",
            amount = 990, max = 1000, cycleSec = 360, readAt = WoWMock.now } },
            cooldowns = { [700] = { name = "Transmute: Ore", readyAt = WoWMock.now - 5 } } }
        char().professions = { [2900] = { name = "Alchemy", amount = 100, max = 1000, cycleSec = 360, readAt = WoWMock.now } }
        local V = wns.WorkshopProfessions
        root.chars["Alt-Realm"].cooldowns[700].expansion = "Midnight"
        local overview = P.Overview(root, {}, WoWMock.now)
        local rows = V.Rows(overview, {}, "concentration")
        assert.same({ "char", "profession", "char", "profession" }, { rows[1].kind, rows[2].kind, rows[3].kind, rows[4].kind })
        assert.equals("Alt-Realm", rows[1].entry.key)                 -- full first
        rows = V.Rows(overview, {}, "cooldowns")
        assert.same({ "char", "cooldown" }, { rows[1].kind, rows[2].kind })
        assert.equals(2, #V.Rows(overview, { char = "Alt-Realm" }, "concentration"))
        assert.equals(2, #V.Rows(overview, { profession = "Alchemy" }, "concentration"))
        V.collapsed["Alt-Realm"] = true
        assert.equals(3, #V.Rows(overview, {}, "concentration"))
        V.collapsed["Alt-Realm"] = nil

        local tab = ns.UI.GetTab("workshop")
        tab.build(CreateFrame("Frame"))
        tab.onShow()
        wns.WorkshopUI.Show("professions")
        assert.equals(4, #wns.WorkshopUI.CurrentPage().rows)
        root.settings.professionsMode = "cooldowns"
        wns.WorkshopUI.Refresh()
        assert.equals(2, #wns.WorkshopUI.CurrentPage().rows)
        WoWMock.advance(61)
        WoWMock.flush()
        tab.onHide()

        local card
        for _, w in ipairs(ns.UI.SortedWidgets()) do if w.id == "workshop.concentration" then card = w end end
        assert.is_table(card)
        local f = CreateFrame("Frame")
        card.build(f)
        card.refresh(f, {})
        assert.is_truthy(f.lines[1].left:GetText():find("Alt"))
    end)

    it("toasts once when an entry becomes due, opens the overview at login and fills the tooltip", function()
        local toasts = {}
        ns.Toast.Show = function(spec) toasts[#toasts + 1] = spec end
        local root = GoblinomicsWorkshopDB
        local N = wns.ProfessionNotices
        root.chars["Alt-Realm"] = { name = "Alt", professions = { [2901] = { name = "Blacksmithing", amount = 1000,
            max = 1000, cycleSec = 360, readAt = WoWMock.now } } }
        char().professions = { [2900] = { name = "Alchemy", amount = 998, max = 1000, cycleSec = 360, readAt = WoWMock.now } }
        assert.is_true(N.HasReady(root, root.settings, WoWMock.now))
        local left, right = N.TooltipText(root, root.settings, WoWMock.now)
        assert.equals("Concentration & cooldowns", left)
        assert.is_truthy(right:find("1 ready"))
        assert.is_truthy(right:find("next in 12m"))
        -- the login marks what is due already; only the Alchemy becomes due later
        for k in pairs(WoWMock.chat) do WoWMock.chat[k] = nil end
        WoWMock.advance(7)
        WoWMock.flush()
        assert.equals(0, #WoWMock.chat)
        assert.is_true(wns.ProfessionPopup.IsOpen())
        assert.equals(0, #toasts)
        WoWMock.advance(2 * 360)
        WoWMock.flush()
        assert.equals(1, #toasts)
        assert.is_truthy(toasts[1].text:find("Alchemy"))
        N.Check()
        assert.equals(1, #toasts)                                     -- once per due time
        root.settings.notifyTooltip = false
        GameTooltip:SetOwner(UIParent)
        ns.UI.FillTooltipProviders(GameTooltip)
        for _, l in ipairs(GameTooltip.lines) do assert.is_falsy(tostring(l.left or l[1] or ""):find("Concentration")) end
        assert.is_false(N.HasReady({ chars = {} }, {}, WoWMock.now))
    end)

    it("builds the settings with the threshold, the notice switches and the characters", function()
        char().professions = { [2900] = { name = "Alchemy", amount = 1, readAt = 1 } }
        local section
        for _, s in ipairs(ns.UI.SortedSettings()) do if s.id == "workshop" then section = s end end
        assert.is_true(section.build(CreateFrame("Frame"), 0) > 200)
    end)

    it("explains a profession and a cooldown row in its tooltip", function()
        local V = wns.WorkshopProfessions
        local now = 100000
        local title, lines = V.TooltipLines({ kind = "profession", profession = { name = "Alchemy", expansion = "Midnight",
            current = 500, max = 1000, fullAt = now + 3600, readAt = now - 600, cycleSec = 360, perCycle = 1 } }, now, 250)
        assert.equals("Alchemy - Midnight", title)
        local text = table.concat(lines, "|")
        assert.is_truthy(text:find("500 / 1000", 1, true))
        assert.is_truthy(text:find("Full at", 1, true))
        assert.is_truthy(text:find("points per hour", 1, true))
        assert.is_truthy(text:find("Worth now", 1, true))
        title, lines = V.TooltipLines({ kind = "cooldown", cooldown = { name = "Transmute: Ore", readyAt = now + 60,
            count = 2, profession = "Alchemy", expansion = "Midnight", maxCharges = 3, charges = 1, fullAt = now + 900 } }, now)
        assert.equals("Transmute: Ore", title)
        text = table.concat(lines, "|")
        assert.is_truthy(text:find("Ready at", 1, true))
        assert.is_truthy(text:find("1/3 charges", 1, true))
        assert.is_truthy(text:find("1 other recipes", 1, true))
    end)

    it("leaves runeforging out and lists expansions only up to the current one", function()
        WoWMock.recipes[800] = { name = "Rune of the Fallen Crusader", profession = "Runeforging", professionID = 960 }
        assert.is_true(wns.Recipes.IsIgnored(800))
        assert.is_false(wns.Recipes.IsIgnored(700))
        WoWMock.recipeCooldowns[800] = { 60, true, 0, 0 }
        assert.is_false(P.ReadCooldown(800))
        local root = GoblinomicsWorkshopDB
        root.crafts[#root.crafts + 1] = { id = 9001, recipe = 800, time = WoWMock.now, reagents = {}, outputs = {} }
        char().cooldowns = { [800] = { name = "Rune", readyAt = WoWMock.now } }
        assert.equals(1, wns.Recipes.PurgeIgnored(root))
        assert.is_nil(char().cooldowns[800])
        for _, name in ipairs(P.Expansions(root)) do assert.are_not.equal("Expansion 12", name) end
    end)

    it("learns the expansion order from a profession window in either direction", function()
        local root = { chars = {} }
        local list = { { professionID = 1, expansionName = "Classic" }, { professionID = 2, expansionName = "Pandaria" },
            { professionID = 3, expansionName = "Dragon Isles" }, { professionID = 4, expansionName = "Khaz Algar" } }
        P.LearnOrder(root, list, 4)                                   -- opened on the newest, listed oldest first
        assert.same({ "Classic", "Pandaria", "Dragon Isles", "Khaz Algar" }, root.expansionOrder)
        local reversed = {}
        for i = #list, 1, -1 do reversed[#reversed + 1] = list[i] end
        local other = { chars = {} }
        P.LearnOrder(other, reversed, 4)                              -- listed newest first
        assert.same(root.expansionOrder, other.expansionOrder)
        other.chars.x = { cooldowns = { [1] = { expansion = "Northrend" } } }
        assert.same({ "Khaz Algar", "Dragon Isles", "Pandaria", "Classic", "Northrend" }, P.Expansions(other))
        assert.equals("Khaz Algar", P.CurrentExpansion(root))
        local fresh = P.Expansions({ chars = {} })                    -- before any window: the client's names
        assert.equals("Midnight", fresh[1])
        for _, name in ipairs(fresh) do assert.are_not.equal("Expansion 12", name) end
    end)
    it("lists every character in the overview window with bars and cooldown chips", function()
        local Popup = wns.ProfessionPopup
        local now = WoWMock.now
        local overview = {
            { key = "Alt-Realm", name = "Alt", professions = { { id = 1, name = "Alchemy", current = 1000, max = 1000,
                fullAt = now - 10 } }, cooldowns = { { recipeID = 700, name = "Transmute", readyAt = now - 5, count = 1 },
                { recipeID = 701, name = "Flask", readyAt = now + 600, count = 1 },
                { recipeID = 702, name = "Potion", readyAt = now + 900, count = 1 } } },
            { key = "Main-Realm", name = "Main", professions = { { id = 2, name = "Tailoring", current = 300, max = 1000,
                fullAt = now + 3600 } }, cooldowns = {} },
            { key = "Empty-Realm", name = "Empty", professions = {}, cooldowns = {} },
        }
        local rows = Popup.Rows(overview, now)
        local kinds = {}
        for _, r in ipairs(rows) do kinds[#kinds + 1] = r.kind end
        assert.same({ "char", "profession", "cooldowns", "cooldowns", "char", "profession" }, kinds)
        assert.equals(2, rows[1].ready)
        assert.equals(now + 600, rows[1].dueAt)
        assert.equals(2, #rows[3].cooldowns)
        assert.equals(1, #rows[4].cooldowns)
        assert.equals(0, rows[5].ready)
        assert.equals(now + 3600, rows[5].dueAt)
        assert.is_true(Popup.Height(40) == Popup.Height(14) and Popup.Height(0) == Popup.Height(1))

        char().professions = { [2900] = { name = "Alchemy", amount = 1000, max = 1000, cycleSec = 360, readAt = now } }
        char().cooldowns = { [700] = { name = "Transmute", readyAt = now - 1 } }
        Popup.Open()
        assert.is_true(Popup.IsOpen())
        local frame = _G.GoblinomicsProfessionPopup
        assert.equals(3, #frame.rows)
        Popup.Toggle()
        assert.is_false(Popup.IsOpen())
    end)

    it("waits with the overview window until the fight is over", function()
        local Popup = wns.ProfessionPopup
        WoWMock.combat = true
        Popup.Open()
        assert.is_false(Popup.IsOpen())
        WoWMock.combat = false
        WoWMock.fire("PLAYER_REGEN_ENABLED")
        assert.is_true(Popup.IsOpen())
    end)

    it("does not open the overview at login when it is switched off", function()
        local root = GoblinomicsWorkshopDB
        root.settings.notifyChat = false
        root.chars["Alt-Realm"] = { name = "Alt", professions = { [2901] = { name = "Blacksmithing", amount = 1000,
            max = 1000, cycleSec = 360, readAt = WoWMock.now } } }
        WoWMock.advance(7)
        WoWMock.flush()
        assert.is_false(wns.ProfessionPopup.IsOpen())
    end)
end)
