-- Headless harness for src/fork/TrainingBridge.lua.
-- Loads the REAL training modules and the REAL bridge against stubs shaped like upstream's
-- classes, then verifies each hook does what the sandbox contract in the bridge header claims.
-- Run from the mod root:  lua tests/bridgetest.lua
--
-- What this CANNOT prove: that upstream's real methods have these names and signatures. That is
-- checked separately against the upstream tree (see the PORT notes); a rename shows up in the
-- game log as "[RHM-fork] TrainingBridge: X.y not found — hook skipped".

-- ---- FS25 global stubs ----
local warnings = {}
Logging = {
    warning = function(fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end,
    error = function() end, info = function() end,
}
g_currentMission = { time = 0, hud = { getIsVisible = function() return true end } }
local guiVisible = false
g_gui = { getIsGuiVisible = function() return guiVisible end }
Utils = { appendedFunction = function(old, new)
    return function(...) local r = old(...); new(...); return r end
end }
Overlay = { new = function() return { setPosition = function() end, setDimension = function() end,
    setColor = function() end, render = function() end, delete = function() end } end }
g_screenAspectRatio = 1.7777
RenderText = { ALIGN_LEFT = 0 }
setTextBold, setTextColor, setTextAlignment, renderText = function() end, function() end, function() end, function() end

local commands = {}
function addConsoleCommand(name) commands[#commands + 1] = name end

-- ---- stubs shaped like upstream (names verified against v1.6.4.0) ----
RHM_RealisticHarvestManager = {}
function RHM_RealisticHarvestManager.new(mission, dir, name)
    return setmetatable({ mission = mission, settings = {}, log = {} }, { __index = RHM_RealisticHarvestManager })
end
function RHM_RealisticHarvestManager:update(dt) self.log[#self.log + 1] = "update" end
function RHM_RealisticHarvestManager:draw() self.log[#self.log + 1] = "draw" end
function RHM_RealisticHarvestManager:mouseEvent() self.log[#self.log + 1] = "mouse"; return false end
function RHM_RealisticHarvestManager:delete() self.log[#self.log + 1] = "delete" end
function RHM_RealisticHarvestManager:getControlledVehicle() return self.vehicle end

RHMDraggableHUD = {}
function RHMDraggableHUD:draw() self.drew = (self.drew or 0) + 1 end

RHM_LoadCalculator = {}
function RHM_LoadCalculator:calculateTotalCropLoss(vehicle)
    self.origCalls = (self.origCalls or 0) + 1
    self.cropLoss, self.totalLoss, self.wearLoss, self.moistureLoss = 7, 7, 2, 1
    return 7
end

rhm_Combine = {}
function rhm_Combine:onRegisterActionEvents() self.baseRegistered = true end

-- ---- load the real fork layer ----
g_currentModDirectory = "./"
function source(path) dofile(path) end
dofile("src/fork/ForkLoader.lua")

local pass, fail = 0, 0
local function check(name, cond, detail)
    if cond then pass = pass + 1; print(string.format("  PASS  %-56s %s", name, detail or ""))
    else fail = fail + 1; print(string.format("  FAIL  %-56s %s", name, detail or "")) end
end

-- ---- spies on the real modules ----
local calls = {}
local function spy(tbl, key, tag)
    local orig = tbl[key]
    tbl[key] = function(...) calls[#calls + 1] = tag; return orig(...) end
end
spy(TrainingInput, "update", "input"); spy(SignalConditioner, "update", "cond"); spy(TelemetryProvider, "update", "telem")
local registered = {}
local origReg = TrainingInput.registerActionEvents
TrainingInput.registerActionEvents = function(veh, tbl) registered[#registered + 1] = { veh, tbl } end

-- ---- a fake corner post so we can observe lifecycle without rendering ----
local post = { drawn = 0, mouse = 0, deleted = 0 }
function post:draw() self.drawn = self.drawn + 1 end
function post:mouseEvent() self.mouse = self.mouse + 1; return self.claim end
function post:delete() self.deleted = self.deleted + 1 end
CornerPostHUD.new = function() return post end

print("=== 1. all hooks installed ===")
check("no 'hook skipped' warnings at load", #warnings == 0, #warnings > 0 and warnings[1] or "")

local client = { getIsClient = function() return true end }
local server = { getIsClient = function() return false end }

print("=== 2. constructor attaches training ===")
local mgr = RHM_RealisticHarvestManager.new(client, "./", "mod")
check("corner post created on a client", mgr.cornerPost == post)
local function has(n) for _, c in ipairs(commands) do if c == n then return true end end end
check("rhmTraining console command registered", has("rhmTraining"))
check("rhmPostScale + rhmTrainingDebug registered", has("rhmPostScale") and has("rhmTrainingDebug"))
check("layout editor commands registered", has("rhmPostList") and has("rhmPostSide"))
local smgr = RHM_RealisticHarvestManager.new(server, "./", "mod")
check("no corner post on a dedicated server", smgr.cornerPost == nil)

print("=== 3. loss physics sandbox ===")
local calc = setmetatable({}, { __index = RHM_LoadCalculator })
TrainingMode.setActive(false)
check("normal play: upstream loss passes through", calc:calculateTotalCropLoss({}) == 7 and calc.origCalls == 1)
TrainingMode.setActive(true)
local before = calc.origCalls
check("training: returns 0", calc:calculateTotalCropLoss({}) == 0)
check("training: upstream calculation NOT run", calc.origCalls == before)
check("training: every exposed loss field zeroed",
    calc.cropLoss == 0 and calc.totalLoss == 0 and calc.wearLoss == 0 and calc.moistureLoss == 0
    and calc.baseLoss == 0 and calc.slopeLoss == 0 and calc.totalWearLoss == 0)
TrainingMode.setActive(false)
check("leaving training restores upstream loss", calc:calculateTotalCropLoss({}) == 7)

print("=== 4. normal HUD is replaced, not doubled ===")
local hud = setmetatable({}, { __index = RHMDraggableHUD })
TrainingMode.setActive(false); hud:draw()
check("normal play: HUD draws", hud.drew == 1)
TrainingMode.setActive(true); hud:draw()
check("training: HUD suppressed", hud.drew == 1)

print("=== 5. update pipeline ===")
TrainingMode.setActive(false); calls = {}; mgr:update(16)
check("training off: pipeline does not run", #calls == 0)
TrainingMode.setActive(true); calls = {}; mgr.lastActiveCombine = nil; mgr:update(16)
check("training on: input -> conditioner -> telemetry, in order",
    calls[1] == "input" and calls[2] == "cond" and calls[3] == "telem" and #calls == 3)
check("upstream update still ran", mgr.log[#mgr.log] == "update")
local sOnly = RHM_RealisticHarvestManager.new(server, "./", "mod"); calls = {}; sOnly:update(16)
check("dedicated server: pipeline skipped", #calls == 0)

print("=== 6. draw ===")
mgr.vehicle = {}; post.drawn = 0; mgr.log = {}
TrainingMode.setActive(false); mgr:draw()
check("normal play: upstream draws, no corner post", mgr.log[1] == "draw" and post.drawn == 0)
TrainingMode.setActive(true); mgr:draw()
check("training: upstream draws THEN corner post", mgr.log[2] == "draw" and post.drawn == 1)
mgr.vehicle = nil; mgr:draw()
check("training, player on foot: no corner post", post.drawn == 1)
mgr.vehicle = {}; guiVisible = true; mgr:draw(); guiVisible = false
check("training, menu open: no corner post", post.drawn == 1)

print("=== 7. mouse ===")
post.mouse = 0; post.claim = true; mgr.log = {}
TrainingMode.setActive(true)
check("training: post claims click, upstream skipped", mgr:mouseEvent(0, 0, true, false, 1) == true and #mgr.log == 0)
post.claim = false
mgr:mouseEvent(0, 0, true, false, 1)
check("training: unclaimed click falls through to upstream", mgr.log[1] == "mouse")
TrainingMode.setActive(false); post.mouse = 0; mgr.log = {}
mgr:mouseEvent(0, 0, true, false, 1)
check("normal play: post never sees the mouse", post.mouse == 0 and mgr.log[1] == "mouse")

print("=== 8. delete ===")
mgr:delete()
check("corner post deleted and cleared", post.deleted == 1 and mgr.cornerPost == nil)
check("upstream delete still ran", mgr.log[#mgr.log] == "delete")

print("=== 9. instructor key registration ===")
local spec = { isRhmCombine = true, actionEvents = {} }
local veh = setmetatable({ isClient = true, spec_rhm_Combine = spec }, { __index = rhm_Combine })
registered = {}
rhm_Combine.onRegisterActionEvents(veh, true, true)
check("upstream registration still ran", veh.baseRegistered == true)
check("training keys registered into upstream's actionEvents table",
    #registered == 1 and registered[1][1] == veh and registered[1][2] == spec.actionEvents)
registered = {}
veh.spec_rhm_Combine = { isRhmCombine = false, actionEvents = {} }
rhm_Combine.onRegisterActionEvents(veh, true, true)
check("non-RHM vehicle: nothing registered", #registered == 0)
veh.spec_rhm_Combine = spec; veh.isClient = false
rhm_Combine.onRegisterActionEvents(veh, true, true)
check("dedicated server: nothing registered", #registered == 0)
veh.isClient = true
rhm_Combine.onRegisterActionEvents(veh, false, false)
check("not entered / not active: nothing registered", #registered == 0)

print("=== 10. a failing training hook cannot take down the base mod ===")
TrainingMode.setActive(true)
local origT = TelemetryProvider.update
TelemetryProvider.update = function() error("boom") end
local m2 = RHM_RealisticHarvestManager.new(client, "./", "mod")
local ok = pcall(function() m2:update(16); m2:update(16) end)
check("update survives a throwing telemetry provider", ok)
TelemetryProvider.update = origT
TrainingMode.setActive(false)

print(string.format("\n=== FINAL: %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
