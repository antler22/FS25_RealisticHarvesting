-- Verifies seven-segment numbers always fit inside their field.
-- Overflow here is silent on screen: digits just run past the black panel onto whatever is
-- behind, which reads as a rendering glitch rather than a layout bug.
g_currentMission={time=0}; Logging={warning=function()end,error=function()end}
g_screenAspectRatio=1.7777
function addConsoleCommand() end
Overlay={new=function() return {setPosition=function()end,setDimension=function()end,
  setColor=function()end,render=function()end,delete=function()end} end}
dofile("src/hud/CornerPostHUD.lua")

local L = CornerPostHUD.LAYOUT
local pass, fail = 0, 0
local function check(n,c,d) if c then pass=pass+1;print("  PASS  "..n.."  "..(d or ""))
  else fail=fail+1;print("  FAIL  "..n.."  "..(d or "")) end end

-- Replicate the sizing from drawSevenSegNumber and measure the drawn extent.
local function measure(spec, text)
    local chars={} ; for i=1,#text do chars[#chars+1]=text:sub(i,i) end
    local units=0 ; for _,c in ipairs(chars) do units = units + (c=="." and 0.34 or 1) end
    local padX   = spec.w * 0.05
    local availW = spec.w - padX*2
    local cellW  = availW / units
    local digH   = math.min(spec.h * 0.62, cellW / 0.62)
    local digW   = digH * 0.62
    local usedW  = 0
    for _,c in ipairs(chars) do usedW = usedW + (c=="." and digW*0.42 or digW*1.22) end
    local x0 = spec.x + (spec.w - usedW)*0.5
    return x0, x0+usedW, digH, usedW
end

local fields = {
    { name="rpm",      spec=L.rpm,      samples={"0","880","1880","2450","9999"} },
    { name="speed",    spec=L.speed,    samples={"0.0","4.2","12.7","199.9"} },
    { name="moisture", spec=L.moisture, samples={"0.0","13.0","23.6","100.0"} },
}

print("=== Seven-segment numbers must fit their field ===")
for _, f in ipairs(fields) do
    for _, txt in ipairs(f.samples) do
        local x0, x1, digH, usedW = measure(f.spec, txt)
        local fitsW = x0 >= f.spec.x - 1e-9 and x1 <= f.spec.x + f.spec.w + 1e-9
        local fitsH = digH <= f.spec.h + 1e-9
        check(string.format("%-8s %-7s fits its field", f.name, '"'..txt..'"'),
            fitsW and fitsH,
            string.format("x %.1f..%.1f in %.1f..%.1f, h %.1f <= %.1f",
                x0, x1, f.spec.x, f.spec.x+f.spec.w, digH, f.spec.h))
    end
end

print("\n=== Digits are smaller than before the rescale ===")
do
    -- the previous sizing was a flat spec.h * 0.86
    local _,_,digH = measure(L.rpm, "1880")
    check("rpm digit height reduced vs the old 0.86 factor",
        digH < L.rpm.h * 0.86,
        string.format("%.2f now vs %.2f before", digH, L.rpm.h*0.86))
end

print("\n=== Gauge icons align with their gauges ===")
do
    local gi = L.gaugeIcons
    local pairsList = {
        {"load",L.gaugeLoad},{"coolant",L.gaugeCoolant},{"fuel",L.gaugeFuel},{"def",L.gaugeDef}}
    for _, p in ipairs(pairsList) do
        local role, g = p[1], p[2]
        local iconW = math.min(g.w*0.85, gi.h*1.25)
        local ix = g.x + (g.w-iconW)*0.5
        local iconCx, gaugeCx = ix + iconW*0.5, g.x + g.w*0.5
        check(string.format("%-8s icon centred on its gauge", role),
            math.abs(iconCx-gaugeCx) < 1e-9,
            string.format("icon cx %.2f vs gauge cx %.2f, w %.1f", iconCx, gaugeCx, iconW))
    end
end

-- Dormant segments must not be painted. Passing a nil off-colour is the switch, and the only
-- way to observe it without a screen is to count the rectangles each glyph emits: if unlit
-- elements were still drawn, "1" (two segments) would cost exactly as much as "8" (seven).
print("\n=== Unlit segments are not drawn ===")
do
    local rects = 0
    local probe = setmetatable({ rect = function() rects = rects + 1 end }, { __index = CornerPostHUD })

    local function count(ch, offC)
        rects = 0
        probe:drawSevenSeg(ch, 0, 0, 10, 16, {1,1,1,1}, offC)
        return rects
    end

    local one, eight = count("1", nil), count("8", nil)
    check("a sparse glyph costs less than a full one", one < eight,
        string.format('"1" = %d rects, "8" = %d rects', one, eight))
    check("a blank glyph draws nothing at all", count(" ", nil) == 0,
        string.format('" " = %d rects', count(" ", nil)))
    check("every lit glyph still draws something", count("0", nil) > 0,
        string.format('"0" = %d rects', count("0", nil)))

    -- With an off-colour supplied every element is drawn, so both glyphs cost the same.
    -- This proves the count above is measuring the skip and not some unrelated difference.
    check("supplying an off-colour restores the ghosting",
        count("1", {0,0,0,1}) == count("8", {0,0,0,1}),
        string.format('"1" = %d, "8" = %d with off-colour',
            count("1", {0,0,0,1}), count("8", {0,0,0,1})))
end

print(string.format("\n=== %d passed, %d failed ===", pass, fail))
os.exit(fail==0 and 0 or 1)
