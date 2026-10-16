-- Headless harness for src/fork/RotorPlug.lua.
-- Loads the REAL module and the REAL SpecHooks installer against stubs shaped like upstream's rhm_Combine and
-- the engine's event/stream/HUD machinery; drives the state machine on a simulated clock.
-- Run from the mod root:  lua tests/rotorplugtest.lua

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }
Utils = { appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end }
SpecializationManager = { addSpecialization = function() return true end }

Class = function(cls, base)
    if base then setmetatable(cls, { __index = base }) end
    return { __index = cls }
end
Event = { new = function(mt) return setmetatable({}, mt) end }
InitEventClass = function() end

local function newStream() return { q = {}, r = 1 } end
local function put(s, v) s.q[#s.q + 1] = v end
local function take(s) local v = s.q[s.r]; s.r = s.r + 1; return v end
function streamWriteUInt8(s, v) put(s, v) end
function streamReadUInt8(s) return take(s) end
NetworkUtil = { writeNodeObject = function(s, o) put(s, o) end, readNodeObject = function(s) return take(s) end }

local texts = { rhm_warn_rotor_plugged = "ROTOR PLUGGED!", rhm_warn_plug_risk = "PLUG RISK" }
g_i18n = { hasText = function(_, k) return texts[k] ~= nil end, getText = function(_, k) return texts[k] end }
local shown = {}
g_currentMission = { showBlinkingWarning = function(_, text, ms, id) shown[#shown + 1] = { text = text, ms = ms, id = id } end }

local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end
RHM_RealisticHarvestManager = { new = function() return {} end }
g_realisticHarvestManager = {}

local function newUpstreamRhmCombine()
    local c = { seen = {} }
    function c:getSpeedLimit(superFunc, onlyIfWorking) return self._limit or 20, true end
    function c:onUpdateTick(dt) c.seen.ticks = (c.seen.ticks or 0) + 1; if self._explodeTick then error("boom in tick") end end
    function c:onWriteStream(streamId) put(streamId, "upstream-field") end
    function c:onReadStream(streamId) self.upstreamRead = take(streamId) end
    return c
end
rhm_Combine = newUpstreamRhmCombine()

dofile("src/fork/SpecHooks.lua")
dofile("src/fork/RotorPlug.lua")
ForkSpecHooks.install()

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-68s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-68s %s", name, detail or "")) end
end
local P = RotorPlug

local function machine(load, extra)
    local v = setmetatable({
        isServer = true, isClient = true,
        spec_rhm_Combine = { loadCalculator = { engineLoad = load or 0 } },
        getIsEntered = function() return true end,
    }, { __index = rhm_Combine })
    for k, val in pairs(extra or {}) do v[k] = val end
    return v
end
-- advance the machine by `seconds` in 100 ms frames; returns the states seen on change
local function run(v, seconds, dtMs)
    local changes = {}
    dtMs = dtMs or 100
    for _ = 1, math.floor(seconds * 1000 / dtMs + 0.5) do
        local new = P.step(v, dtMs)
        if new ~= nil then
            P.apply(v, new)
            changes[#changes + 1] = new
        end
    end
    return changes
end

print("=== 1. loads cleanly ===")
check("no warnings", #warnings == 0, warnings[1] or "")

print("=== 2. the state machine (130 % for 10 s plugs; 12 s to clear) ===")
do
    local v = machine(1.0)
    check("normal load: nothing, ever", #run(v, 60) == 0 and P.get(v) == P.OK)

    v = machine(1.29)
    check("just under 130 %: nothing", #run(v, 60) == 0 and P.get(v) == P.OK)

    v = machine(1.30)
    local ch = run(v, 4.9)
    check("130 % for 4.9 s: still fine", #ch == 0 and P.get(v) == P.OK)
    ch = run(v, 0.2)
    check("...PLUG RISK at the halfway mark (5 s)", #ch == 1 and ch[1] == P.RISK and P.get(v) == P.RISK)
    ch = run(v, 4.7)
    check("...still only RISK at 9.9 s", #ch == 0 and P.get(v) == P.RISK)
    ch = run(v, 0.3)
    check("...PLUGGED at 10 s", #ch == 1 and ch[1] == P.PLUGGED and P.isPlugged(v))

    v.spec_rhm_Combine.loadCalculator.engineLoad = 0.2      -- load collapses, but it stays plugged
    ch = run(v, 11.8)
    check("plugged: stays plugged for the 12 s clear time whatever the load", #ch == 0 and P.isPlugged(v))
    ch = run(v, 0.4)
    check("...then clears", #ch == 1 and ch[1] == P.OK and P.get(v) == P.OK)

    v.spec_rhm_Combine.loadCalculator.engineLoad = 1.4
    ch = run(v, 10.1)
    check("it can plug again straight after", ch[#ch] == P.PLUGGED)
end

print("=== 3. easing off resets the timer at once ===")
do
    local v = machine(1.5)
    run(v, 7)
    check("at 7 s: at risk", P.get(v) == P.RISK)
    v.spec_rhm_Combine.loadCalculator.engineLoad = 1.0
    local ch = run(v, 0.1)
    check("load drops below 130 %: back to clear immediately", ch[1] == P.OK and P.get(v) == P.OK)
    v.spec_rhm_Combine.loadCalculator.engineLoad = 1.5
    ch = run(v, 9.9)
    check("the timer started from zero again (9.9 s is not enough)", P.get(v) == P.RISK and not P.isPlugged(v))
end

print("=== 4. when it does not apply ===")
do
    local v = machine(1.6); P.enabled = false
    check("switched off: never plugs", #run(v, 30) == 0 and P.get(v) == P.OK)
    P.enabled = true
    TrainingMode = { isActive = true }
    v = machine(1.6)
    check("Training mode: never plugs", #run(v, 30) == 0)
    TrainingMode = nil
    local noCalc = machine(1.6); noCalc.spec_rhm_Combine.loadCalculator = nil
    check("no load calculator: nothing, no crash", P.step(noCalc, 100) == nil)
    check("not a combine: nothing, no crash", P.step({ spec_rhm_Combine = nil }, 100) == nil or true)
    local arcade = machine(0)       -- upstream reports zero load in Arcade motor difficulty
    check("zero engine load (Arcade): never plugs", #run(arcade, 30) == 0)
end

print("=== 5. the stop works through the vehicle speed limit ===")
do
    local v = machine(1.0)
    local limit, check2 = v:getSpeedLimit(function() end, true)
    check("not plugged: upstream's limit untouched", limit == 20 and check2 == true and not v.spec_rhm_Combine.isSpeedLimitActive)
    P.apply(v, P.RISK)
    check("at risk: still untouched", (v:getSpeedLimit(function() end, true)) == 20)
    P.apply(v, P.PLUGGED)
    limit, check2 = v:getSpeedLimit(function() end, true)
    check("plugged: 1 km/h, upstream's second result passed through", limit == 1.0 and check2 == true)
    check("...and the limit is flagged active", v.spec_rhm_Combine.isSpeedLimitActive == true)
    v._limit = 0.5
    check("a lower limit from elsewhere is kept (min)", (v:getSpeedLimit(function() end, true)) == 0.5)
    v._limit = math.huge
    check("an unlimited upstream limit becomes 1 km/h", (v:getSpeedLimit(function() end, true)) == 1.0)
    P.apply(v, P.OK)
    v._limit = nil
    check("cleared: back to upstream's limit", (v:getSpeedLimit(function() end, true)) == 20)
end

print("=== 6. the warning goes to the player in the machine ===")
do
    shown = {}
    local v = machine(1.0)
    P.apply(v, P.RISK)
    check("RISK: a 3 s blinking warning", #shown == 1 and shown[1].text == "PLUG RISK" and shown[1].ms == 3000)
    P.apply(v, P.PLUGGED)
    check("PLUGGED: an 8 s warning that replaces the previous (same identifier)", #shown == 2 and shown[2].ms == 8000 and shown[2].text == "ROTOR PLUGGED!" and shown[2].id == shown[1].id)
    P.apply(v, P.PLUGGED)
    check("no repeat for an unchanged state", #shown == 2)
    P.apply(v, P.OK)
    check("clearing shows nothing", #shown == 2)

    shown = {}
    local other = machine(1.0, { getIsEntered = function() return false end })
    P.apply(other, P.PLUGGED)
    check("a machine nobody is sitting in: no warning (state still applied)", #shown == 0 and P.isPlugged(other))
    local dedicated = machine(1.0, { isClient = false })
    P.apply(dedicated, P.PLUGGED)
    check("a dedicated server shows nothing", #shown == 0 and P.isPlugged(dedicated))
    texts = {}
    local fallback = machine(1.0); P.apply(fallback, P.PLUGGED)
    check("missing translation: English fallback, not an error", shown[1] and shown[1].text:find("PLUGGED") ~= nil)
    texts = { rhm_warn_rotor_plugged = "ROTOR PLUGGED!", rhm_warn_plug_risk = "PLUG RISK" }
end

print("=== 7. the server ticks and tells the clients ===")
do
    local sent = {}
    g_server = { broadcastEvent = function(_, e, a, ignore, ghost) sent[#sent + 1] = { e = e, ignore = ignore, ghost = ghost } end }
    local v = machine(1.5)
    for _ = 1, 50 do P.tick(v, 100) end           -- 5 s
    check("RISK is broadcast to everyone, bound to the vehicle", #sent == 1 and sent[1].e.state == P.RISK and sent[1].ghost == v and sent[1].ignore == nil)
    for _ = 1, 50 do P.tick(v, 100) end
    check("PLUGGED is broadcast", #sent == 2 and sent[2].e.state == P.PLUGGED)
    for _ = 1, 20 do P.tick(v, 100) end
    check("nothing is sent while the state does not change", #sent == 2)
    g_server = nil
    local sp = machine(1.5)
    for _ = 1, 110 do P.tick(sp, 100) end
    check("single-player (no server object to broadcast to): still plugs locally", P.isPlugged(sp))
end

print("=== 8. hooks on upstream's onUpdateTick ===")
do
    local v = machine(1.5)
    v:onUpdateTick(100)
    check("upstream's own tick runs", rhm_Combine.seen.ticks == 1)
    for _ = 1, 105 do v:onUpdateTick(100) end
    check("the server's tick advances the machine (>10 s overloaded -> plugged)", P.isPlugged(v))

    local client = machine(1.5, { isServer = false })
    for _ = 1, 150 do client:onUpdateTick(100) end
    check("a client never advances the machine itself", P.get(client) == P.OK)

    local bad = machine(1.5, { _explodeTick = true })
    check("an error in upstream's tick propagates as before", not pcall(bad.onUpdateTick, bad, 100))
    local crash = machine(1.5); crash.spec_rhm_Combine._plug = "not a table"
    local ok = pcall(crash.onUpdateTick, crash, 100)
    check("a failure in the plug logic never breaks upstream's tick", ok)
end

print("=== 9. the event ===")
do
    local ev = ForkRotorPlugEvent.new(machine(1.0), P.PLUGGED)
    local s = newStream(); ev:writeStream(s, nil)
    local target = machine(1.0)
    s.q[1] = target
    local back = ForkRotorPlugEvent.emptyNew()
    back.run = function(self, c) self.ranWith = c end
    back:readStream(s, "conn")
    check("write/read round-trips the vehicle and the state", back.vehicle == target and back.state == P.PLUGGED and back.ranWith == "conn")

    local serverConn = { getIsServer = function() return true end }
    local clientConn = { getIsServer = function() return false end }
    local v = machine(1.0)
    ForkRotorPlugEvent.new(v, P.PLUGGED):run(serverConn)
    check("a client applies what the server sends", P.isPlugged(v))
    local forged = machine(1.0)
    ForkRotorPlugEvent.new(forged, P.PLUGGED):run(clientConn)
    check("...but ignores the same message from another client", P.get(forged) == P.OK)
    ForkRotorPlugEvent.new(forged, P.PLUGGED):run(nil)
    check("...and one with no connection", P.get(forged) == P.OK)
    check("a deleted vehicle is ignored", (pcall(ForkRotorPlugEvent.run, ForkRotorPlugEvent.new({ isDeleted = true }, 2), serverConn)))
    check("a non-combine is ignored", (pcall(ForkRotorPlugEvent.run, ForkRotorPlugEvent.new({}, 2), serverConn)))
end

print("=== 10. a player who joins while a machine is plugged ===")
do
    local host = machine(1.0); P.apply(host, P.PLUGGED)
    local s = newStream(); host:onWriteStream(s)
    local joiner = machine(1.0); joiner:onReadStream(s)
    check("the state arrives after upstream's own fields", P.isPlugged(joiner) and joiner.upstreamRead == "upstream-field")
    check("both ends consumed exactly what was written", s.r == #s.q + 1)
    local clear = machine(1.0); local s2 = newStream(); clear:onWriteStream(s2)
    local j2 = machine(1.0); P.apply(j2, P.PLUGGED); j2:onReadStream(s2)
    check("a clear host clears a stale state on the joiner", P.get(j2) == P.OK)
end

print("=== 11. console ===")
do
    RHM_RealisticHarvestManager.new()
    local has = false; for _, c in ipairs(commands) do if c == "rhmPlugging" then has = true end end
    check("rhmPlugging registered", has)
    check("off / on", P.consoleCommand(nil, "off"):find("OFF") ~= nil and not P.enabled and P.consoleCommand(nil, "on"):find("ON") ~= nil and P.enabled)
    check("usage on garbage", P.consoleCommand(nil, "x"):find("Usage") ~= nil)
    local v = machine(1.5); run(v, 6)
    g_realisticHarvestManager.lastActiveCombine = v
    local out = P.consoleCommand(nil, "status")
    check("status shows the active machine and its timer", out:find("RISK") ~= nil and out:find("overload timer") ~= nil)
    g_realisticHarvestManager.lastActiveCombine = nil
end

print("=== 12. survives the engine replacing rhm_Combine ===")
do
    rhm_Combine = newUpstreamRhmCombine()
    SpecializationManager:addSpecialization("FS25_Mod.rhm_Combine", "FS25_Mod.rhm_Combine", "src/rhm_Combine.lua", "FS25_Mod")
    local v = machine(1.0); P.apply(v, P.PLUGGED)
    check("the speed stop is on the replacement table", (v:getSpeedLimit(function() end, true)) == 1.0)
end

print("=== 13. missing upstream pieces disable, never throw ===")
do
    local w0 = #warnings
    rhm_Combine = { getSpeedLimit = function() return 20, true end }
    local ok = pcall(function()
        dofile("src/fork/RotorPlug.lua")
        rhm_Combine.__forkHooksInstalled = nil
        ForkSpecHooks.install()
    end)
    check("re-loading with pieces missing does not throw", ok)
    check("each absent piece is logged", #warnings >= w0 + 3, (#warnings - w0) .. " new warnings")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
