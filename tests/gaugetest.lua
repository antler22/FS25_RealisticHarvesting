-- Verifies the gauge colour scales land their boundaries on the stated real-world values.
--
-- loadstring was removed in Lua 5.2. The game runs 5.1, but the interpreter on hand for
-- running these tests may be either, so alias it rather than pin the test to one runtime.
loadstring = loadstring or load
g_currentMission={time=0}; Logging={warning=function()end,error=function()end}
g_screenAspectRatio=1.7777
function addConsoleCommand() end
Overlay={new=function() return {setPosition=function()end,setDimension=function()end,
  setColor=function()end,render=function()end,delete=function()end} end}
dofile("src/training/TrainingMode.lua")
dofile("src/training/SignalConditioner.lua")
dofile("src/hud/CornerPostHUD.lua")

local src = io.open("src/hud/CornerPostHUD.lua"):read("*a")
local specSrc = src:match("(local GAUGE_SPECS = %b{})")
assert(specSrc, "could not extract GAUGE_SPECS")
local S = assert(loadstring(specSrc .. "\nreturn GAUGE_SPECS"))()

local pass, fail = 0, 0
local function check(n,c,d) if c then pass=pass+1;print("  PASS  "..n.."  "..(d or ""))
  else fail=fail+1;print("  FAIL  "..n.."  "..(d or "")) end end

-- which colour does a value fall in?
local function zoneAt(spec, v)
    for _, z in ipairs(spec.zones) do
        if v <= z.upto then return z.color end
    end
    return spec.zones[#spec.zones].color
end

print("=== Engine load: 100% is green/amber boundary, 120% enters red ===")
local L = S.load
check("99% is green",   zoneAt(L, 99)  == "segGreen", zoneAt(L, 99))
check("100% is green (boundary belongs to green)", zoneAt(L,100) == "segGreen", zoneAt(L,100))
check("101% is amber",  zoneAt(L,101)  == "segAmber", zoneAt(L,101))
check("119% is amber",  zoneAt(L,119)  == "segAmber", zoneAt(L,119))
check("120% is amber at the boundary", zoneAt(L,120) == "segAmber", zoneAt(L,120))
check("121% is red",    zoneAt(L,121)  == "segRed",   zoneAt(L,121))
check("scale has headroom above red", L.max > 120, "max="..L.max)

print("\n=== Fuel / DEF: empty is the bad end, so red sits at the BOTTOM ===")
local F = S.fuel
check("5% is red",     zoneAt(F,5)   == "segRed",   zoneAt(F,5))
check("20% is amber",  zoneAt(F,20)  == "segAmber", zoneAt(F,20))
check("80% is green",  zoneAt(F,80)  == "segGreen", zoneAt(F,80))
check("DEF shares the fuel scale", S.def.max == F.max and #S.def.zones == #F.zones)

print("\n=== Coolant: normal running green, overheat red ===")
local C = S.coolant
check("90C is green",  zoneAt(C,90)  == "segGreen", zoneAt(C,90))
check("105C is amber", zoneAt(C,105) == "segAmber", zoneAt(C,105))
check("115C is red",   zoneAt(C,115) == "segRed",   zoneAt(C,115))
check("scale matches FS25 motorTemperature ceiling of 120C", C.max == 120, "max="..C.max)

print("\n=== Every zone list is ordered and covers the whole scale ===")
for name, spec in pairs(S) do
    local prev, ordered = 0, true
    for _, z in ipairs(spec.zones) do
        if z.upto <= prev then ordered = false end
        prev = z.upto
    end
    check(name..": zones ascend and reach full scale",
        ordered and prev == spec.max, string.format("last=%s max=%s", prev, spec.max))
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
os.exit(fail==0 and 0 or 1)
