-- Headless harness for src/fork/WorkWidth.lua.
-- Loads the REAL module and the REAL SpecHooks installer against stubs shaped like upstream's
-- rhm_Combine, the calibration terminal and the engine's event/stream/XML machinery.
-- Run from the mod root:  lua tests/workwidthtest.lua

local warnings = {}
Logging = { warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
            error = function() end, info = function() end }
g_currentModName = "FS25_RealisticHarvesting"
Utils = { appendedFunction = function(old, new) return function(...) local r = old(...); new(...); return r end end }
SpecializationManager = { addSpecialization = function() return true end }

-- ---- engine machinery stubs ----
Class = function(cls, base)
    if base then setmetatable(cls, { __index = base }) end
    return { __index = cls }
end
Event = { new = function(mt) return setmetatable({}, mt) end }
InitEventClass = function() end
XMLValueType = { FLOAT = "FLOAT" }

-- A byte-less "network": each stream is a FIFO of values; node objects travel by reference.
local function newStream() return { q = {}, r = 1 } end
local function put(s, v) s.q[#s.q + 1] = v end
local function take(s) local v = s.q[s.r]; s.r = s.r + 1; return v end
function streamWriteFloat32(s, v) put(s, v) end
function streamReadFloat32(s) return take(s) end
function streamWriteBool(s, v) put(s, v) end
function streamReadBool(s) return take(s) end
NetworkUtil = {
    writeNodeObject = function(s, o) put(s, o) end,
    readNodeObject = function(s) return take(s) end,
}

-- text/drawing stubs
RenderText = { ALIGN_LEFT = 0, ALIGN_RIGHT = 2 }
local drawn = {}
function setTextBold() end; function setTextAlignment() end; function setTextColor() end
function renderText(x, y, size, text) drawn[#drawn + 1] = text end

local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end

-- ---- upstream-shaped stubs ----
RHM_UnitConverter = { getActiveSystem = function() return RHM_UnitConverter.system or 1 end }
RHM_Api = {}
RHM_RealisticHarvestManager = { new = function() return {} end }
g_realisticHarvestManager = {}

local function newUpstreamRhmCombine()
    local c = {}
    c.seen = {}
    function c:onUpdateTick(dt)
        local spec = self.spec_rhm_Combine
        c.seen.rawAreaAtUpdate = spec and spec.lastRawArea
        c.seen.updates = (c.seen.updates or 0) + 1
    end
    function c.registerXMLPaths(schema, basePath) schema:register("ORIG", basePath .. ".other", "x", 0) end
    function c:saveToXMLFile(xmlFile, key) xmlFile:setValue(key .. ".combineMemory.current#mode", "AUTO") end
    function c:loadFromSavegame(savegame) self.loaded = true; return true end
    function c:onWriteStream(streamId) streamWriteBool(streamId, true) end        -- upstream's own field
    function c:onReadStream(streamId) self.upstreamRead = streamReadBool(streamId) end
    return c
end
rhm_Combine = newUpstreamRhmCombine()

-- The terminal: a drawing surface plus the button list draw() rebuilds each frame.
RHMCombineCalibrationGUI = {}
function RHMCombineCalibrationGUI:draw()
    self.buttons = {}
    self.drewTerminal = (self.drewTerminal or 0) + 1
end
function RHMCombineCalibrationGUI:drawRect(x, y, w, h) self.rects = (self.rects or 0) + 1; self.lastRect = { x, y, w, h } end
function RHMCombineCalibrationGUI:drawBorder() end
function RHMCombineCalibrationGUI:drawButton(x, y, w, h, text, cb)
    self.buttons[#self.buttons + 1] = { x = x, y = y, w = w, h = h, text = text, callback = cb }
end
function RHMCombineCalibrationGUI:_resetTextState() end

dofile("src/fork/SpecHooks.lua")
dofile("src/fork/WorkWidth.lua")
ForkSpecHooks.install()

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-66s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-66s %s", name, detail or "")) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-9) end
local W = WorkWidth

local function combine(extra)
    local v = setmetatable({
        isServer = true,
        lastMovedDistance = 0,
        spec_rhm_Combine = { combineMemory = {}, lastRawArea = 0, lastLiters = 0, lastMultiplier = 1 },
        getOwnerFarmId = function() return 1 end,
    }, { __index = rhm_Combine })
    for k, val in pairs(extra or {}) do v[k] = val end
    return v
end

print("=== 1. loads cleanly ===")
check("no warnings at load", #warnings == 0, warnings[1] or "")

print("=== 2. the setting ===")
check("nil / 0 / negative -> Auto (nil)", W.normalize(nil) == nil and W.normalize(0) == nil and W.normalize(-3) == nil)
check("below the minimum -> Auto", W.normalize(0.2) == nil)
check("above the cap clamps to 50 m", W.normalize(80) == 50.0)
check("rounded to 0.1 mm (so foot steps do not drift)", W.normalize(14.60494) == 14.6049)
check("text numbers accepted", W.normalize("12.5") == 12.5)
local v = combine()
check("a fresh machine is Auto", W.get(v) == nil)
check("apply sets it", W.apply(v, 14.6) == true and W.get(v) == 14.6 and v.spec_rhm_Combine.combineMemory.swathWidth == 14.6)
check("stored where the fork kept it (combineMemory.swathWidth)", v.spec_rhm_Combine.combineMemory.swathWidth == 14.6)
W.apply(v, 0)
check("apply(0) returns to Auto", W.get(v) == nil)
check("a vehicle with no combine memory is refused", W.apply({}, 10) == false and W.get({}) == nil)

print("=== 3. formatting and steps ===")
RHM_UnitConverter.system = 1
check("metric", W.format(14.6) == "14.6 m" and W.format(nil) == "Auto" and W.format(0) == "Auto")
RHM_UnitConverter.system = 2
check("imperial shows whole feet", W.format(14.6304) == "48 ft")
check("imperial step is one foot", near(W.stepSize(), 0.3048))
RHM_UnitConverter.system = 1
check("metric step is half a metre", W.stepSize() == 0.5)
do
    local m = combine()
    W.step(m, 1); check("+ from Auto -> one step", W.get(m) == 0.5)
    W.step(m, 1); W.step(m, 1); check("+ accumulates", near(W.get(m), 1.5))
    W.step(m, -1); check("- subtracts a step", near(W.get(m), 1.0))
    W.step(m, -1); W.step(m, -1); check("- at the first step returns to Auto", W.get(m) == nil)
    W.step(m, -1); check("- from Auto stays Auto", W.get(m) == nil)
    W.apply(m, 49.8); W.step(m, 1); W.step(m, 1)
    check("+ stops at the 50 m cap", W.get(m) == 50.0)
    RHM_UnitConverter.system = 2
    local f = combine(); W.step(f, 1); W.step(f, 1)
    check("imperial: two presses = two feet", near(W.get(f), 0.6096, 1e-6))
    local big = combine(); for _ = 1, 48 do W.step(big, 1) end
    check("imperial: 48 presses = 48 ft, with no drift", near(W.get(big), 48 * 0.3048, 1e-3) and W.format(W.get(big)) == "48 ft")
    RHM_UnitConverter.system = 1
end

print("=== 4. area rule: distance x width, applied just before upstream reads the area ===")
do
    local m = combine({ lastMovedDistance = 2.0 })
    m.spec_rhm_Combine.lastRawArea = 0.7; m.spec_rhm_Combine.lastArea = 0.7; m.spec_rhm_Combine.lastMultiplier = 1.25
    W.apply(m, 10)
    m:onUpdateTick(16)
    check("upstream's onUpdateTick saw distance x width (2 m x 10 m = 20 m2)", near(rhm_Combine.seen.rawAreaAtUpdate, 20.0))
    check("lastArea follows with upstream's multiplier", near(m.spec_rhm_Combine.lastArea, 25.0))
    check("upstream's own onUpdateTick still ran", rhm_Combine.seen.updates >= 1)

    local a = combine({ lastMovedDistance = 2.0 }); a.spec_rhm_Combine.lastRawArea = 0.7
    a:onUpdateTick(16)
    check("Auto: the engine's pixel area is left alone", near(rhm_Combine.seen.rawAreaAtUpdate, 0.7))

    local idle = combine({ lastMovedDistance = 2.0 }); W.apply(idle, 10)
    idle:onUpdateTick(16)
    check("nothing being harvested this frame: no area invented", (rhm_Combine.seen.rawAreaAtUpdate or 0) == 0)

    local grain = combine({ lastMovedDistance = 2.0 }); W.apply(grain, 10); grain.spec_rhm_Combine.lastLiters = 5
    grain:onUpdateTick(16)
    check("grain arriving with no pixel area still gets distance x width", near(rhm_Combine.seen.rawAreaAtUpdate, 20.0))

    local still = combine({ lastMovedDistance = 0 }); W.apply(still, 10); still.spec_rhm_Combine.lastRawArea = 0.7
    still:onUpdateTick(16)
    check("not moving: keeps the pixel area rather than zeroing it", near(rhm_Combine.seen.rawAreaAtUpdate, 0.7))

    local client = combine({ lastMovedDistance = 2.0, isServer = false }); W.apply(client, 10)
    client.spec_rhm_Combine.lastRawArea = 0.7
    client:onUpdateTick(16)
    check("clients do not touch the area (server-side quantity)", near(rhm_Combine.seen.rawAreaAtUpdate, 0.7))

    local bad = combine({ lastMovedDistance = {} }); W.apply(bad, 10); bad.spec_rhm_Combine.lastRawArea = 0.7
    local before = rhm_Combine.seen.updates
    local ok = pcall(bad.onUpdateTick, bad, 16)
    check("a failure in the correction never blocks upstream's update", ok and rhm_Combine.seen.updates == before + 1)
end

print("=== 5. saved with the game ===")
do
    local schema = { paths = {} }
    function schema:register(t, path, desc, def) self.paths[#self.paths + 1] = { t, path } end
    rhm_Combine.registerXMLPaths(schema, "vehicles.vehicle(?).FS25_RealisticHarvesting.rhm_Combine")
    local found = false
    for _, p in ipairs(schema.paths) do
        if p[2] == "vehicles.vehicle(?).FS25_RealisticHarvesting.rhm_Combine.combineMemory.current#workWidth" and p[1] == "FLOAT" then found = true end
    end
    check("the schema path is registered beside upstream's own", found)
    check("...and upstream's registrations still happen", schema.paths[1][1] == "ORIG")

    local xml = { v = {} }
    function xml:setValue(path, val) self.v[path] = val end
    function xml:hasProperty(path) return self.v[path] ~= nil end
    function xml:getValue(path) return self.v[path] end
    local key = "vehicles.vehicle(0).FS25_RealisticHarvesting.rhm_Combine"

    local m = combine(); W.apply(m, 14.6)
    m:saveToXMLFile(xml, key)
    check("saved under the machine-settings node", xml.v[key .. ".combineMemory.current#workWidth"] == 14.6)
    check("upstream's own save still ran", xml.v[key .. ".combineMemory.current#mode"] == "AUTO")

    local auto = combine(); local xml2 = { v = {} }; xml2.setValue = xml.setValue
    auto:saveToXMLFile(xml2, key)
    check("Auto writes nothing", xml2.v[key .. ".combineMemory.current#workWidth"] == nil)

    local loaded = combine()
    xml.v["vehicles.vehicle(0).FS25_RealisticHarvesting.rhm_Combine.combineMemory.current#workWidth"] = 14.6
    local ret = loaded:loadFromSavegame({ xmlFile = xml, key = "vehicles.vehicle(0)" })
    check("loaded from the same node", W.get(loaded) == 14.6 and loaded.loaded == true and ret == true)
    local reset = combine()
    reset:loadFromSavegame({ xmlFile = xml, key = "vehicles.vehicle(0)", resetVehicles = true })
    check("a vehicle reset does not restore it", W.get(reset) == nil)
    local none = combine()
    none:loadFromSavegame({ xmlFile = { hasProperty = function() return false end }, key = "vehicles.vehicle(1)" })
    check("a save without the value leaves it Auto", W.get(none) == nil)
    check("no savegame at all is fine", (pcall(combine().loadFromSavegame, combine(), nil)))
end

print("=== 6. a joining player gets the current width ===")
do
    local m = combine(); W.apply(m, 12.5)
    local s = newStream(); m:onWriteStream(s)
    local joiner = combine(); joiner:onReadStream(s)
    check("width arrives after upstream's own fields", W.get(joiner) == 12.5 and joiner.upstreamRead == true)
    check("both ends consumed exactly what was written", s.r == #s.q + 1)

    local a = combine(); local s2 = newStream(); a:onWriteStream(s2)
    local j2 = combine(); W.apply(j2, 9); j2:onReadStream(s2)
    check("Auto on the host clears a stale value on the joiner", W.get(j2) == nil and s2.r == #s2.q + 1)
end

print("=== 7. changes travel as an event ===")
do
    local ev = ForkWorkWidthEvent.new(combine(), 14.6)
    local s = newStream(); ev:writeStream(s, nil)
    local back = ForkWorkWidthEvent.emptyNew()
    local target = combine()
    s.q[1] = target
    back.run = function(self, c) self.ran = c end
    back:readStream(s, "conn")
    check("write/read round-trips the vehicle and the width", back.vehicle == target and back.metres == 14.6 and back.ran == "conn")

    -- server receiving from a client
    local broadcast = {}
    g_server = { broadcastEvent = function(_, e, a, ignore, ghost) broadcast[#broadcast + 1] = { e = e, ignore = ignore, ghost = ghost } end }
    local clientConn = { getIsServer = function() return false end }
    local owner = combine({ getOwnerFarmId = function() return 7 end })
    g_currentMission = {
        userManager = { getUserByConnection = function() return { getUniqueUserId = function() return "u1" end } end },
    }
    g_farmManager = { getFarmForUniqueUserId = function() return { farmId = 7 } end }
    local e1 = ForkWorkWidthEvent.new(owner, 11)
    e1:run(clientConn)
    check("owner's client: applied on the server", W.get(owner) == 11)
    check("...and broadcast to everyone but the sender", #broadcast == 1 and broadcast[1].ignore == clientConn and broadcast[1].ghost == owner and broadcast[1].e.metres == 11)

    g_farmManager = { getFarmForUniqueUserId = function() return { farmId = 2 } end }
    local other = combine({ getOwnerFarmId = function() return 7 end })
    ForkWorkWidthEvent.new(other, 11):run(clientConn)
    check("another farm's client is refused", W.get(other) == nil and #broadcast == 1)

    g_currentMission.userManager.getUserByConnection = function() return nil end
    ForkWorkWidthEvent.new(other, 11):run(clientConn)
    check("an unknown connection is refused", W.get(other) == nil)

    -- client receiving the server's broadcast
    local serverConn = { getIsServer = function() return true end }
    local onClient = combine()
    ForkWorkWidthEvent.new(onClient, 8):run(serverConn)
    check("client: applies what the server sends", W.get(onClient) == 8 and #broadcast == 1)
    check("a deleted vehicle is ignored", (pcall(ForkWorkWidthEvent.run, ForkWorkWidthEvent.new({ isDeleted = true }, 5), serverConn)))
    check("a non-combine vehicle is ignored", (pcall(ForkWorkWidthEvent.run, ForkWorkWidthEvent.new({}, 5), serverConn)))
    g_server = nil
end

print("=== 8. request: who sends what ===")
do
    local sent, bcast = {}, {}
    g_server = { broadcastEvent = function(_, e) bcast[#bcast + 1] = e end }
    local m = combine()
    check("single-player / host: applies and broadcasts", W.request(m, 10) and W.get(m) == 10 and #bcast == 1)
    g_server = nil
    g_client = { getServerConnection = function() return { sendEvent = function(_, e) sent[#sent + 1] = e end } end }
    local c = combine()
    W.request(c, 12)
    check("client: applies at once and asks the server", W.get(c) == 12 and #sent == 1 and sent[1].metres == 12)
    W.request(c, 0)
    check("Auto is sent as 0", W.get(c) == nil and sent[2].metres == 0)
    g_client = nil
    check("no network at all: still applies locally", W.request(combine(), 5) == true)
    check("not a combine: refused", W.request({}, 5) == false)
end

print("=== 9. the row under the calibration terminal ===")
do
    local m = combine(); W.apply(m, 14.6)
    local gui = setmetatable({
        isOpen = true, activeVehicle = m,
        ui = { x = 0.60, y = 0.35, w = 0.392, h = 0.55, margin = 0.009, fontSize = 0.0125, buttonW = 0.017, buttonH = 0.017, colors = {} },
    }, { __index = RHMCombineCalibrationGUI })
    drawn = {}
    gui:draw()
    check("upstream's terminal still draws", gui.drewTerminal == 1)
    check("two buttons were added to the terminal's own list", #gui.buttons == 2 and gui.buttons[1].text == "-" and gui.buttons[2].text == "+")
    check("the row shows the label and the current width", (function() local l, v = false, false
        for _, t in ipairs(drawn) do if t == "Working Width" then l = true elseif t == "14.6 m" then v = true end end return l and v end)())
    local r = gui.lastRect
    check("sits directly under the terminal", r[2] < gui.ui.y and r[2] + r[4] <= gui.ui.y and r[1] == gui.ui.x and r[3] == gui.ui.w)
    gui.buttons[2].callback()
    check("+ raises the width by a step", near(W.get(m), 15.1, 1e-6))
    gui.buttons[1].callback(); gui.buttons[1].callback()
    check("- lowers it", near(W.get(m), 14.1, 1e-6))

    gui.ui.y = 0.01
    gui:draw()
    check("no room below: sits above the terminal", gui.lastRect[2] > gui.ui.y + gui.ui.h - 1e-9)

    local closed = setmetatable({ isOpen = false, activeVehicle = m, ui = gui.ui }, { __index = RHMCombineCalibrationGUI })
    closed:draw()
    check("terminal closed: no row, no buttons", (closed.buttons == nil or #closed.buttons == 0) and closed.rects == nil)

    local noVeh = setmetatable({ isOpen = true, activeVehicle = {}, ui = gui.ui }, { __index = RHMCombineCalibrationGUI })
    noVeh:draw()
    check("no combine memory: no row", #noVeh.buttons == 0)

    local boomGui = setmetatable({ isOpen = true, activeVehicle = m, ui = {} }, { __index = RHMCombineCalibrationGUI })
    check("a drawing failure never breaks the terminal", pcall(boomGui.draw, boomGui) and boomGui.drewTerminal == 1)
end

print("=== 10. console + API ===")
do
    check("parse metres", W.parse("14.6") == 14.6 and W.parse("14.6m") == 14.6)
    check("parse feet", near(W.parse("48ft"), 14.6304, 1e-4) and near(W.parse("48 ft"), 14.6304, 1e-4))
    check("parse auto / off / 0", W.parse("auto") == 0 and W.parse("OFF") == 0 and W.parse("0") == 0)
    check("parse rejects nonsense", W.parse("wide") == nil and W.parse("5 parsecs") == nil and W.parse(nil) == nil)

    g_realisticHarvestManager.lastActiveCombine = nil
    check("no combine active -> says so", W.consoleCommand(nil, "10"):find("climb into") ~= nil)
    local m = combine(); g_realisticHarvestManager.lastActiveCombine = m
    check("set by metres", W.consoleCommand(nil, "14.6"):find("14.6 m", 1, true) ~= nil and W.get(m) == 14.6)
    check("status", W.consoleCommand(nil, ""):find("14.6 m", 1, true) ~= nil and W.consoleCommand(nil, "status"):find("14.6", 1, true) ~= nil)
    W.consoleCommand(nil, "auto")
    check("auto clears it", W.get(m) == nil)
    check("usage on garbage", W.consoleCommand(nil, "wide"):find("Usage") ~= nil)
    RHM_RealisticHarvestManager.new()
    local has = false; for _, c in ipairs(commands) do if c == "rhmWorkWidth" then has = true end end
    check("rhmWorkWidth registered with the manager", has)
    W.apply(m, 9)
    check("RHM_Api.getSwathWidth returns the fork's value (0 when Auto)", RHM_Api.getSwathWidth(m) == 9 and RHM_Api.getSwathWidth(combine()) == 0)
    g_realisticHarvestManager.lastActiveCombine = nil
end

print("=== 11. hooks survive the engine replacing rhm_Combine ===")
do
    rhm_Combine = newUpstreamRhmCombine()
    SpecializationManager:addSpecialization("FS25_Mod.rhm_Combine", "FS25_Mod.rhm_Combine", "src/rhm_Combine.lua", "FS25_Mod")
    local m = combine({ lastMovedDistance = 2.0 }); W.apply(m, 10); m.spec_rhm_Combine.lastRawArea = 0.7
    m:onUpdateTick(16)
    check("the area rule works on the replacement table", near(rhm_Combine.seen.rawAreaAtUpdate, 20.0))
end

print("=== 12. missing upstream pieces disable, never throw ===")
do
    local w0 = #warnings
    local saved = RHMCombineCalibrationGUI
    RHMCombineCalibrationGUI = nil
    rhm_Combine = { onUpdateTick = function() end }          -- almost everything absent
    local ok = pcall(function()
        dofile("src/fork/WorkWidth.lua")
        rhm_Combine.__forkHooksInstalled = nil
        ForkSpecHooks.install()
    end)
    RHMCombineCalibrationGUI = saved
    check("re-loading with pieces missing does not throw", ok)
    check("each absent piece is logged", #warnings >= w0 + 4, (#warnings - w0) .. " new warnings")
end

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
