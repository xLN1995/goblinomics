-- LibDBIcon stub (LibStub keeps libraries across specs, so define it once).
local icon = LibStub:NewLibrary("LibDBIcon-1.0", 1) or LibStub("LibDBIcon-1.0")
icon.registered = icon.registered or {}
function icon:Register(name, obj, db) self.registered[name] = { obj = obj, db = db } end
function icon:IsRegistered(name) return self.registered[name] ~= nil end
function icon:Show(name) self.registered[name].shown = true end
function icon:Hide(name) self.registered[name].shown = false end

describe("Core/EntryPoints", function()
    local ns

    before_each(function()
        icon.registered = {}
        -- LDB objects persist in the library; give every spec a clean slate.
        local ldb = LibStub("LibDataBroker-1.1")
        ldb.proxystorage = ldb.proxystorage or {}
        ldb.proxystorage.Goblinomics = nil
        ldb.namestorage = ldb.namestorage or {}
        for k, v in pairs(ldb.namestorage) do if v == "Goblinomics" then ldb.namestorage[k] = nil end end
        ldb.attributestorage = ldb.attributestorage or {}
        ns = load_core({ login = true, money = 5000 })
    end)

    it("creates the LDB feed with an icon and registers the minimap button with the live settings", function()
        assert.is_table(ns.EntryPoints.ldb)
        assert.truthy(ns.EntryPoints.ldb.icon:find("goblinomics_icon_64", 1, true))
        local reg = icon.registered.Goblinomics
        assert.equals(ns.coreDB.settings.minimap, reg.db)
    end)

    it("updates the LDB text on player money changes", function()
        WoWMock.set_money(143000000)
        WoWMock.fire("PLAYER_MONEY")
        assert.truthy(ns.EntryPoints.ldb.text:find("14.3K", 1, true))
    end)

    it("toggles the minimap button through the setting", function()
        ns.EntryPoints.SetMinimapShown(false)
        assert.is_true(ns.coreDB.settings.minimap.hide)
        assert.is_false(icon.registered.Goblinomics.shown)
    end)

    it("fills the tooltip with character and warband gold", function()
        WoWMock.set_money(10000)
        WoWMock.warband = 20000
        ns.EntryPoints.FillTooltip(GameTooltip)
        local text = table.concat(GameTooltip.lines, "\n")
        assert.truthy(text:find("Character=", 1, true))
        assert.truthy(text:find("Warband bank=", 1, true))
    end)

    it("sets key binding labels and translates them at ADDON_LOADED", function()
        assert.equals("Goblinomics", BINDING_HEADER_GOBLINOMICS)
        assert.equals("Open or close the main window", BINDING_NAME_GOBLINOMICS_TOGGLE)
        _G.GoblinomicsDB = { _schema = 1, settings = { locale = "deDE" } }
        ns = load_core()
        _G.GoblinomicsDB = { _schema = 1, settings = { locale = "deDE" } }
        WoWMock.fire("ADDON_LOADED", "Goblinomics")
        assert.equals("Hauptfenster öffnen oder schließen", BINDING_NAME_GOBLINOMICS_TOGGLE)
    end)

    it("prints a perf report with the idle line", function()
        WoWMock.advance(5)
        ns.EntryPoints.HandleSlash("perf")
        assert.truthy(WoWMock.chat[1]:find("Idle: 0 timers, 0 jobs", 1, true))
        local all = table.concat(WoWMock.chat, "\n")
        assert.truthy(all:find("Memory: Goblinomics 512 KB", 1, true))
        ns.EntryPoints.HandleSlash("perf reset")
        assert.equals(0, #ns.Perf.Summary())
    end)
end)

describe("Core: entry points on WoW: Forever", function()
    it("knows no warband bank: no tooltip line, nothing tracked", function()
        local ns = load_core({ login = true, client = "forever", money = 10000 })
        WoWMock.warband = 20000
        assert.is_nil(ns.MoneyTracker.GetWarband())
        GameTooltip:SetOwner(nil)   -- the mock keeps lines across specs
        ns.EntryPoints.FillTooltip(GameTooltip)
        local text = table.concat(GameTooltip.lines, "\n")
        assert.truthy(text:find("Character=", 1, true))
        assert.is_nil(text:find("Warband bank=", 1, true))
    end)
end)
