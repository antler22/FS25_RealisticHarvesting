--[[
    CropFactorTuning — DEV-ONLY in-game editor for crop load factors.
    Writes cropFactorTuning.xml to modSettings so you can copy tuned values
    back into LoadCalculator.lua (CROP_FACTORS_BY_NAME / factorMap).

    ENABLED = false  → near-zero runtime cost; GUI/command never register.

    To remove entirely:
      1) Delete this file.
      2) Remove source() and loadFromDisk() block from main.lua.
      3) Remove "CropFactorTuning hook" block from LoadCalculator.lua calculateEngineLoad.
      4) Remove cropFactorTuneGUI lifecycle hooks from RealisticHarvestManager.lua.
--]]

CropFactorTuning = CropFactorTuning or {}

-- EN: Master switch — set true while tuning, keep false for release.
CropFactorTuning.ENABLED = false

CropFactorTuning.XML_ROOT = "cropFactorTuning"

-- EN: Live factor table (absolute values). Initialised from REFERENCE, then overridden by XML.
CropFactorTuning.values = {}

-- EN: Reference crop list — ordered, one row per crop.
--     exampleHp / exampleHeaderM are informational only (typical combine class).
--     defaultFactor must stay in sync with LoadCalculator.lua CROP_FACTORS_BY_NAME.
CropFactorTuning.REFERENCE_CROPS = {
    { name = "WHEAT",            defaultFactor = 0.814, exampleHp = 547, exampleHeaderM = 10.7, note = "Grain: benchmark ~5 km/h with RHM (yield-dependent)" },
    { name = "BARLEY",           defaultFactor = 0.869, exampleHp = 520, exampleHeaderM = 10.5, note = "Slightly harder than wheat" },
    { name = "OAT",              defaultFactor = 0.900, exampleHp = 507, exampleHeaderM = 10.8, note = "Grain: light-stemmed but bulky; roughly on par with wheat" },
    { name = "RYE",              defaultFactor = 0.814, exampleHp = 540, exampleHeaderM = 10.5, note = "Same as wheat" },
    { name = "SPELT",            defaultFactor = 0.814, exampleHp = 540, exampleHeaderM = 10.5, note = "Same as wheat" },
    { name = "TRITICALE",        defaultFactor = 0.461, exampleHp = 520, exampleHeaderM = 10.5, note = "Lighter" },
    { name = "MILLET",           defaultFactor = 0.976, exampleHp = 500, exampleHeaderM = 9.0,  note = "Grain" },
    { name = "MAIZE",            defaultFactor = 0.572, exampleHp = 625, exampleHeaderM = 12.0, note = "Grain corn" },
    { name = "CORN",             defaultFactor = 0.572, exampleHp = 625, exampleHeaderM = 12.0, note = "Grain corn (BY_NAME alias)" },
    { name = "MAIZE_FORAGE",     defaultFactor = 0.300, exampleHp = 956, exampleHeaderM = 9.0,  note = "Green silage corn — far easier for forage harvesters" },
    { name = "MAIZE_SILAGE",     defaultFactor = 0.572, exampleHp = 700, exampleHeaderM = 9.0,  note = "Silage fill type" },
    { name = "SOYBEAN",          defaultFactor = 1.788, exampleHp = 550, exampleHeaderM = 12.0, note = "Harder on the thresher" },
    { name = "SUNFLOWER",        defaultFactor = 2.324, exampleHp = 600, exampleHeaderM = 12.0, note = "Very hard on the combine" },
    { name = "CANOLA",           defaultFactor = 1.738, exampleHp = 540, exampleHeaderM = 10.5, note = "Rapeseed" },
    { name = "SORGHUM",          defaultFactor = 0.801, exampleHp = 520, exampleHeaderM = 10.5, note = "Sorghum" },
    { name = "RICE",             defaultFactor = 1.303, exampleHp = 480, exampleHeaderM = 8.0,  note = "Rice" },
    { name = "RICE_LONG_GRAIN",  defaultFactor = 1.303, exampleHp = 480, exampleHeaderM = 8.0,  note = "Long-grain rice" },
    { name = "PEA",              defaultFactor = 1.152, exampleHp = 520, exampleHeaderM = 10.5, note = "Legume" },
    { name = "LENTIL",           defaultFactor = 1.152, exampleHp = 520, exampleHeaderM = 10.5, note = "Legume" },
    { name = "CHICKPEA",         defaultFactor = 1.152, exampleHp = 520, exampleHeaderM = 10.5, note = "Legume" },
    { name = "GREENBEAN",        defaultFactor = 2.240, exampleHp = 400, exampleHeaderM = 6.0,  note = "Vegetable — high load" },
    { name = "POTATO",           defaultFactor = 0.600, exampleHp = 450, exampleHeaderM = 2.0,  note = "Potato (root crop)" },
    { name = "SUGARBEET",        defaultFactor = 0.920, exampleHp = 600, exampleHeaderM = 6.0,  note = "Sugar beet" },
    { name = "BEETROOT",         defaultFactor = 1.050, exampleHp = 500, exampleHeaderM = 6.0,  note = "Beetroot" },
    { name = "CARROT",           defaultFactor = 0.323, exampleHp = 400, exampleHeaderM = 3.0,  note = "Carrot" },
    { name = "PARSNIP",          defaultFactor = 0.400, exampleHp = 400, exampleHeaderM = 3.0,  note = "Parsnip" },
    { name = "ONION",            defaultFactor = 0.600, exampleHp = 420, exampleHeaderM = 4.0,  note = "Onion" },
    { name = "ONION_DIRTY",      defaultFactor = 0.700, exampleHp = 420, exampleHeaderM = 4.0,  note = "Dirty onion" },
    { name = "SPINACH",          defaultFactor = 2.880, exampleHp = 350, exampleHeaderM = 6.0,  note = "Spinach — very heavy" },
    { name = "GRASS",            defaultFactor = 1.221, exampleHp = 700, exampleHeaderM = 9.0,  note = "Grass" },
    { name = "DRYGRASS",         defaultFactor = 1.100, exampleHp = 650, exampleHeaderM = 9.0,  note = "Dry grass / hay" },
    { name = "ALFALFA",          defaultFactor = 1.100, exampleHp = 650, exampleHeaderM = 9.0,  note = "Alfalfa" },
    { name = "CLOVER",           defaultFactor = 1.100, exampleHp = 650, exampleHeaderM = 9.0,  note = "Clover" },
    { name = "MEADOW",           defaultFactor = 1.221, exampleHp = 650, exampleHeaderM = 9.0,  note = "Meadow grass" },
    { name = "GRASS_WINDROW",    defaultFactor = 1.221, exampleHp = 520, exampleHeaderM = 9.0,  note = "Grass windrow — enum strip maps to GRASS; 0.75 pickup multiplier gives ~0.916 effective" },
    { name = "DRYGRASS_WINDROW", defaultFactor = 1.100, exampleHp = 520, exampleHeaderM = 9.0,  note = "Hay windrow — enum strip maps to DRYGRASS; 0.75 pickup multiplier gives ~0.825 effective" },
    { name = "COTTON",           defaultFactor = 4.782, exampleHp = 600, exampleHeaderM = 12.0, note = "Cotton — extreme load" },
    { name = "SUGARCANE",        defaultFactor = 0.654, exampleHp = 700, exampleHeaderM = 3.0,  note = "Sugar cane" },
    { name = "POPLAR",           defaultFactor = 0.156, exampleHp = 500, exampleHeaderM = 4.0,  note = "Woodchip / poplar" },
    { name = "OILSEED_RADISH",   defaultFactor = 0.391, exampleHp = 500, exampleHeaderM = 10.5, note = "Mustard / cover crop" },
    { name = "GRAPE",            defaultFactor = 0.391, exampleHp = 200, exampleHeaderM = 2.0,  note = "Grape (different machine type)" },
    { name = "OLIVE",            defaultFactor = 0.391, exampleHp = 200, exampleHeaderM = 2.0,  note = "Olive" },
    { name = "MINT",             defaultFactor = 1.054, exampleHp = 400, exampleHeaderM = 6.0,  note = "Mint" },
}

function CropFactorTuning.isEnabled()
    return CropFactorTuning.ENABLED == true
end

function CropFactorTuning.initValuesFromReference()
    CropFactorTuning.values = {}
    for _, row in ipairs(CropFactorTuning.REFERENCE_CROPS) do
        CropFactorTuning.values[row.name] = row.defaultFactor
    end
end

function CropFactorTuning.getXmlPath()
    local sm = SettingsManager.new()
    local base = sm:getServerXmlFilePath()
    if not base then return nil end
    return base:gsub("settings%.xml$", "cropFactorTuning.xml")
end

function CropFactorTuning.loadFromDisk()
    if not CropFactorTuning.isEnabled() then return end
    CropFactorTuning.initValuesFromReference()
    local path = CropFactorTuning.getXmlPath()
    if not path or not fileExists(path) then return end
    local xml = XMLFile.load("RHM_CropFactorTuningLoad", path)
    if not xml then return end
    local root = CropFactorTuning.XML_ROOT
    local i = 0
    while true do
        local base = string.format("%s.crop(%d)", root, i)
        local name = xml:getString(base .. "#name")
        if name == nil or name == "" then break end
        local factor = xml:getFloat(base .. "#factor", CropFactorTuning.values[name] or 0.814)
        CropFactorTuning.values[name] = factor
        i = i + 1
        if i > 512 then break end
    end
    xml:delete()
    print(string.format("[RHM] CropFactorTuning: loaded %d entries from %s", i, path))
end

function CropFactorTuning.saveToDisk()
    if not CropFactorTuning.isEnabled() then return false end
    -- EN: Calling getServerXmlFilePath ensures the modSettings/FS25_RealisticHarvesting folder exists.
    SettingsManager.new():getServerXmlFilePath()
    local path = CropFactorTuning.getXmlPath()
    if not path then return false end
    local root = CropFactorTuning.XML_ROOT
    local xml = XMLFile.create("RHM_CropFactorTuningSave", path, root)
    if not xml then return false end
    for i, row in ipairs(CropFactorTuning.REFERENCE_CROPS) do
        local idx = i - 1
        local base = string.format("%s.crop(%d)", root, idx)
        local v = CropFactorTuning.values[row.name] or row.defaultFactor
        xml:setString(base .. "#name", row.name)
        xml:setFloat(base .. "#factor", v)
    end
    xml:save()
    xml:delete()
    print(string.format("[RHM] CropFactorTuning: saved to %s — copy factors into LoadCalculator.lua CROP_FACTORS_BY_NAME when done", path))
    if g_currentMission then
        g_currentMission:showBlinkingWarning("RHM: cropFactorTuning.xml saved (modSettings)", 3500)
    end
    return true
end

---Returns the override factor for a named crop, or nil if not tuning / not overridden.
---@param cropName string|nil
---@return number|nil
function CropFactorTuning.getFactorOverride(cropName)
    if not CropFactorTuning.isEnabled() or not cropName then return nil end
    return CropFactorTuning.values[cropName]
end

-- ============================================================================
-- GUI (client-only overlay)
-- ============================================================================

CropFactorTuningGui = {}
local CropFactorTuningGui_mt = Class(CropFactorTuningGui)

function CropFactorTuningGui.new(modDirectory)
    local self = setmetatable({}, CropFactorTuningGui_mt)
    self.modDirectory = modDirectory
    self.isOpen = false
    self.selectedIndex = 1
    self.refScroll = 0
    self.buttons = {}
    local tex = modDirectory .. "textures/hud_icons.dds"
    self.overlay = Overlay.new(tex, 0, 0, 1, 1)
    if GuiUtils and GuiUtils.getUVs then
        self.overlay:setUVs(GuiUtils.getUVs({388, 4, 56, 56}, {512, 64}))
    end
    return self
end

function CropFactorTuningGui:delete()
    if self.overlay then
        self.overlay:delete()
        self.overlay = nil
    end
end

function CropFactorTuningGui:toggle()
    if not CropFactorTuning.isEnabled() then return end
    self.isOpen = not self.isOpen
    if self.isOpen then
        self:syncSelectionToLiveCrop()
        g_inputBinding:setShowMouseCursor(true)
    else
        local hudOn = g_realisticHarvestManager and g_realisticHarvestManager.isCursorVisible
        g_inputBinding:setShowMouseCursor(hudOn or false)
    end
end

function CropFactorTuningGui:drawRect(x, y, w, h, color)
    if not self.overlay then return end
    self.overlay:setPosition(x, y)
    self.overlay:setDimension(w, h)
    self.overlay:setColor(color[1], color[2], color[3], color[4])
    self.overlay:render()
end

function CropFactorTuningGui:getActiveCombine()
    if not g_realisticHarvestManager then return nil end
    return g_realisticHarvestManager.lastActiveCombine
end

function CropFactorTuningGui:syncSelectionToLiveCrop()
    local veh = self:getActiveCombine()
    if not veh then return end
    local mem = veh.spec_rhm_Combine and veh.spec_rhm_Combine.combineMemory
    local crop = mem and mem.currentCrop
    if not crop then return end
    for i, row in ipairs(CropFactorTuning.REFERENCE_CROPS) do
        if row.name == crop then
            self.selectedIndex = i
            return
        end
    end
end

function CropFactorTuningGui:update(dt)
end

local COL_BG   = {0,    0,    0,    0.82}
local COL_HDR  = {0.223, 0.407, 0.004, 1.0}
local COL_BTN  = {0.12, 0.12, 0.12, 0.95}
local COL_BTN_H = {0.25, 0.25, 0.22, 1.0}

function CropFactorTuningGui:draw()
    if not self.isOpen or not CropFactorTuning.isEnabled() then return end

    self.buttons = {}
    local mx, my = g_inputBinding:getMousePosition()

    -- Left panel
    local lx, ly, lw, lh = 0.02, 0.12, 0.40, 0.78
    self:drawRect(lx, ly, lw, lh, COL_BG)
    self:drawRect(lx, ly + lh - 0.035, lw, 0.035, COL_HDR)

    setTextBold(true)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
    renderText(lx + 0.01, ly + lh - 0.028, 0.017, "RHM Crop factors (DEV)")
    setTextBold(false)

    -- Live stats from the active combine
    local veh = self:getActiveCombine()
    local liveCrop  = "—"
    local liveLoad  = "—"
    local liveSpeed = "—"
    local liveHp    = "—"
    if veh and veh.spec_rhm_Combine then
        local lc = veh.spec_rhm_Combine.loadCalculator
        local mem = veh.spec_rhm_Combine.combineMemory
        liveCrop = (lc and lc.currentCrop) or (mem and mem.currentCrop) or "—"
        if lc then liveLoad = string.format("%.0f%%", lc:getEngineLoad() or 0) end
        liveSpeed = string.format("%.1f km/h", veh:getLastSpeed() or 0)
        if veh.spec_motorized and veh.spec_motorized.motor then
            liveHp = string.format("%.0f hp", veh.spec_motorized.motor.hp or 0)
        end
    end

    local ty = ly + lh - 0.065
    setTextColor(0.9, 0.88, 0.8, 1)
    renderText(lx + 0.01, ty, 0.013, "Live: " .. tostring(liveCrop) .. "  |  Load " .. liveLoad .. "  |  " .. liveSpeed .. "  |  " .. liveHp)
    ty = ty - 0.028
    renderText(lx + 0.01, ty, 0.011, "XML: " .. tostring(CropFactorTuning.getXmlPath() or "?"))

    local ref = CropFactorTuning.REFERENCE_CROPS
    local sel = ref[self.selectedIndex]
    if not sel then self.selectedIndex = 1; sel = ref[1] end

    local bw, bh = 0.06, 0.035

    local function regBtn(id, x, y, w, h, label)
        local hov = mx >= x and mx <= x + w and my >= y and my <= y + h
        self.buttons[id] = { x = x, y = y, w = w, h = h }
        self:drawRect(x, y, w, h, hov and COL_BTN_H or COL_BTN)
        setTextAlignment(RenderText.ALIGN_CENTER)
        renderText(x + w * 0.5, y + h * 0.25, 0.014, label)
        setTextAlignment(RenderText.ALIGN_LEFT)
    end

    ty = ty - 0.04
    renderText(lx + 0.01, ty, 0.014, "Edit crop:")
    ty = ty - 0.03

    regBtn("prev", lx + 0.01, ty, bw, bh, "<")
    regBtn("next", lx + 0.01 + bw + 0.01, ty, bw, bh, ">")
    regBtn("live", lx + 0.01 + 2 * (bw + 0.01), ty, 0.10, bh, "Live crop")
    setTextColor(1, 0.85, 0.2, 1)
    renderText(lx + 0.32, ty + 0.01, 0.016, sel.name)
    ty = ty - 0.05

    setTextColor(0.65, 0.72, 0.78, 1)
    renderText(lx + 0.01, ty, 0.010, sel.note or "")
    ty = ty - 0.026
    setTextColor(0.85, 0.85, 0.85, 1)
    renderText(lx + 0.01, ty, 0.012, string.format("Factor (lower = easier): %.3f", CropFactorTuning.values[sel.name] or sel.defaultFactor))
    ty = ty - 0.042
    regBtn("fm",  lx + 0.01, ty, bw,   bh, "-0.02")
    regBtn("fp",  lx + 0.09, ty, bw,   bh, "+0.02")
    regBtn("fsm", lx + 0.17, ty, bw,   bh, "-0.005")
    regBtn("fsp", lx + 0.25, ty, bw,   bh, "+0.005")
    ty = ty - 0.05
    regBtn("reset", lx + 0.01, ty, 0.14, bh, "Reset row")
    regBtn("save",  lx + 0.17, ty, 0.18, bh, "Save XML")
    ty = ty - 0.048
    setTextColor(0.55, 0.75, 1.0, 1)
    renderText(lx + 0.01, ty, 0.010, "Console: rhm_cropTune  |  Copy saved XML into LoadCalculator.lua when done")

    -- Right panel: reference table
    local rx, ry, rw, rh = 0.44, 0.12, 0.54, 0.78
    self:drawRect(rx, ry, rw, rh, COL_BG)
    self:drawRect(rx, ry + rh - 0.030, rw, 0.030, COL_HDR)
    setTextColor(1, 1, 1, 1)
    setTextBold(true)
    renderText(rx + 0.01, ry + rh - 0.024, 0.014, "Reference (examples — tune in game, then copy to LoadCalculator.lua)")
    setTextBold(false)

    local rowH   = 0.024
    local y0     = ry + rh - 0.058
    local maxVis = math.floor((rh - 0.08) / rowH)
    self.refScroll = math.max(0, math.min(self.refScroll or 0, math.max(0, #ref - maxVis)))

    setTextColor(0.75, 0.75, 0.7, 1)
    renderText(rx + 0.01, y0 + 0.006, 0.011, "Crop  factor  ~hp  ~m  note")
    local y = y0 - rowH
    for i = self.refScroll + 1, math.min(#ref, self.refScroll + maxVis) do
        local row = ref[i]
        local v   = CropFactorTuning.values[row.name] or row.defaultFactor
        local line = string.format("%-22s  %.3f  %d  %.1f", row.name, v, row.exampleHp or 0, row.exampleHeaderM or 0)
        if i == self.selectedIndex then
            setTextColor(1, 0.9, 0.4, 1)
        else
            setTextColor(0.9, 0.87, 0.78, 1)
        end
        renderText(rx + 0.01, y, 0.010, line)
        y = y - rowH * 0.92
    end
    setTextColor(0.6, 0.6, 0.6, 1)
    renderText(rx + 0.01, ry + 0.02, 0.009, "Scroll: ^ / v buttons")
    regBtn("scrollUp", rx + rw - 0.12, ry + rh - 0.055, 0.05, 0.028, "^")
    regBtn("scrollDn", rx + rw - 0.06, ry + rh - 0.055, 0.05, 0.028, "v")

    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function CropFactorTuningGui:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.isOpen or not CropFactorTuning.isEnabled() then return false end
    if not (isDown and button == Input.MOUSE_BUTTON_LEFT) then return false end

    for id, b in pairs(self.buttons) do
        if posX >= b.x and posX <= b.x + b.w and posY >= b.y and posY <= b.y + b.h then
            local ref = CropFactorTuning.REFERENCE_CROPS
            local sel = ref[self.selectedIndex]
            if id == "prev" then
                self.selectedIndex = self.selectedIndex - 1
                if self.selectedIndex < 1 then self.selectedIndex = #ref end
            elseif id == "next" then
                self.selectedIndex = self.selectedIndex + 1
                if self.selectedIndex > #ref then self.selectedIndex = 1 end
            elseif id == "live" then
                self:syncSelectionToLiveCrop()
            elseif id == "fm" and sel then
                CropFactorTuning.values[sel.name] = math.max(0.05, (CropFactorTuning.values[sel.name] or sel.defaultFactor) - 0.02)
            elseif id == "fp" and sel then
                CropFactorTuning.values[sel.name] = math.min(8.0, (CropFactorTuning.values[sel.name] or sel.defaultFactor) + 0.02)
            elseif id == "fsm" and sel then
                CropFactorTuning.values[sel.name] = math.max(0.05, (CropFactorTuning.values[sel.name] or sel.defaultFactor) - 0.005)
            elseif id == "fsp" and sel then
                CropFactorTuning.values[sel.name] = math.min(8.0, (CropFactorTuning.values[sel.name] or sel.defaultFactor) + 0.005)
            elseif id == "reset" and sel then
                CropFactorTuning.values[sel.name] = sel.defaultFactor
            elseif id == "save" then
                CropFactorTuning.saveToDisk()
            elseif id == "scrollUp" then
                self.refScroll = math.max(0, (self.refScroll or 0) - 3)
            elseif id == "scrollDn" then
                self.refScroll = math.min(math.max(0, #ref - 8), (self.refScroll or 0) + 3)
            end
            return true
        end
    end
    return false
end

-- ============================================================================
-- Console command handler
-- ============================================================================

CropFactorTuning._consoleHandler = CropFactorTuning._consoleHandler or {}

function CropFactorTuning._consoleHandler:consoleCommandCropTune()
    if not CropFactorTuning.isEnabled() then
        print("[RHM] CropFactorTuning is disabled (ENABLED = false).")
        return
    end
    if g_realisticHarvestManager and g_realisticHarvestManager.cropFactorTuneGUI then
        g_realisticHarvestManager.cropFactorTuneGUI:toggle()
    end
end

function CropFactorTuning.registerConsoleCommand()
    if not CropFactorTuning.isEnabled() then return end
    addConsoleCommand("rhm_cropTune", "Toggle RHM crop factor tuning overlay (DEV)", "consoleCommandCropTune", CropFactorTuning._consoleHandler)
end
