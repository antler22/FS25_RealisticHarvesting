-- Verifies the training-mode key claim takes exactly what it must and nothing else.
--
-- This is the test that did not exist when the bottom row silently failed to bind. A refused
-- action registration produces no event and no message, so the only observable symptom is a
-- key that does nothing — and the same symptom would be produced by a broken callback, a
-- wrong channel name, or a suppressed HUD. Testing the claim directly separates those.
--
-- Collision in FS25 is an EXACT match of the whole key list (Binding:hasEventCollision uses
-- table.equalLists), so the claim must mirror that: displace an identical binding, leave a
-- longer or shorter one alone. Over-claiming would silently steal a key the engine would
-- never have contested.

g_currentMission = { time = 0 }
Logging = { warning = function() end, error = function() end, info = function() end }
InputAction = setmetatable({}, { __index = function(_, k) return k end })
GS_PRIO_LOW = 1
function addConsoleCommand() end

-- Minimal fakes standing in for the engine's input registry.
local function makeAction(name, inputStrings, hasEvent)
    local bindings = {}
    for _, s in ipairs(inputStrings) do
        bindings[#bindings + 1] = { isActive = true, inputString = s }
    end
    return {
        name = name,
        getBindings = function() return bindings end,
        _hasEvent = hasEvent,
    }
end

local removed = {}
local function makeInputBinding(actions)
    local nameActions, actionEvents = {}, {}
    for _, a in ipairs(actions) do
        nameActions[a.name] = a
        if a._hasEvent then actionEvents[a] = { { id = a.name } } end
    end
    return {
        nameActions = nameActions,
        actionEvents = actionEvents,
        removeActionEventsByActionName = function(self, n)
            removed[#removed + 1] = n
            for act, _ in pairs(self.actionEvents) do
                if act.name == n then self.actionEvents[act] = nil end
            end
        end,
    }
end

dofile("src/training/TrainingMode.lua")
dofile("src/training/SignalConditioner.lua")
dofile("src/training/TrainingInput.lua")

local pass, fail = 0, 0
local function check(n, c, d)
    if c then pass = pass + 1; print("  PASS  " .. n .. "  " .. (d or ""))
    else fail = fail + 1; print("  FAIL  " .. n .. "  " .. (d or "")) end
end

local function contains(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

print("=== Key claim takes exactly the colliding events ===")
do
    removed = {}
    g_inputBinding = makeInputBinding({
        -- ours: the six adjust actions, on the bare numpad grid
        makeAction("RHM_TRAIN_SHOE_UP",   { "KEY_KP_7" }, false),
        makeAction("RHM_TRAIN_SHOE_DOWN", { "KEY_KP_1" }, false),
        makeAction("RHM_TRAIN_SEP_UP",    { "KEY_KP_8" }, false),
        makeAction("RHM_TRAIN_SEP_DOWN",  { "KEY_KP_2" }, false),
        makeAction("RHM_TRAIN_TAIL_UP",   { "KEY_KP_9" }, false),
        makeAction("RHM_TRAIN_TAIL_DOWN", { "KEY_KP_3" }, false),

        -- an always-active vehicle action sitting on one of our keys: must be taken
        makeAction("TOGGLE_TURNLIGHT_LEFT", { "KEY_KP_1" }, true),
        -- same key, but dormant: cannot block us, so taking it would be vandalism
        makeAction("REINKE_PIVOT_SWEEP_MIN_DN_V2", { "KEY_KP_1" }, false),
        -- a LONGER key list on the same physical key: the engine would not collide with it
        makeAction("SOME_MODIFIED_ACTION", { "KEY_lctrl KEY_KP_2" }, true),
        -- unrelated action holding an event: untouched
        makeAction("TOGGLE_LIGHTS", { "KEY_f" }, true),
    })

    local names = {}
    for _, m in ipairs(TrainingInput.KEY_CHANNELS) do
        names[#names + 1] = m.upAction
        names[#names + 1] = m.downAction
    end
    TrainingInput.claimKeys(names)

    check("takes the active action sitting on our key",
        contains(removed, "TOGGLE_TURNLIGHT_LEFT"), table.concat(removed, ", "))
    check("leaves a dormant action on the same key alone",
        not contains(removed, "REINKE_PIVOT_SWEEP_MIN_DN_V2"))
    check("leaves a modifier variant of our key alone",
        not contains(removed, "SOME_MODIFIED_ACTION"),
        "exact-list match only, as Binding:hasEventCollision does")
    check("leaves unrelated actions alone", not contains(removed, "TOGGLE_LIGHTS"))
    check("never takes one of our own actions", not contains(removed, "RHM_TRAIN_SHOE_DOWN"))
    check("takes exactly one binding here", #removed == 1, "#removed = " .. #removed)
    check("records what it took", #TrainingInput._claimed == 1,
        table.concat(TrainingInput._claimed, ", "))
end

print("\n=== Claim is a no-op when nothing collides ===")
do
    removed = {}
    g_inputBinding = makeInputBinding({
        makeAction("RHM_TRAIN_SHOE_UP", { "KEY_KP_7" }, false),
        makeAction("TOGGLE_LIGHTS",     { "KEY_f" },    true),
    })
    TrainingInput.claimKeys({ "RHM_TRAIN_SHOE_UP" })
    check("takes nothing", #removed == 0, "#removed = " .. #removed)
end

print("\n=== Claim survives a missing action ===")
do
    removed = {}
    g_inputBinding = makeInputBinding({ makeAction("TOGGLE_LIGHTS", { "KEY_f" }, true) })
    local ok = pcall(TrainingInput.claimKeys, { "RHM_TRAIN_SHOE_UP" })
    check("an unregistered action name does not throw", ok)
    check("and takes nothing", #removed == 0)
end

-- The re-registration edge is what makes the keys change hands at the moment training mode is
-- switched rather than at the next vehicle enter. It watches the STATE, not the toggle key,
-- because the rhmTraining console command flips the same state by another route.
print("\n=== Re-registration fires once per state change, by any route ===")
do
    local requests = 0
    g_realisticHarvestManager = {
        getControlledVehicle = function()
            return { requestActionEventUpdate = function() requests = requests + 1 end }
        end,
    }
    g_inputBinding = makeInputBinding({})
    TrainingInput._lastActive = false
    TrainingMode.isActive = false

    TrainingInput.update(16)
    check("steady state does not re-register", requests == 0, "requests = " .. requests)

    TrainingMode.isActive = true                    -- as the console command would
    TrainingInput.update(16)
    check("switching on re-registers once", requests == 1, "requests = " .. requests)

    TrainingInput.update(16)
    TrainingInput.update(16)
    check("staying on does not re-register again", requests == 1, "requests = " .. requests)

    TrainingMode.isActive = false
    TrainingInput.update(16)
    check("switching off re-registers once", requests == 2, "requests = " .. requests)
end

-- On Windows, holding Shift with the numpad temporarily inverts Num Lock, so Shift+NumPad7
-- arrives as Home and a KEY_KP_7 binding can never match. This cost a full round of testing;
-- encode it so nobody reaches for that modifier again to dodge a conflict.
print("\n=== modDesc bindings avoid the Shift+numpad trap ===")
do
    local src = io.open("modDesc.xml"):read("*a")
    local bad, checked = {}, 0
    for action, input in src:gmatch('<actionBinding action="(RHM_[%w_]+)">%s*<binding[^>]-input="([^"]+)"') do
        checked = checked + 1
        if input:match("KEY_KP_") and input:match("shift") then
            bad[#bad + 1] = action .. " = " .. input
        end
    end
    check("every RHM binding was read", checked >= 8, "checked = " .. checked)
    check("no RHM binding pairs Shift with a numpad key", #bad == 0, table.concat(bad, "; "))
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
os.exit(fail == 0 and 0 or 1)
