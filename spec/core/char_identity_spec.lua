describe("Character identity", function()
    local function forever(rules)
        return function()
            WoWMock.set_client("forever")
            WoWMock.regionalNames = true
            WoWMock.player.name, WoWMock.player.realm = "Nimble", "CAMWOWEU5Realm9PvP"
            for _, rule in ipairs(rules or {}) do WoWMock.gameRules[Enum.GameRule[rule]] = true end
        end
    end

    it("keys retail characters by name and normalised realm", function()
        local ns = load_core()
        assert.equals("xLN-Blackrock", ns.CharKey())
    end)

    it("keys characters with region-wide names by name and ruleset", function()
        assert.equals("Nimble-PvE", load_core({ prepare = forever() }).CharKey())
        assert.equals("Nimble-PvP", load_core({ prepare = forever({ "PvPRuleset" }) }).CharKey())
        assert.equals("Nimble-RP", load_core({ prepare = forever({ "RPRuleset" }) }).CharKey())
        assert.equals("Nimble-RPPvP", load_core({ prepare = forever({ "RPRuleset", "PvPRuleset" }) }).CharKey())
        assert.equals("Nimble-HC", load_core({ prepare = forever({ "HardcoreRuleset", "PvPRuleset" }) }).CharKey())
    end)

    it("merges the shard-realm key of the same character at login", function()
        local ns = load_core({ login = true, prepare = forever({ "PvPRuleset" }), db = { _schema = 3, chars = {
            ["Nimble-CAMWOWEU5Realm6PvP"] = { name = "Nimble", money = 500, lastTab = "flips" },
            ["Nimble-CAMWOWEU5Realm9PvP"] = { name = "Nimble", money = 900 },
            -- 1.3.0 after Blizzard emptied the realm name
            ["Nimble-"] = { name = "Nimble", money = 950 },
            ["Fred-CAMWOWEU5Realm6PvP"] = { name = "Fred", money = 7 },
        } } })
        local chars = GoblinomicsDB.chars
        assert.is_nil(chars["Nimble-CAMWOWEU5Realm6PvP"])
        assert.is_nil(chars["Nimble-CAMWOWEU5Realm9PvP"])
        assert.is_nil(chars["Nimble-"])
        assert.equals(chars["Nimble-PvP"], ns.coreDB.char)
        assert.equals("flips", chars["Nimble-PvP"].lastTab)
        assert.equals("PvP", chars["Nimble-PvP"].realm)
        -- other characters move when they log in themselves
        assert.equals(7, chars["Fred-CAMWOWEU5Realm6PvP"].money)
        assert.same({ "Fred-CAMWOWEU5Realm6PvP", "Nimble-PvP" }, ns.API.KnownCharacters())
    end)

    it("rewrites references in module namespaces, including ones created later", function()
        local ns = load_core({ boot = true, prepare = forever({ "PvPRuleset" }), db = { _schema = 3, chars = {
            ["Nimble-CAMWOWEU5Realm6PvP"] = { name = "Nimble" } } } })
        _G.GoblinomicsEarlyDB = { _schema = 1, chars = { ["Nimble-CAMWOWEU5Realm6PvP"] = { a = 1 } },
            charIndex = { "Nimble-CAMWOWEU5Realm6PvP", "Fred-X" },
            records = { { char = "Nimble-CAMWOWEU5Realm6PvP", note = "Nimble-CAMWOWEU5Realm6PvP!" } },
            settings = { hidden = { ["Nimble-CAMWOWEU5Realm6PvP"] = true } } }
        local early = ns.DB:Namespace("Early", "GoblinomicsEarlyDB", {})
        WoWMock.loggedIn = true
        WoWMock.fire("PLAYER_LOGIN")
        assert.same({ a = 1 }, early.root.chars["Nimble-PvP"])
        assert.same({ "Nimble-PvP", "Fred-X" }, early.root.charIndex)
        assert.equals("Nimble-PvP", early.root.records[1].char)
        assert.equals("Nimble-CAMWOWEU5Realm6PvP!", early.root.records[1].note)
        assert.is_true(early.settings.hidden["Nimble-PvP"])
        assert.same({ ["Nimble-CAMWOWEU5Realm6PvP"] = "Nimble-PvP" }, GoblinomicsDB.charRenames)

        _G.GoblinomicsLateDB = { chars = { ["Nimble-CAMWOWEU5Realm6PvP"] = { b = 2 } } }
        local late = ns.DB:Namespace("Late", "GoblinomicsLateDB", {})
        assert.same({ b = 2 }, late.root.chars["Nimble-PvP"])
        _G.GoblinomicsEarlyDB, _G.GoblinomicsLateDB = nil, nil
    end)

    it("applies a rename once per namespace and keeps data written afterwards", function()
        local ns = load_core()
        _G.GoblinomicsTestDB = { chars = { old = { x = 1 }, new = { x = 2, y = 3 } } }
        local db = ns.DB:Namespace("T", "GoblinomicsTestDB", {})
        ns.DB.RenameChars({ old = "new" })
        assert.same({ new = { x = 2, y = 3 } }, db.root.chars)
        db.root.chars.old = { later = true }
        ns.DB.RenameChars({ old = "new" })
        assert.same({ later = true }, db.root.chars.old)
        _G.GoblinomicsTestDB = nil
    end)

    it("leaves retail keys alone", function()
        load_core({ login = true, db = { _schema = 3, chars = {
            ["xLN-Blackrock"] = { name = "xLN" }, ["xLN-Alleria"] = { name = "xLN" } } } })
        assert.is_table(GoblinomicsDB.chars["xLN-Alleria"])
        assert.is_nil(GoblinomicsDB.charRenames)
    end)
end)
