-- loadstring was removed in Lua 5.2; the game runs 5.1 but the local interpreter may be
-- newer, so alias it rather than pin the test to one runtime.
loadstring = loadstring or load
g_screenAspectRatio = 1.7777
g_currentMission={time=0}; Logging={warning=function()end,error=function()end}
function addConsoleCommand() end
Overlay={new=function() return {setPosition=function()end,setDimension=function()end,
  setColor=function()end,render=function()end,delete=function()end} end}
g_screenAspectRatio=1.7777
dofile("src/hud/CornerPostHUD.lua")

local cp = CornerPostHUD.new("./", {})
local pass, fail = 0, 0
local function check(n,c,d) if c then pass=pass+1;print("  PASS  "..n.."  "..(d or ""))
  else fail=fail+1;print("  FAIL  "..n.."  "..(d or "")) end end

print("=== Live layout editor ===")

-- capture original
local before = {}
for k,v in pairs(CornerPostHUD.LAYOUT) do
  before[k] = {x=v.x,y=v.y,w=v.w,h=v.h,gap=v.gap,count=v.count,digits=v.digits,label=v.label}
end

-- EN: Pick a real element out of LAYOUT rather than hardcoding a name, so renaming an
--     element in the source can never break this test the way SUBJ just did.
local SUBJ
for k, v in pairs(CornerPostHUD.LAYOUT) do
    if type(v) == "table" and v.x and v.y and v.w and v.h then SUBJ = k break end
end
assert(SUBJ, "no geometry element found in LAYOUT")
print("  (subject element: " .. SUBJ .. ")")

check("list finds elements", cp:consoleList():find(SUBJ, 1, true) ~= nil)
check("unknown element is rejected", cp:consoleSet("nosuchthing",1,2):find("Unknown") ~= nil)

cp:consoleSet(SUBJ, 20, 160)
check("set moves x and y", CornerPostHUD.LAYOUT[SUBJ].x==20 and CornerPostHUD.LAYOUT[SUBJ].y==160,
  string.format("x=%s y=%s", CornerPostHUD.LAYOUT[SUBJ].x, CornerPostHUD.LAYOUT[SUBJ].y))
check("set leaves untouched fields alone", CornerPostHUD.LAYOUT[SUBJ].gap==before[SUBJ].gap,
  "gap="..tostring(CornerPostHUD.LAYOUT[SUBJ].gap))

cp:consoleNudge(SUBJ, -3, 5)
check("nudge is relative", CornerPostHUD.LAYOUT[SUBJ].x==17 and CornerPostHUD.LAYOUT[SUBJ].y==165,
  string.format("x=%s y=%s", CornerPostHUD.LAYOUT[SUBJ].x, CornerPostHUD.LAYOUT[SUBJ].y))

local w0 = CornerPostHUD.LAYOUT[SUBJ].w
cp:consoleSize(SUBJ, 4, -2)
check("size is relative", CornerPostHUD.LAYOUT[SUBJ].w == w0+4)
cp:consoleSize(SUBJ, -9999, -9999)
check("size cannot go non-positive",
  CornerPostHUD.LAYOUT[SUBJ].w > 0 and CornerPostHUD.LAYOUT[SUBJ].h > 0,
  string.format("w=%s h=%s", CornerPostHUD.LAYOUT[SUBJ].w, CornerPostHUD.LAYOUT[SUBJ].h))

-- restore, then dump and re-load to prove round-trip fidelity
for k,v in pairs(before) do
  for f,val in pairs(v) do CornerPostHUD.LAYOUT[k][f] = val end
end
local dumped = cp:consoleDump()
local chunk = assert(loadstring(dumped .. "\nreturn CornerPostHUD.LAYOUT"))
CornerPostHUD.LAYOUT = {}   -- prove the dump reconstructs from nothing
local restored = chunk()

local lost = {}
for k,v in pairs(before) do
  local r = restored[k]
  if not r then table.insert(lost, k.." missing")
  else
    for f,val in pairs(v) do
      if r[f] ~= val then table.insert(lost, string.format("%s.%s %s~=%s",k,f,tostring(r[f]),tostring(val))) end
    end
  end
end
check("dump round-trips every element and field", #lost==0, #lost>0 and table.concat(lost,"; ") or "all fields preserved")

-- The panel defaults to the LEFT edge so it does not sit under the vehicle menus and the
-- mod's own settings dialog, both of which open on the right. Anchoring has to survive a
-- scale change without drifting, and a hand-drag has to win over the anchor permanently —
-- otherwise the next scale change would silently yank the panel back to an edge.
print("\n=== Panel anchoring ===")
do
    local hud = CornerPostHUD.new("", {})

    check("defaults to the left edge", hud.anchorSide == "left", tostring(hud.anchorSide))

    hud:applyAnchor()
    local leftX = hud.posX
    hud:setScale(hud.scale * 1.5)
    check("stays pinned left across a scale change",
        math.abs(hud.posX - leftX) < 1e-9, string.format("%.4f -> %.4f", leftX, hud.posX))

    hud:setAnchorSide("right")
    local rightX = hud.posX
    check("right anchor leaves the panel on screen",
        rightX > 0 and rightX + hud:panelWidthNorm() <= 1.0 + 1e-9,
        string.format("x %.4f + w %.4f", rightX, hud:panelWidthNorm()))
    check("right anchor is right of left anchor", rightX > leftX,
        string.format("%.4f > %.4f", rightX, leftX))

    -- Pinned right means the panel's RIGHT edge holds still while its width changes, which is
    -- the opposite of the left case and the reason applyAnchor cannot just set posX.
    hud:setScale(hud.scale * 0.6)
    check("stays pinned right across a scale change",
        math.abs(hud.posX + hud:panelWidthNorm() - (1.0 - hud.edgeMargin)) < 1e-9,
        string.format("right edge at %.4f, want %.4f",
            hud.posX + hud:panelWidthNorm(), 1.0 - hud.edgeMargin))

    -- A drag frees the panel; nothing may move it afterwards.
    hud.anchorSide = nil
    hud.posX = 0.42
    hud:setScale(hud.scale * 1.3)
    check("a hand-placed panel is never re-anchored", math.abs(hud.posX - 0.42) < 1e-9,
        string.format("%.4f", hud.posX))

    check("setAnchorSide rejects nonsense and frees instead",
        hud:setAnchorSide("sideways") == nil)
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
os.exit(fail==0 and 0 or 1)
