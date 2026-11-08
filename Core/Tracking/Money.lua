if GOBLINOMICS_CLIENT_BLOCKED then return end
-- Core/Tracking/Money.lua
-- MONEY_DELTA stream for the character (PLAYER_MONEY) and the warband bank
-- (ACCOUNT_MONEY). Baseline when the tracker starts; GetMoney() can read 0 shortly
-- after login, so 0 is re-read up to 30 times at one-second intervals (TSM).
-- Secret readings are skipped; the next plain reading carries the full delta.
local _, ns = ...

local MoneyTracker = {}
ns.MoneyTracker = MoneyTracker

local Bus, Context, Restriction, Timer = ns.Bus, ns.Context, ns.Restriction, ns.Timer
local events = ns.Events.NewDispatcher("Core.Money")
local OWNER = "Core.Money"
local MAX_ZERO_RETRIES = 30

local lastPlayer, lastWarband = nil, nil
local zeroRetries = 0
-- GetMoney() reads 0 while the client leaves the world (logout, reload, loading
-- screens); readings in that window are ignored so no phantom delta appears.
local leaving = false

local IsSecret = Restriction.IsSecret

local function CanAccessWarband()
    if ns.Flavor.IsForever() then return false end   -- no warband bank there
    if not (C_Bank and C_Bank.FetchDepositedMoney and Enum and Enum.BankType) then
        return false
    end
    if C_PlayerInfo and C_PlayerInfo.HasAccountInventoryLock then
        return C_PlayerInfo.HasAccountInventoryLock() == true
    end
    return true
end

local function FetchWarband()
    if not CanAccessWarband() then return nil end
    return C_Bank.FetchDepositedMoney(Enum.BankType.Account)
end

local function Emit(scope, amount, total, t, reconciled)
    Bus.Emit("MONEY_DELTA", {
        scope = scope, amount = amount, total = total, time = t,
        context = Context.Snapshot(),
        restricted = Restriction.ReplayKind() or false,
        reconciled = reconciled == true,
    })
end

local function ApplyPlayer(money, t, reconciled)
    if lastPlayer == nil then
        lastPlayer = money
        return
    end
    local delta = money - lastPlayer
    lastPlayer = money
    if delta ~= 0 then
        Emit("player", delta, money, t, reconciled)
    end
end

local function ApplyWarband(money, t, reconciled)
    if lastWarband == nil then
        lastWarband = money
        return
    end
    local delta = money - lastWarband
    lastWarband = money
    if delta ~= 0 then
        Emit("warband", delta, money, t, reconciled)
    end
end

local function ReadBaseline()
    if lastPlayer ~= nil then return end
    local money = GetMoney()
    if IsSecret(money) then return end
    if money == 0 and zeroRetries < MAX_ZERO_RETRIES then
        zeroRetries = zeroRetries + 1
        Timer.After(1, ReadBaseline, OWNER)
        return
    end
    lastPlayer = money
end

local function OnPlayerMoney()
    if leaving then return end
    local money = GetMoney()
    if Restriction.IsActive() then
        Restriction.Buffer("PLAYER_MONEY", money)
        return
    end
    if IsSecret(money) then return end
    ApplyPlayer(money, time())
end

local function OnAccountMoney()
    if leaving then return end
    local money = FetchWarband()
    if money == nil then return end
    if Restriction.IsActive() then
        Restriction.Buffer("ACCOUNT_MONEY", money)
        return
    end
    if IsSecret(money) then return end
    ApplyWarband(money, time())
end

Restriction.RegisterReplay("PLAYER_MONEY", function(value, _, t) ApplyPlayer(value, t) end)
Restriction.RegisterReplay("ACCOUNT_MONEY", function(value, _, t) ApplyWarband(value, t) end)

Restriction.OnLeave(function()
    if not Bus.IsServiceActive("money") then return end
    local money = GetMoney()
    if not IsSecret(money) and lastPlayer ~= nil and money ~= lastPlayer then
        ApplyPlayer(money, time(), true)
    end
    local warband = FetchWarband()
    if warband ~= nil and not IsSecret(warband) and lastWarband ~= nil and warband ~= lastWarband then
        ApplyWarband(warband, time(), true)
    end
end)

function MoneyTracker.GetPlayer() return lastPlayer end

--- Last reliable character money (never the 0 the client reports while logging out).
function ns.API.PlayerMoney() return lastPlayer end

local function OnLeavingWorld() leaving = true end
local function OnEnteringWorld() leaving = false end
function MoneyTracker.GetWarband() return lastWarband end

Bus.DefineService("money", {
    deps = { "context", "restriction" },
    events = { "MONEY_DELTA" },
    start = function()
        zeroRetries = 0
        ReadBaseline()
        local warband = FetchWarband()
        if warband ~= nil and not IsSecret(warband) then
            lastWarband = warband
        end
        events:Register("PLAYER_MONEY", OnPlayerMoney)
        events:Register("ACCOUNT_MONEY", OnAccountMoney)
        events:Register("PLAYER_LEAVING_WORLD", OnLeavingWorld)
        events:Register("PLAYER_ENTERING_WORLD", OnEnteringWorld)
    end,
    stop = function()
        events:UnregisterAll()
        Timer.CancelOwner(OWNER)
        lastPlayer, lastWarband = nil, nil
    end,
})
