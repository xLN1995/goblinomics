-- Project rule: code is ASCII-only (multi-byte characters corrupt in the packaging
-- pipeline); translated text lives only in Locales/.
describe("Code rules", function()
    it("keeps every code file ASCII-only", function()
        local offenders = {}
        local p = io.popen('find Core Modules Connectors -name "*.lua"')
        for file in p:lines() do
            local fh = assert(io.open(file, "rb"))
            local n = 0
            for line in fh:lines() do
                n = n + 1
                if line:find("[\128-\255]") then offenders[#offenders + 1] = file .. ":" .. n end
            end
            fh:close()
        end
        p:close()
        assert.same({}, offenders)
    end)

    it("never subscribes one bus or game event twice as the same module (the second handler would replace the first)", function()
        local p = io.popen('ls -d Modules/*/')
        local dups = {}
        for dir in p:lines() do
            local seen = {}
            local files = io.popen('ls ' .. dir .. '*.lua')
            for file in files:lines() do
                local fh = assert(io.open(file))
                local src = fh:read("*a")
                fh:close()
                for event in src:gmatch('[%a_]+:On%("([%u_]+)"') do
                    if seen[event] then dups[#dups + 1] = dir .. " " .. event end
                    seen[event] = true
                end
                -- an explicit handler key (third argument) keeps handlers apart
                for event, rest in src:gmatch('[%a_]+:RegisterEvent%("([%u_]+)"([^\n]*)') do
                    local id = "event:" .. event .. ":" .. (rest:match(',[^,]+,%s*"([%w_]+)"%)') or event)
                    if seen[id] then dups[#dups + 1] = dir .. " RegisterEvent " .. event end
                    seen[id] = true
                end
            end
            files:close()
        end
        p:close()
        assert.same({}, dups)
    end)

    it("keeps personal names, machine paths and internal documents out of the public repository", function()
        local hits = {}
        local words = { "fr" .. "ank", "dusch" .. "icka", "ged" .. "ak", "cla" .. "ude", "anthr" .. "opic", "/ho" .. "me/", "do" .. "cs/" }
        local p = io.popen("grep -rniIlE '" .. table.concat(words, "|") .. "' Core Modules Connectors Locales Libs spec tools .github"
            .. " README.md CHANGELOG.md LICENSE .pkgmeta .gitignore Goblinomics.toc Bindings.xml")
        for file in p:lines() do hits[#hits + 1] = file end
        p:close()
        assert.same({}, hits)
    end)

    it("uses only the public API from module addons (ns there is the module's own namespace)", function()
        local hits = {}
        local pattern = "(^|[^A-Za-z0-9_])ns\\.(Print|Lf|Timer|Bus|Events|Price|Modules)([^A-Za-z0-9_]|$)"
        local p = io.popen("grep -rnE '" .. pattern .. "' Modules Connectors")
        for line in p:lines() do hits[#hits + 1] = line end
        p:close()
        assert.same({}, hits)
    end)

    it("calls the farming module Gatherer (Prospector only in the core migration)", function()
        local hits = {}
        local p = io.popen("grep -rniIl prospector Core Modules Connectors Locales")
        for file in p:lines() do
            if file ~= "Core/Bootstrap.lua" then hits[#hits + 1] = file end
        end
        p:close()
        assert.same({}, hits)
    end)

    -- Design rules: one theme for every module --------------------------
    local function uiFiles()
        local list = {}
        local p = io.popen('find Core/UI Modules -name "*.lua"')
        for file in p:lines() do list[#list + 1] = file end
        p:close()
        return list
    end

    local function scan(pattern, allowed)
        local hits = {}
        for _, file in ipairs(uiFiles()) do
            if not (allowed and allowed[file]) then
                local fh = assert(io.open(file))
                local n = 0
                for line in fh:lines() do
                    n = n + 1
                    if line:match(pattern) and not line:match("^%s*%-%-") then hits[#hits + 1] = file .. ":" .. n end
                end
                fh:close()
            end
        end
        return hits
    end

    it("uses the theme fonts, never Blizzard font objects", function()
        assert.same({}, scan("GameFont"))
    end)

    it("takes colours from the theme, not from hex codes or RGB tables", function()
        -- item quality colours are the game's, not the theme's
        assert.same({}, scan("|cff%x%x%x%x%x%x", { ["Core/UI/Theme.lua"] = true, ["Modules/Gatherer/Highlights.lua"] = true }))
        assert.same({}, scan("{%s*[01]?%.%d+,%s*[01]?%.%d+,%s*[01]?%.%d+", { ["Core/UI/Theme.lua"] = true }))
    end)

    it("uses only the sizes of the type scale", function()
        local allowed = { ["9"] = true, ["10"] = true, ["11"] = true, ["12"] = true, ["14"] = true, ["16"] = true,
            ["18"] = true, ["24"] = true }
        local hits = {}
        for _, file in ipairs(uiFiles()) do
            local fh = assert(io.open(file))
            local src = fh:read("*a")
            fh:close()
            for size in src:gmatch("Theme%.Text%([^,]+,%s*(%d+)") do
                if not allowed[size] then hits[#hits + 1] = file .. ": " .. size end
            end
        end
        assert.same({}, hits)
    end)
end)

