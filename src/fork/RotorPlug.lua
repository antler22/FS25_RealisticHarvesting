-- EN: Rotor plugging - the fork's consequence for overloading the machine, layered over upstream WITHOUT
--     editing upstream's files.
--
--     The rule, as in the fork: engine load held at 130 % or more for 10 continuous seconds plugs the rotor.
--     A plugged machine crawls at 1 km/h for 12 seconds while it clears, at any electronics tier, with a
--     blinking warning. A "PLUG RISK" warning appears at the halfway mark so there is time to back off.
--     Dropping below 130 % resets the timer at once.
--
--     Why it matters here: below tier 3 there is no automatic speed control, and above it the controller
--     brakes at 102 % - so 130 % for ten seconds happens when a person drives into a crop the machine
--     cannot swallow (or a surge outruns the controller). Until now that cost crop loss and nothing else.
--
--     How it is built
--       - state machine on the server, advanced from rhm_Combine:onUpdateTick (dt in ms) from upstream's own
--         engine-load reading (loadCalculator.engineLoad, a ratio where 1.0 = 100 %);
--       - the stop is applied through the vehicle's getSpeedLimit - the value the engine's Drivable
--         specialization hands the motor every update (Drivable.lua:611-617) and the AI helper reads
--         (AIFieldWorker.lua:298) - so it holds for a driver, cruise control and a hired worker alike;
--       - clients are told by a small event when the state changes, and joiners get it appended to upstream's
--         initial stream; the warning shows only for the player sitting in that machine;
--       - off in Training mode (the sandbox has no consequences) and in Arcade motor difficulty (upstream reports
--         zero load there, so it never builds);
--       - rhmPlugging on|off|status.
--
--     Not carried over: the "PLUGGED" icon on the fork's HUD and the plug count in its session report -
--     upstream's HUD and tracker have no place for them; the warnings carry the information.
--
-- UA: Забивання ротора - наслідок перевантаження машини в форку, поверх оригіналу БЕЗ правок його файлів.
--     Навантаження двигуна >= 130 % безперервно 10 с забиває ротор: 12 с машина повзе зі швидкістю 1 км/год,
--     на будь-якому рівні електроніки, з миготливим попередженням. На півдорозі - "ризик забивання".
RotorPlug = {}

RotorPlug.enabled = true
RotorPlug.LOAD_THRESHOLD = 1.30       -- engine load ratio
RotorPlug.RISK_AFTER_MS  = 5000
RotorPlug.PLUG_AFTER_MS  = 10000
RotorPlug.CLEAR_MS       = 12000
RotorPlug.SPEED_KMH      = 1.0

RotorPlug.OK, RotorPlug.RISK, RotorPlug.PLUGGED = 0, 1, 2
local WARNING_ID = "RHM_ROTOR_PLUG"

local warned = {}
local function reportOnce(key, err)
    if warned[key] then return end
    warned[key] = true
    Logging.warning("[RHM-fork] RotorPlug %s failed: %s", tostring(key), tostring(err))
end

-- ============================================================================
-- EN: State
-- UA: Стан
-- ============================================================================

function RotorPlug.get(vehicle)
    local spec = vehicle and vehicle.spec_rhm_Combine
    return spec and spec.forkPlugState or RotorPlug.OK
end

function RotorPlug.isPlugged(vehicle)
    return RotorPlug.get(vehicle) == RotorPlug.PLUGGED
end

local function text(key, fallback)
    return (g_i18n and g_i18n:hasText(key) and g_i18n:getText(key)) or fallback
end

-- EN: Local state, plus the warning for the player in this machine. Used by the server for itself, by the
--     event on clients, and by the stream on joiners.
-- UA: Локальний стан і попередження для гравця в цій машині.
function RotorPlug.apply(vehicle, state)
    local spec = vehicle and vehicle.spec_rhm_Combine
    if not spec then return false end
    state = tonumber(state) or RotorPlug.OK
    local previous = spec.forkPlugState or RotorPlug.OK
    spec.forkPlugState = state

    if state ~= previous and vehicle.isClient and g_currentMission and g_currentMission.showBlinkingWarning
        and vehicle.getIsEntered and vehicle:getIsEntered() then
        if state == RotorPlug.PLUGGED then
            g_currentMission:showBlinkingWarning(text("rhm_warn_rotor_plugged", "ROTOR PLUGGED! Reverse and clear the machine."), 8000, WARNING_ID)
        elseif state == RotorPlug.RISK then
            g_currentMission:showBlinkingWarning(text("rhm_warn_plug_risk", "PLUG RISK"), 3000, WARNING_ID)
        end
    end
    return true
end

-- EN: Advance the server-side state machine by dt ms. Returns the new state if it changed, else nil.
function RotorPlug.step(vehicle, dt)
    local spec = vehicle.spec_rhm_Combine
    local calc = spec and spec.loadCalculator
    if not calc then return nil end

    local st = spec._plug
    if not st then st = { timer = 0, clear = 0 }; spec._plug = st end
    local current = spec.forkPlugState or RotorPlug.OK
    local new = current

    if current == RotorPlug.PLUGGED then
        st.clear = st.clear - dt
        if st.clear <= 0 then
            st.clear, st.timer = 0, 0
            new = RotorPlug.OK
        end
    else
        local blocked = (not RotorPlug.enabled)
            or (TrainingMode and TrainingMode.isActive)
            or ((calc.engineLoad or 0) < RotorPlug.LOAD_THRESHOLD)
        if blocked then
            st.timer = 0
            new = RotorPlug.OK
        else
            st.timer = st.timer + dt
            if st.timer >= RotorPlug.PLUG_AFTER_MS then
                st.timer, st.clear = 0, RotorPlug.CLEAR_MS
                new = RotorPlug.PLUGGED
            elseif st.timer >= RotorPlug.RISK_AFTER_MS then
                new = RotorPlug.RISK
            else
                new = RotorPlug.OK
            end
        end
    end

    if new ~= current then return new end
    return nil
end

-- EN: Server tick: step, apply, tell the clients.
function RotorPlug.tick(vehicle, dt)
    local changed = RotorPlug.step(vehicle, dt)
    if changed ~= nil then
        RotorPlug.apply(vehicle, changed)
        if g_server ~= nil then
            g_server:broadcastEvent(ForkRotorPlugEvent.new(vehicle, changed), nil, nil, vehicle)
        end
    end
    return changed
end

-- ============================================================================
-- EN: Network - server to clients only
-- UA: Мережа - лише від сервера до клієнтів
-- ============================================================================

ForkRotorPlugEvent = {}
local ForkRotorPlugEvent_mt = Class(ForkRotorPlugEvent, Event)
InitEventClass(ForkRotorPlugEvent, "ForkRotorPlugEvent")

function ForkRotorPlugEvent.emptyNew()
    return Event.new(ForkRotorPlugEvent_mt)
end

function ForkRotorPlugEvent.new(vehicle, state)
    local self = ForkRotorPlugEvent.emptyNew()
    self.vehicle = vehicle
    self.state = state or RotorPlug.OK
    return self
end

function ForkRotorPlugEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUInt8(streamId, self.state or RotorPlug.OK)
end

function ForkRotorPlugEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.state = streamReadUInt8(streamId)
    self:run(connection)
end

function ForkRotorPlugEvent:run(connection)
    -- Only the server decides; a client never accepts this from another client.
    if connection == nil or not connection:getIsServer() then return end
    local vehicle = self.vehicle
    if not vehicle or vehicle.isDeleted or not vehicle.spec_rhm_Combine then return end
    RotorPlug.apply(vehicle, self.state)
end

-- ============================================================================
-- EN: Hooks on rhm_Combine (through the installer - the engine replaces that table; see SpecHooks.lua)
-- UA: Хуки на rhm_Combine (через інсталер)
-- ============================================================================

local function wrapMethod(class, className, name, wrapper)
    local orig = class and class[name]
    if type(orig) ~= "function" then
        Logging.warning("[RHM-fork] RotorPlug: %s.%s not found - rotor plugging inactive", className, name)
        return false
    end
    class[name] = function(...) return wrapper(orig, ...) end
    return true
end

local function hookSpec(method, wrapper)
    ForkSpecHooks.add("rotor plug: " .. method, function()
        wrapMethod(rhm_Combine, "rhm_Combine", method, wrapper)
    end)
end

-- The stop. Outside every other getSpeedLimit hook, so it holds whatever they decided.
hookSpec("getSpeedLimit", function(orig, self, superFunc, onlyIfWorking)
    local limit, doCheckSpeedLimit = orig(self, superFunc, onlyIfWorking)
    if RotorPlug.isPlugged(self) then
        local spec = self.spec_rhm_Combine
        if spec then spec.isSpeedLimitActive = true end
        return math.min(limit or math.huge, RotorPlug.SPEED_KMH), doCheckSpeedLimit
    end
    return limit, doCheckSpeedLimit
end)

-- The clock. After upstream's own tick, so it reads the engine load that tick produced.
hookSpec("onUpdateTick", function(orig, self, dt, ...)
    local r = orig(self, dt, ...)
    if self.isServer then
        local ok, err = pcall(RotorPlug.tick, self, dt)
        if not ok then reportOnce("tick", err) end
    end
    return r
end)

-- A player who joins while a machine is plugged. Appended to upstream's stream, in the same order both ends.
hookSpec("onWriteStream", function(orig, self, streamId, connection)
    orig(self, streamId, connection)
    streamWriteUInt8(streamId, RotorPlug.get(self))
end)

hookSpec("onReadStream", function(orig, self, streamId, connection)
    orig(self, streamId, connection)
    RotorPlug.apply(self, streamReadUInt8(streamId))
end)

-- ============================================================================
-- EN: Console
-- UA: Консоль
-- ============================================================================
function RotorPlug.consoleCommand(_, arg)
    local a = arg and tostring(arg):lower() or ""
    if a == "on" or a == "1" then RotorPlug.enabled = true
    elseif a == "off" or a == "0" then RotorPlug.enabled = false
    elseif a ~= "" and a ~= "status" then return "Usage: rhmPlugging [on|off|status]" end

    local out = string.format("Rotor plugging: %s (%.0f %% load for %.0f s; %.0f s to clear)",
        RotorPlug.enabled and "ON" or "OFF", RotorPlug.LOAD_THRESHOLD * 100,
        RotorPlug.PLUG_AFTER_MS / 1000, RotorPlug.CLEAR_MS / 1000)
    local veh = g_realisticHarvestManager and g_realisticHarvestManager.lastActiveCombine
    if veh and veh.spec_rhm_Combine then
        local names = { [0] = "clear", [1] = "RISK", [2] = "PLUGGED" }
        local st = veh.spec_rhm_Combine._plug
        out = out .. string.format("\n  active machine: %s (overload timer %.1f s)", names[RotorPlug.get(veh)] or "?", (st and st.timer or 0) / 1000)
    end
    return out
end

if RHM_RealisticHarvestManager and type(RHM_RealisticHarvestManager.new) == "function" then
    local origNew = RHM_RealisticHarvestManager.new
    RHM_RealisticHarvestManager.new = function(...)
        local self = origNew(...)
        addConsoleCommand("rhmPlugging", "rhmPlugging [on|off|status] - rotor plugging on sustained overload", "consoleCommand", RotorPlug)
        return self
    end
end
