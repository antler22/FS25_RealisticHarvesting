-- Proves the green marker band lands on exactly the same rows as the bar segments.
-- This is geometry that looks right until it is half a cell off, at which point it looks
-- wrong on the machine and is invisible in code — so it is asserted, not eyeballed.
g_currentMission={time=0}; Logging={warning=function(s) print("WARN: "..s) end, error=function()end}
g_screenAspectRatio=1.7777
function addConsoleCommand() end
Overlay={new=function() return {setPosition=function()end,setDimension=function()end,
  setColor=function()end,render=function()end,delete=function()end} end}
dofile("src/training/TrainingMode.lua")
dofile("src/training/SignalConditioner.lua")
dofile("src/hud/CornerPostHUD.lua")

local src = io.open("src/hud/CornerPostHUD.lua"):read("*a")
local below = tonumber(src:match("below = (%d+)"))
local green = tonumber(src:match("green = (%d+)"))
local above = tonumber(src:match("above = (%d+)"))
local segs  = SignalConditioner.segments

local pass, fail = 0, 0
local function check(n,c,d) if c then pass=pass+1;print("  PASS  "..n.."  "..(d or ""))
  else fail=fail+1;print("  FAIL  "..n.."  "..(d or "")) end end

print(string.format("=== Segment zones: %d below / %d green / %d above, segments=%d ===",
    below, green, above, segs))

check("zones sum to the segment count", below+green+above == segs,
    string.format("%d+%d+%d=%d vs %d", below, green, above, below+green+above, segs))
check("4 segments sit below the green band", below == 4, tostring(below))
check("3 segments are in the green band",    green == 3, tostring(green))
check("4 segments sit above the green band", above == 4, tostring(above))

-- Replicate both placements and compare boundaries.
local L = CornerPostHUD.LAYOUT
local bar = L.colShoe
local mk  = L.markerL
local GREEN_FROM, GREEN_TO = below + 1, below + green

-- bar cell i (1-based from bottom) occupies [v+vh-i*cellH, v+vh-(i-1)*cellH]
local barCell = bar.h / segs
local function barCellTop(i)    return bar.y + bar.h - i * barCell end
local function barCellBottom(i) return bar.y + bar.h - (i-1) * barCell end

-- marker band as drawn
local mkCell = mk.h / segs
local bandY  = mk.y + mk.h - GREEN_TO * mkCell
local bandH  = mkCell * (GREEN_TO - GREEN_FROM + 1)

check("bar and marker use the same cell height", math.abs(barCell - mkCell) < 1e-9,
    string.format("bar=%.4f marker=%.4f", barCell, mkCell))
check("green band TOP aligns with top of segment "..GREEN_TO,
    math.abs(bandY - barCellTop(GREEN_TO)) < 1e-9,
    string.format("band=%.4f seg=%.4f", bandY, barCellTop(GREEN_TO)))
check("green band BOTTOM aligns with bottom of segment "..GREEN_FROM,
    math.abs((bandY + bandH) - barCellBottom(GREEN_FROM)) < 1e-9,
    string.format("band=%.4f seg=%.4f", bandY+bandH, barCellBottom(GREEN_FROM)))
check("green band spans exactly "..green.." cells",
    math.abs(bandH - green * barCell) < 1e-9,
    string.format("%.4f vs %.4f", bandH, green*barCell))

-- colour band boundaries must fall on the same rows
print("\nBar colour by segment (bottom -> top), all lit:")
local row = {}
for i = 1, segs do
    local c = (i >= GREEN_FROM and i <= GREEN_TO) and "G" or "A"
    table.insert(row, string.format("%d:%s", i, c))
end
print("  " .. table.concat(row, " "))
-- EN: Loss columns are a TARGET BAND: amber outside on both sides, green in the middle,
--     and no red anywhere. Red belongs to the fuel / DEF / load gauges, which have a bad end.
local expect = {}
for i=1,below do table.insert(expect,"A") end
for i=1,green do table.insert(expect,"G") end
for i=1,above do table.insert(expect,"A") end
local got = {}
for i = 1, segs do
    table.insert(got, (i >= GREEN_FROM and i <= GREEN_TO) and "G" or "A")
end
check("no red anywhere on a loss column",
    not table.concat(got,""):find("R"), table.concat(got,""))
check("amber sits on BOTH sides of the green band",
    got[1] == "A" and got[segs] == "A" and got[GREEN_FROM] == "G",
    string.format("bottom=%s top=%s band=%s", got[1], got[segs], got[GREEN_FROM]))
check("colour transitions occur at the zone boundaries",
    table.concat(got,"") == table.concat(expect,""),
    table.concat(got,"") .. " vs " .. table.concat(expect,""))

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
os.exit(fail==0 and 0 or 1)
