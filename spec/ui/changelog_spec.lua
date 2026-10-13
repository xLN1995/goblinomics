-- "What's new" window: version order, entries since the last login, the popup
-- once after an update, the footer of the main window, and CHANGELOG.md and
-- Core/ChangelogData.lua saying the same.
describe("UI: changelog", function()
    after_each(function() assert.same({}, WoWMock.errors) end)

    --- Core booted, the running version set, then the login.
    local function login(version, db)
        local ns = load_core({ boot = true, db = db })
        Goblinomics.VERSION = version
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
        return ns
    end

    local EXISTING = { _schema = 3, settings = {}, setup = { done = true } }

    local function existing(seen)
        local db = {}
        for k, v in pairs(EXISTING) do db[k] = v end
        db.changelog = seen and { seen = seen } or nil
        return db
    end

    it("orders versions", function()
        local ns = load_core()
        local cmp = ns.Changelog.CompareVersions
        assert.equals(1, cmp("1.0.10", "1.0.2"))
        assert.equals(-1, cmp("1.0.2", "1.1"))
        assert.equals(0, cmp("v1.0.2", "1.0.2"))
        assert.equals(-1, cmp("1.1.0-beta", "1.1.0"))
        assert.equals(1, cmp("0.9.2-beta", "0.9.1-beta"))
        assert.equals(1, cmp("dev", "9.9.9"))
        assert.equals(1, cmp("unreleased", "1.0.2"))
    end)

    it("lists the entries since the last seen version", function()
        local ns = load_core()
        ns.CHANGELOG = {
            { version = "unreleased" }, { version = "1.0.2" }, { version = "1.0.1" }, { version = "1.0.0" },
        }
        local function versions(list)
            local out = {}
            for i, e in ipairs(list) do out[i] = e.version end
            return out
        end
        assert.same({ "1.0.2", "1.0.1" }, versions(ns.Changelog.EntriesSince("1.0.0", "v1.0.2")))
        assert.same({ "1.0.2" }, versions(ns.Changelog.EntriesSince(nil, "v1.0.2")))
        assert.same({}, versions(ns.Changelog.EntriesSince("1.0.2", "1.0.2")))
        assert.same({ "unreleased" }, versions(ns.Changelog.EntriesSince(nil, "dev")))
    end)

    it("opens once after an update and remembers the version", function()
        local ns = login("1.0.2", existing("1.0.1"))
        assert.is_false(ns.Changelog.IsShown())
        WoWMock.advance(7)
        assert.is_true(ns.Changelog.IsShown())
        local win = ns.Changelog.window()
        win.buttons[1]:GetScript("OnClick")(win.buttons[1], "LeftButton")
        assert.is_false(ns.Changelog.IsShown())
        assert.equals("1.0.2", GoblinomicsDB.changelog.seen)

        ns = login("1.0.2", existing("1.0.2"))
        WoWMock.advance(7)
        assert.is_false(ns.Changelog.IsShown())
    end)

    it("shows the current version's notes to installations from before the changelog", function()
        local ns = login("1.0.2", existing(nil))
        WoWMock.advance(7)
        assert.is_true(ns.Changelog.IsShown())
    end)

    it("stays closed in dev builds and on fresh installations", function()
        local ns = login("dev", existing(nil))
        WoWMock.advance(7)
        assert.is_false(ns.Changelog.IsShown())

        ns = login("1.0.2", nil)
        assert.equals("1.0.2", GoblinomicsDB.changelog.seen)
        WoWMock.advance(7)
        assert.is_false(ns.Changelog.IsShown())
    end)

    it("waits for the end of combat, and combat closes it without marking it seen", function()
        local ns = load_core({ boot = true, db = existing("1.0.1") })
        Goblinomics.VERSION = "1.0.2"
        WoWMock.combat = true
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
        WoWMock.advance(7)
        assert.is_false(ns.Changelog.IsShown())
        WoWMock.combat = false
        WoWMock.advance(11)
        assert.is_true(ns.Changelog.IsShown())
        WoWMock.fire("PLAYER_REGEN_DISABLED")
        assert.is_false(ns.Changelog.IsShown())
        assert.equals("1.0.1", GoblinomicsDB.changelog.seen)
    end)

    it("names new modules and their install state", function()
        local ns = load_core({ login = true })
        assert.equals("GatherMate2 Connector", ns.Changelog.ModuleTitle("Goblinomics_Connector_GatherMate2"))
        assert.equals("Vault", ns.Changelog.ModuleTitle("Goblinomics_Vault"))
        assert.equals("active", ns.Changelog.AddonState("Goblinomics_Vault"))
        ns.CHANGELOG = { { version = "unreleased", modules = { { addon = "Goblinomics_Vault", text = "x" } },
            sections = { { title = "Added", items = { "y" } } } } }
        assert.is_true(ns.Changelog.Show(true))
    end)

    it("has a footer with the version and a changelog button", function()
        local ns = login("v1.0.2", existing("1.0.2"))
        ns.UI.Show("dashboard")
        local footer = _G.GoblinomicsMainWindow.footer
        assert.equals("v1.0.2", footer.version:GetText())
        footer.changelog:GetScript("OnClick")(footer.changelog, "LeftButton")
        assert.is_true(ns.Changelog.IsShown())
        assert.is_true(ns.EntryPoints.HandleSlash ~= nil)
    end)

    describe("CHANGELOG.md and Core/ChangelogData.lua", function()
        --- CHANGELOG.md the way ChangelogData.lua stores it: bullets joined to one
        -- line, without backticks and bold marks.
        local function parse_markdown()
            local entries, entry, section, item = {}, nil, nil, nil
            local function flush()
                if item then section.items[#section.items + 1] = table.concat(item, " ") end
                item = nil
            end
            local function clean(s) return (s:gsub("`", ""):gsub("%*%*", "")) end
            for line in io.lines("CHANGELOG.md") do
                local version, date = line:match("^## %[(.-)%]%s*%-?%s*(%S*)")
                if version then
                    if section then flush() end
                    entry = { version = version == "Unreleased" and "unreleased" or version,
                        date = date ~= "" and date or nil, intro = {}, sections = {} }
                    entries[#entries + 1] = entry
                    section = nil
                elseif entry then
                    local title = line:match("^### (.+)$")
                    if title then
                        if section then flush() end
                        section = { title = title, items = {} }
                        entry.sections[#entry.sections + 1] = section
                    elseif line:match("^%- ") then
                        flush()
                        item = { clean(line:sub(3):match("^%s*(.-)%s*$")) }
                    elseif line:match("^  %S") and item then
                        item[#item + 1] = clean(line:match("^%s*(.-)%s*$"))
                    elseif line:match("^%s*$") then
                        if section then flush() end
                    elseif not section then
                        entry.intro[#entry.intro + 1] = clean(line)
                    end
                end
            end
            if section then flush() end
            return entries
        end

        local function data_entries()
            local ns = {}
            load_addon_file("Core/ChangelogData.lua", "Goblinomics", ns)
            return ns.CHANGELOG
        end

        it("list the same versions with the same text", function()
            local md, data = parse_markdown(), data_entries()
            assert.equals(#md, #data)
            for i, m in ipairs(md) do
                local d = data[i]
                assert.equals(m.version, d.version)
                assert.equals(m.date, d.date)
                assert.equals(#m.intro > 0 and table.concat(m.intro, " ") or nil, d.intro)
                local sections, modules = {}, {}
                for _, s in ipairs(m.sections) do
                    if s.title == "New modules" then
                        for _, it in ipairs(s.items) do
                            local addon, text = it:match("^([%w_]+):%s*(.+)$")
                            assert.is_string(addon, "New modules bullet needs 'Folder_Name: text': " .. it)
                            modules[#modules + 1] = { addon = addon, text = text }
                        end
                    else
                        sections[#sections + 1] = s
                    end
                end
                assert.same(sections, d.sections or {})
                assert.same(modules, d.modules or {})
            end
        end)

        it("only announce modules the release ships", function()
            local fh = assert(io.open(".pkgmeta"))
            local pkgmeta = fh:read("*a")
            fh:close()
            for _, e in ipairs(data_entries()) do
                for _, m in ipairs(e.modules or {}) do
                    assert.truthy(pkgmeta:find(": " .. m.addon .. "\n", 1, true), m.addon .. " missing in .pkgmeta")
                end
            end
        end)

        it("have an unreleased entry only on top", function()
            for i, e in ipairs(data_entries()) do
                if i > 1 then assert.is_not.equals("unreleased", e.version) end
                if e.version ~= "unreleased" then assert.is_string(e.date) end
            end
        end)
    end)
end)
