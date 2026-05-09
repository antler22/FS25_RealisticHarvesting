# Forage Harvester Yield Calculation — Bug Investigation

## Symptom
Yield (tons/acre) is far too high on forage harvesters. Speed (km/h) and throughput (tons/hr) are correct. The user's manually set calculation width of 48 ft appears to be ignored.

## Yield Formula (Correct)
**File:** `src/logic/LoadCalculator.lua:1575`
```lua
self.currentYield = (sumMass / sumArea) * 10  -- t/ha
```

The formula itself is correct. Since throughput (tons/hr) is accurate, `sumMass` is correct. Therefore **`sumArea` is too low** — the denominator is underestimated, which inflates the yield.

---

## Root Cause

### The pickup header width is 12ft, the manual setting is 48ft

When a forage harvester uses a pickup header (`fillTypeConverter="PICKUPHEADER_GRASS"` in the XML), the mod reads the pickup's work area width (~12 ft) instead of the original swath width (48 ft). The yield formula then inflates by approximately 4× because the area denominator is too small.

### Why the user's 48ft setting is silently ignored

The swath width correction lives in `src/rhm_Combine.lua:630-651` (inside `addCutterArea`):

```lua
if spec.combineMemory and spec.combineMemory.swathWidth and spec.combineMemory.swathWidth > 0 then
    -- Walk attached cutters to find the working header width.
    local headerW = 0
    local sc = self.spec_combine
    if sc and sc.attachedCutters then
        for c, _ in pairs(sc.attachedCutters) do
            -- ... tries to read workWidth from the cutter ...
        end
    end
    if headerW > 0.5 then
        areaForYield = areaForYield * (spec.combineMemory.swathWidth / headerW)
    end
end
```

The problem: the correction **only applies when `headerW > 0.5`**. For pickup headers, the `headerW` loop reads the pickup's narrow work area (e.g. 12 ft). The correction factor becomes `48 / 12 = 4x`, but the **pixel area** (`area * sqmMultiplier` at line 624) is the starting point. For direct-cut forage, the pixel area is already too large relative to the actual mass because the game's pixel callbacks overcount for forage harvesting, or the area is derived from the wrong source entirely.

The real issue is in **`onUpdateTick` at line 1425-1431**, where the area for yield is finalized:

```lua
if pixelAreaDelta > 0 then
    areaForYield = pixelAreaDelta         -- PRIMARY path for direct-cut forage
elseif spec._cachedCutWidth and spec._cachedCutWidth > 0 then
    local dist = self.lastMovedDistance or 0
    areaForYield = dist * spec._cachedCutWidth  -- geometric fallback (never reached)
end
```

For forage harvesters doing direct cutting, `pixelAreaDelta > 0` is true, so the geometric fallback (`dist × 48ft`) **never runs**. The area is purely from FS25's pixel harvest callbacks, which do not scale correctly for pickup headers.

---

## Summary of Key Files

| File | Role |
|---|---|
| `src/logic/LoadCalculator.lua` | Core yield calculation (`updateProductivityAndYield`, line 1538) |
| `src/rhm_Combine.lua` | FS25 specialization; `addCutterArea` (line 567), `onUpdateTick` (line 1376) — area flow |
| `src/settings/CombineMemory.lua` | `swathWidth` storage (line 71) |
| `src/gui/CombineCalibrationGUI.lua` | Swath width UI (lines 802-846) |
| `src/hud/DraggableHUD.lua` | HUD rendering, `acPerHour` calculation (line 223) |

---

## Fix Proposal

### 1. Add a pickup header detection function

```lua
local function isPickupHeader(self)
    local sc = self.spec_combine
    if not sc or not sc.attatedCutters then return false end
    for cutter, _ in pairs(sc.attachedCutters) do
        local ftc = cutter.spec_fillTypeConverter
        if ftc and ftc.fillTypeConverterType == "PICKUPHEADER_GRASS" then
            return true
        end
    end
    return false
end
```

### 2. Bypass pixel area for pickup headers (`onUpdateTick`, ~line 1425)

When a pickup header is detected, skip `pixelAreaDelta` and calculate area geometrically using the user's manual swath width:

```lua
local isPickup = isPickupHeader(self)

if isPickup and spec.combineMemory and spec.combineMemory.swathWidth and spec.combineMemory.swathWidth > 0 then
    -- EN: Pickup header -- pixel area is unreliable. Use distance x manual swath width.
    local dist = self.lastMovedDistance or 0
    areaForYield = dist * spec.combineMemory.swathWidth
elseif pixelAreaDelta > 0 then
    areaForYield = pixelAreaDelta
elseif spec._cachedCutWidth and spec._cachedCutWidth > 0 then
    local dist = self.lastMovedDistance or 0
    areaForYield = dist * spec._cachedCutWidth
end
```

### 3. Skip work area iteration in `addCutterArea` (~line 630)

When a pickup header is detected, don't try to read work areas. The manual swath width is the source of truth:

```lua
if spec.combineMemory and spec.combineMemory.swathWidth and spec.combineMemory.swathWidth > 0 then
    if isPickupHeader(self) then
        -- EN: Pickup header -- manual swath width is authoritative. Skip work area detection.
        -- The pixel area has already been scaled via the geometric path in onUpdateTick.
        -- No further correction needed here.
    else
        -- Existing logic: walk attachedCutters to find headerW...
        local headerW = 0
        -- ... (existing loop unchanged)
        if headerW > 0.5 then
            areaForYield = areaForYield * (spec.combineMemory.swathWidth / headerW)
        end
    end
end
```

### 4. Fix HUD width caching (~line 1397)

Ensure `_cachedCutWidth` resolves to the manual swath width for pickup headers, so `ac/hr` in the HUD is also correct:

```lua
if not spec._cachedCutWidth or spec._cachedCutWidth <= 0 then
    if isPickupHeader(self) and spec.combineMemory and spec.combineMemory.swathWidth then
        spec._cachedCutWidth = spec.combineMemory.swathWidth
    else
        -- Existing cutter iteration logic...
    end
end
```

### 5. Edge case: no manual width set

If the user hasn't set a manual swath width, fall back to the pickup's work area as a best-effort estimate, but warn the user. This can be added to the `addCutterArea` swath correction block.

---

## Expected Result

After the fix, forage harvesters with `PICKUPHEADER_GRASS` headers will:
- Ignore all game-reported work area widths (12 ft pickup width)
- Calculate yield area purely from `distance_traveled x user_manual_swath_width` (48 ft)
- Display correct `ac/hr` in the HUD using the same manual width
- Yield (tons/acre) will no longer be inflated by ~4x
