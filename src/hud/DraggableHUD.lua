-- EN: Draggable on-screen HUD overlay for the Realistic Harvesting mod.
--     Displays live combine metrics: engine load, yield, productivity, crop loss, and speed.
--     Supports drag-and-drop repositioning (via mouse on the header), dynamic row sizing
--     based on user-selected visible metrics, and the "Settings" button that opens the calibration GUI.
-- UA: Перетягуваний HUD-оверлей на екрані для мода Realistic Harvesting.
--     Відображає живі показники комбайна: навантаження двигуна, врожайність, продуктивність, втрати зерна, швидкість.
--     Підтримує перетягування для репозиціонування (через мишу по заголовку), динамічне змінення розміру рядків
--     залежно від вибраних метрик і кнопку "Settings" яка відкриває GUI калібрування.
DraggableHUD = {}
DraggableHUD.__index = DraggableHUD

DraggableHUD.DRAG_DELAY_MS = 15
DraggableHUD.DRAG_LIMIT = 2

function DraggableHUD.new(modDirectory, settings)
    local self = setmetatable({}, DraggableHUD)

    self.modDirectory = modDirectory
    self.settings = settings
    self.vehicle = nil

    self.data = {
        load = 0,
        yield = 0,
        speed = 0,
        cropLoss = 0,
        headerLoss = 0,
        tonPerHour = 0,
        litersPerHour = 0,
        recommendedSpeed = 0,
        isPlugged = false,
        plugTimerPct = 0,
        moistureLabel = "",
        grainMoisture = 0,
    }

    self.width = 0.11
    self.height = 0.18
    self.headerHeight = 0.028
    self.uiScale = 1.0

    self.dragging = false
    self.dragStartX = nil
    self.dragOffsetX = nil
    self.dragStartY = nil
    self.dragOffsetY = nil
    self.lastDragTimeStamp = nil

    self.backgroundOverlay = nil
    self.headerOverlay = nil
    self.accentLineOverlay = nil
    self.icons = {}

    return self
end

function DraggableHUD:load()
    self.uiScale = 1.0
    if g_gameSettings then
        self.uiScale = g_gameSettings:getValue("uiScale") or 1.0
    end

    self.width = 0.09 * self.uiScale
    self.height = 0.155 * self.uiScale
    self.headerHeight = 0.030 * self.uiScale

    self.x, self.y = self:getPosition()

    local bgTexture = self.modDirectory .. "textures/hud_background.dds"

    -- EN: Dark amber-tinted header strip replacing the old green one.
    -- UA: Темна бурштинова смуга заголовку замість старої зеленої.
    self.headerOverlay = Overlay.new(bgTexture, self.x, self.y + self.height, self.width, self.headerHeight)
    self.headerOverlay:setColor(0.09, 0.07, 0.03, 1.0)

    -- Removed the thin amber accent line at the top of the header as requested.
    self.accentLineOverlay = nil

    -- EN: Dark olive background panel, more opaque for better readability.
    -- UA: Темно-оливкова фонова панель, більш непрозора для кращої читабельності.
    self.backgroundOverlay = Overlay.new(bgTexture, self.x, self.y, self.width, self.height)
    self.backgroundOverlay:setColor(0.04, 0.05, 0.03, 0.92)

    self:loadIcons(self.uiScale)

    if RHM_Debug and RHM_Debug.isEnabled("UI") then
        print("RHM: DraggableHUD loaded successfully")
    end
end

function DraggableHUD:loadIcons(uiScale)
    local iconHeight = 0.024 * self.uiScale
    local iconWidth = iconHeight / g_screenAspectRatio

    local iconsPath = self.modDirectory .. "textures/"

    -- EN: Icon registry. Every HUD row and GUI slider has its own key so JD-style .dds files
    --     can be dropped in as direct replacements. Placeholders copy nearby existing icons.
    --     See README for the full icon spec sheet.
    local iconNames = {
        -- EN: Core metric rows (HUD)
        load         = "icon_load",         -- engine load gauge
        yield        = "icon_yield",        -- grain head / yield
        speed        = "icon_speed",        -- speedometer
        productivity = "icon_productivity", -- throughput / t/h

        -- EN: Grain combine loss rows (HUD + GUI)
        loss         = "icon_loss",         -- combined loss (level 0 / fallback)
        sep          = "icon_sep",          -- separation loss (rotor/concave)
        cln          = "icon_cln",          -- cleaning loss (fan/sieves)
        hdr          = "icon_hdr",          -- header loss

        -- EN: Forage-specific (HUD + GUI)
        score        = "icon_score",        -- processing score (inverted — high = good)
        chop         = "icon_chop",         -- cut/chop length
        kp           = "icon_kp",           -- kernel processor gap
        accelerator  = "icon_accelerator",  -- crop accelerator gap (NOT the same as grain fan)

        -- EN: Condition / warning rows (HUD)
        plug         = "icon_plug",         -- rotor plug / blockage warning
        moisture     = "icon_moisture",     -- dew / moisture condition

        -- EN: GUI slider parameter icons (grain combine)
        fan          = "icon_fan",
        rotor        = "icon_rotor",
        concave      = "icon_concave",
        sieve_upper  = "icon_sieve_upper",
        sieve_lower  = "icon_sieve_lower",
        feeder       = "icon_feeder",
        target_load  = "icon_target_load",  -- target engine load slider
    }

    for name, filename in pairs(iconNames) do
        local iconPath = iconsPath .. filename .. ".dds"
        local icon = Overlay.new(iconPath, 0, 0, iconWidth, iconHeight)
        icon:setColor(1, 1, 1, 0.80)
        self.icons[name] = icon
    end

    if self.settings.showLoad == nil then self.settings.showLoad = true end
    if self.settings.showYield == nil then self.settings.showYield = true end
    if self.settings.showSpeed == nil then self.settings.showSpeed = true end
    if self.settings.showCropLoss == nil then self.settings.showCropLoss = true end
    if self.settings.showProductivity == nil then self.settings.showProductivity = true end
end

function DraggableHUD:getPosition()
    local x = self.settings.hudPosX
    local y = self.settings.hudPosY

    if x and y then
        if x >= -0.1 and x <= 1.1 and y >= -0.1 and y <= 1.1 then
            x = math.max(0, math.min(1 - (self.width or 0), x))
            y = math.max(0, math.min(1 - (self.height or 0), y))
            return x, y
        else
            if RHM_Debug and RHM_Debug.isEnabled("UI") then
                print(string.format("RHM: Saved HUD position (%.2f, %.2f) is off-screen. Resetting to default.", x, y))
            end
        end
    end

    if g_currentMission and g_currentMission.hud and g_currentMission.hud.speedMeter then
        local speedMeter = g_currentMission.hud.speedMeter
        if speedMeter.speedBg and speedMeter.speedBg.x and speedMeter.speedBg.x > 0.01 then
            local offsetX = speedMeter:scalePixelToScreenWidth(-145)
            local offsetY = speedMeter:scalePixelToScreenHeight(15)
            return speedMeter.speedBg.x + offsetX, speedMeter.speedBg.y + offsetY
        end
    end

    return 0.7, 0.05
end

function DraggableHUD:setPosition(x, y)
    self.x = x
    self.y = y
end

function DraggableHUD:setVehicle(vehicle)
    self.vehicle = vehicle
    if vehicle then
        self:update(vehicle)
    else
        self.data.load = 0
        self.data.yield = 0
        self.data.speed = 0
        self.data.cropLoss = 0
        self.data.tonPerHour = 0
        self.data.litersPerHour = 0
        self.data.recommendedSpeed = 0
    end
end

function DraggableHUD:update(dt)
    local vehicle = self.vehicle
    if not vehicle then return end

    local spec = vehicle.spec_rhm_Combine
    if not spec or not spec.data then return end

    self.data.load             = spec.data.load or 0
    self.data.yield            = spec.data.yield or 0
    self.data.cropLoss         = spec.data.cropLoss or 0
    self.data.thrLoss          = spec.data.thrLoss or spec.data.cropLoss or 0
    self.data.cleanLoss        = spec.data.cleanLoss or 0
    self.data.headerLoss       = spec.data.headerLoss or 0
    self.data.tonPerHour       = spec.data.tonPerHour or 0
    self.data.litersPerHour    = spec.data.litersPerHour or 0
    self.data.recommendedSpeed = spec.data.recommendedSpeed or 0
    self.data.speed            = vehicle:getLastSpeed() or 0
    self.data.isPlugged        = spec.data.isPlugged or false
    self.data.plugTimerPct     = spec.data.plugTimerPct or 0
    self.data.moistureLabel    = spec.data.moistureLabel or ""
    self.data.grainMoisture    = spec.data.grainMoisture or 0

    if self.dragging then
        if g_inputBinding and g_inputBinding.getMousePosition then
            local posX, posY = g_inputBinding:getMousePosition()
            if posX and posY then
                self:moveTo(posX - self.dragOffsetX, posY - self.dragOffsetY)
            end
        end
    end
end

function DraggableHUD:draw()
    if not g_currentMission:getIsClient() then return end
    if not self.settings.showHUD then return end
    if not self.vehicle then return end
    -- EN: Hide the compact HUD while the calibration GUI is open — the GUI shows all the same
    --     information in a larger format, so the HUD would just add visual clutter on top.
    -- UA: Приховуємо компактний HUD поки відкритий GUI калібрування — GUI вже показує ту саму інформацію.
    if g_realisticHarvestManager and g_realisticHarvestManager.calibrationGUI
            and g_realisticHarvestManager.calibrationGUI.isOpen then
        return
    end

    self:updateSize()

    self.backgroundOverlay:setPosition(self.x, self.y)
    self.headerOverlay:setPosition(self.x, self.y + self.height)
    self.backgroundOverlay:setDimension(self.width, self.height)
    self.headerOverlay:setDimension(self.width, self.headerHeight)

    self.backgroundOverlay:render()
    self.headerOverlay:render()



    -- EN: Amber title text in header.
    -- UA: Бурштиновий заголовок.
    setTextBold(true)
    setTextAlignment(RenderText.ALIGN_CENTER)
    setTextColor(0.83, 0.54, 0.04, 1.0)
    local titleTextSize = 0.012 * self.uiScale
    local headerTextX = self.x + self.width / 2
    local titleTextY = self.y + self.height + self.headerHeight * 0.65
    renderText(headerTextX, titleTextY, titleTextSize, "Realistic Harvesting")

    setTextBold(false)
    setTextAlignment(RenderText.ALIGN_CENTER)

    local settingsTextSize = 0.009 * self.uiScale
    local btnW = 0.040 * self.uiScale
    local btnH = self.headerHeight * 0.40
    local btnX = self.x + (self.width - btnW) / 2
    local btnY = self.y + self.height + self.headerHeight * 0.06

    local settingsButtonArea = { x = btnX, y = btnY, w = btnW, h = btnH }
    local mx, my = g_inputBinding:getMousePosition()
    local isHovered = mx >= settingsButtonArea.x and mx <= settingsButtonArea.x + settingsButtonArea.w and
                      my >= settingsButtonArea.y and my <= settingsButtonArea.y + settingsButtonArea.h

    if self.backgroundOverlay then
        local btnBgTex = self.modDirectory .. "textures/hud_background.dds"
        local rect = Overlay.new(btnBgTex, btnX, btnY, btnW, btnH)
        if isHovered then
            rect:setColor(0.83, 0.54, 0.04, 0.22)
        else
            rect:setColor(0.00, 0.00, 0.00, 0.28)
        end
        rect:render()
        rect:delete()
    end

    if isHovered then
        setTextColor(0.83, 0.54, 0.04, 1.0)
    else
        setTextColor(0.38, 0.36, 0.32, 1.0)
    end

    local textYOffset = btnY + (btnH - settingsTextSize) / 2 + 0.002
    renderText(headerTextX, textYOffset, settingsTextSize, "Settings")
    setTextBold(false)

    self.menuButtonArea = settingsButtonArea

    self:drawContent()
    setTextBold(false)
end

function DraggableHUD:drawContent()
    local textSize   = 0.015 * self.uiScale
    local lineHeight = 0.028 * self.uiScale
    local iconHeight = 0.024 * self.uiScale
    local iconWidth  = iconHeight / g_screenAspectRatio
    local padding    = 0.005 * self.uiScale

    local iconX = self.x + padding
    local textX = iconX + iconWidth + padding
    local textY = self.y + self.height - self.headerHeight - (0.005 * self.uiScale)

    setTextAlignment(RenderText.ALIGN_LEFT)
    setTextBold(true)
    setTextColor(0.91, 0.87, 0.78, 0.95)

    local unitSystem = self.settings.unitSystem or 1
    local fruitType = nil
    if self.vehicle and self.vehicle.spec_combine then
        fruitType = self.vehicle.spec_combine.lastValidInputFruitType
    end

    -- EN: Row 1 — Engine Load.
    -- UA: Рядок 1 — Навантаження двигуна.
    if self.settings.showLoad then
        local loadColor = self:getLoadColor(self.data.load)
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "load",
            string.format("%.0f%%", self.data.load), self.data.load, loadColor[1], loadColor[2], loadColor[3])
        textY = textY - lineHeight
    end

    -- EN: Row 2 — Yield.
    --     Refreshed every 2 seconds with ±5% noise applied once per refresh, not per frame.
    --     Prevents the number from flickering on every draw call (~60/s) while still giving
    --     realistic sensor-variance feel at a human-readable update rate.
    -- UA: Рядок 2 — Врожайність. Оновлюється кожні 2 секунди з одноразовим ±5% шумом.
    if self.settings.showYield then
        -- EN: Update frozen display value every 2 seconds using g_time (ms). / UA: Оновлюємо кожні 2с.
        local now = g_time or 0
        if not self._lastYieldUpdate or (now - self._lastYieldUpdate) >= 2000 then
            self._lastYieldUpdate = now
            local rawYield = self.data.yield or 0
            if rawYield > 0.1 then
                self._yieldDisplayValue = rawYield * (0.95 + math.random() * 0.10)
            else
                self._yieldDisplayValue = rawYield
            end
        end
        local yieldVal = self._yieldDisplayValue or (self.data.yield or 0)
        local yieldStr
        if UnitConverter then
            local val, suffix = UnitConverter.convertYield(yieldVal, unitSystem, fruitType)
            yieldStr = string.format("%.1f %s", val, suffix)
        else
            yieldStr = string.format("%.1f t/ha", yieldVal)
        end
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "yield", yieldStr, 0)
        textY = textY - lineHeight
    end

    -- EN: Row 3 — Productivity.
    -- UA: Рядок 3 — Продуктивність.
    if self.settings.showProductivity then
        local prodVal = self.data.tonPerHour or 0
        local prodStr
        if UnitConverter then
            local val, suffix = UnitConverter.convertProductivity(prodVal, unitSystem, fruitType, self.data.litersPerHour)
            prodStr = string.format("%.1f %s", val, suffix)
        else
            prodStr = string.format("%.1f t/h", prodVal)
        end
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "productivity", prodStr, 0)
        textY = textY - lineHeight
    end

    -- EN: Loss rows — always visible when showCropLoss is enabled.
    --     Level 0 (No upgrades): single combined qualitative label (Great/Good/Bad/Extreme)
    --     representing total machine loss — players feel the machine working hard without
    --     knowing exact percentages.
    --     Level 1+ (Loss Catch Pan): separate Sep / Cln / Hdr rows with exact percentages.
    -- UA: Рядки втрат — завжди видимі коли showCropLoss увімкнено.
    --     Рівень 0: єдина якісна мітка; Рівень 1+: окремі рядки Sep / Cln / Hdr з %.
    local rhmSpec = self.vehicle and self.vehicle.spec_rhm_Combine
    local upgradeLevel = rhmSpec and rhmSpec.combineMemory and (rhmSpec.combineMemory.upgradeLevel or 0) or 0
    local machineType = rhmSpec and rhmSpec.combineMemory and rhmSpec.combineMemory.machineType
    local isForage = machineType == "forage"

    -- EN: Helper: map a loss % to a qualitative label + color for level-0 display.
    -- UA: Допоміжна: перетворює відсоток у якісну мітку + колір для рівня 0.
    local function lossLabel(pct)
        if pct <= 0.5 then     return "Great",    0.24, 0.72, 0.47  -- green
        elseif pct <= 1.0 then return "Good",     0.60, 0.82, 0.30  -- yellow-green
        elseif pct <= 2.0 then return "Worrying", 0.91, 0.78, 0.25  -- amber
        else                   return "Bad",      0.89, 0.29, 0.29  -- red
        end
    end

    -- EN: PLUG WARNING — highest priority, shown in urgent red when rotor is plugged.
    --     Displayed regardless of upgrade level (critical safety information).
    -- UA: ПОПЕРЕДЖЕННЯ ЗАСМІЧЕННЯ — найвищий пріоритет, показується червоним при засміченні ротора.
    if self.data.isPlugged then
        local blinkOn = math.floor((g_time or 0) / 400) % 2 == 0
        local r, g, b = 0.95, 0.20, 0.20
        if blinkOn then r, g, b = 1.0, 0.5, 0.1 end
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "plug",
            "!! PLUGGED !!", 100, r, g, b)
        textY = textY - lineHeight
    elseif (self.data.plugTimerPct or 0) >= 50 then
        -- EN: Pre-plug warning when load has been 130%+ for over 5 seconds.
        -- UA: Попереднє попередження при навантаженні 130%+ більше 5 секунд.
        local pct = self.data.plugTimerPct
        local r = 0.91 + (pct - 50) / 50 * 0.08
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "plug",
            string.format("PLUG RISK %.0f%%", pct), 100, r, 0.35, 0.20)
        textY = textY - lineHeight
    end

    if self.settings.showCropLoss then
        if isForage then
            -- EN: Forage: Processing Score (0-100%). Inverted from loss — 100% = perfect settings.
            --     Color-coded green→amber→red as score drops. "Score" fits HUD width; full label
            --     "Processing Score" is used in the GUI where space permits.
            -- UA: Форажний: Рейтинг обробки (0-100%). Інвертовано від втрат — 100% = ідеальні налаштування.
            local lossVal = self.data.cleanLoss or 0
            local score   = math.max(0, math.floor(100 - lossVal + 0.5))
            -- EN: Score color: green = high (good), amber = mid, red = low (bad) — inverted from grain loss.
            local r, g, b
            if score >= 95 then     r, g, b = 0.24, 0.72, 0.47   -- green
            elseif score >= 85 then r, g, b = 0.91, 0.78, 0.25   -- amber
            else                    r, g, b = 0.89, 0.29, 0.29   -- red
            end
            if upgradeLevel == 0 then
                -- EN: Level 0: qualitative label (mirrors grain lossLabel thresholds, inverted meaning).
                local label
                if score >= 99 then     label = "Great"
                elseif score >= 97 then label = "Good"
                elseif score >= 93 then label = "Fair"
                else                    label = "Poor"
                end
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "score",
                    label, score, r, g, b)
            else
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "score",
                    string.format("%d%%", score), score, r, g, b)
            end
            textY = textY - lineHeight
        else
            if upgradeLevel == 0 then
                -- EN: Level 0 — single combined row. Total = Sep + Cln + Hdr gives the player
                --     a feel for overall performance without precise measurements.
                -- UA: Рівень 0 — один рядок. Сума Sep+Cln+Hdr показує загальну ефективність.
                local sepVal = self.data.thrLoss or self.data.cropLoss or 0
                local clnVal = self.data.cleanLoss or 0
                local hdrVal = self.data.headerLoss or 0
                local total  = sepVal + clnVal + hdrVal
                local label, r, g, b = lossLabel(total)
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "loss",
                    label, total, r, g, b)
                textY = textY - lineHeight
            else
                -- EN: Level 1+ — Separation loss row (rotor/concave + overload).
                -- UA: Рівень 1+ — рядок втрат сепарації (ротор/дека + перевантаження).
                local sepVal = self.data.thrLoss or self.data.cropLoss or 0
                local sepStr = sepVal > 0.1 and string.format("-%.1f%%", sepVal) or "0%"
                local r, g, b
                if sepVal > 3.0 then     r, g, b = 0.89, 0.29, 0.29
                elseif sepVal > 1.0 then r, g, b = 0.91, 0.78, 0.25
                else                     r, g, b = 0.24, 0.72, 0.47
                end
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "sep",
                    sepStr, sepVal, r, g, b)
                textY = textY - lineHeight

                -- EN: Cleaning loss row — always shown at level 1+ (shows 0% when clean).
                -- UA: Рядок втрат очистки — завжди показується при рівні 1+ (0% якщо нема втрат).
                local clnVal = self.data.cleanLoss or 0
                local clnStr = clnVal > 0.05 and string.format("-%.1f%%", clnVal) or "0%"
                local cr, cg, cb
                if clnVal > 3.0 then     cr, cg, cb = 0.89, 0.29, 0.29
                elseif clnVal > 1.0 then cr, cg, cb = 0.91, 0.78, 0.25
                else                     cr, cg, cb = 0.24, 0.72, 0.47
                end
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "cln",
                    clnStr, clnVal, cr, cg, cb)
                textY = textY - lineHeight

                -- EN: Header loss row — always shown at level 1+.
                -- UA: Рядок втрат жатки — завжди показується при рівні 1+.
                local hdrLoss = self.data.headerLoss or 0
                local hdrStr  = hdrLoss > 0.05 and string.format("-%.1f%%", hdrLoss) or "0%"
                local hr, hg, hb
                if hdrLoss > 3.0 then     hr, hg, hb = 0.89, 0.29, 0.29
                elseif hdrLoss > 1.0 then hr, hg, hb = 0.91, 0.78, 0.25
                else                      hr, hg, hb = 0.24, 0.72, 0.47
                end
                self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "hdr",
                    hdrStr, hdrLoss, hr, hg, hb)
                textY = textY - lineHeight
            end
        end
    end

    -- EN: Plant moisture indicator (time-of-day) — shown when conditions are non-optimal.
    -- UA: Індикатор вологості рослини (час доби) — показується при несприятливих умовах.
    if (self.data.moistureLabel or "") ~= "" then
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "moisture",
            self.data.moistureLabel, 0, 0.65, 0.60, 0.40)
        textY = textY - lineHeight
    end

    -- EN: Grain moisture indicator — shown when 'Moisture System' mod is active and moisture > 0.
    --     Color-coded: green ≤14% (at-limit), yellow 14–20%, red >20% (significant penalty).
    -- UA: Індикатор вологості зерна — показується коли мод 'Moisture System' активний і вологість > 0.
    if self.settings.showMoisture and MoistureAdapter and MoistureAdapter.isActive then
        local gm = self.data.grainMoisture or 0
        local gmStr = string.format("%.1f%%", gm)
        local gmR, gmG, gmB
        if gm > 20 then       gmR, gmG, gmB = 0.89, 0.29, 0.29  -- EN: Red — high penalty
        elseif gm > 14 then   gmR, gmG, gmB = 0.91, 0.78, 0.25  -- EN: Yellow — above limit
        else                  gmR, gmG, gmB = 0.24, 0.72, 0.47  -- EN: Green — within safe range
        end
        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "moisture", gmStr, gm, gmR, gmG, gmB)
        textY = textY - lineHeight
    end

    -- EN: Speed row (current / recommended).
    -- UA: Рядок 5 — Швидкість (поточна / рекомендована).
    if self.settings.showSpeed then
        local currentSpeed = self.data.speed
        local recSpeed = self.data.recommendedSpeed or 0
        local speedStr

        if UnitConverter then
            local cur, suf = UnitConverter.convertSpeed(currentSpeed, unitSystem)
            local rec, _   = UnitConverter.convertSpeed(recSpeed, unitSystem)
            if recSpeed > 0 then
                speedStr = string.format("%.1f / %.1f %s", cur, rec, suf)
            else
                speedStr = string.format("%.1f %s", cur, suf)
            end
        else
            if recSpeed > 0 then
                speedStr = string.format("%.1f / %.1f km/h", currentSpeed, recSpeed)
            else
                speedStr = string.format("%.1f km/h", currentSpeed)
            end
        end

        local r, g, b = 0.91, 0.87, 0.78
        if recSpeed > 0 then
            if currentSpeed > (recSpeed + 2) then   r, g, b = 0.89, 0.29, 0.29
            elseif currentSpeed > recSpeed then     r, g, b = 0.91, 0.78, 0.25
            end
        end

        self:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, "speed", speedStr, 0, r, g, b)
    end
end

function DraggableHUD:updateSize()
    local rhmSpec = self.vehicle and self.vehicle.spec_rhm_Combine
    local upgradeLevel = rhmSpec and rhmSpec.combineMemory and (rhmSpec.combineMemory.upgradeLevel or 0) or 0
    local machineType = rhmSpec and rhmSpec.combineMemory and rhmSpec.combineMemory.machineType
    local isForage = machineType == "forage"

    local rowCount = 0
    if self.settings.showLoad        then rowCount = rowCount + 1 end
    if self.settings.showYield       then rowCount = rowCount + 1 end
    if self.settings.showProductivity then rowCount = rowCount + 1 end

    if self.settings.showCropLoss then
        if isForage then
            rowCount = rowCount + 1  -- EN: single forage loss row
        elseif upgradeLevel == 0 then
            rowCount = rowCount + 1  -- EN: single combined Loss label at level 0
        else
            rowCount = rowCount + 3  -- EN: Sep + Cln + Hdr always shown at level 1+
        end
    end

    -- EN: Plant moisture indicator (time-of-day) — shown when conditions are non-optimal.
    if (self.data.moistureLabel or "") ~= "" then rowCount = rowCount + 1 end
    -- EN: Grain moisture indicator — shown when 'Moisture System' mod is active.
    if self.settings.showMoisture and MoistureAdapter and MoistureAdapter.isActive then rowCount = rowCount + 1 end
    -- EN: Plug warning — always visible when plugged (critical safety info).
    if self.data.isPlugged then rowCount = rowCount + 1 end
    if self.settings.showSpeed then rowCount = rowCount + 1 end

    local lineHeight  = 0.028 * self.uiScale
    local padding     = 0.010 * self.uiScale
    local targetHeight = math.max(0.01 * self.uiScale, (rowCount * lineHeight) + padding)

    if math.abs(self.height - targetHeight) > 0.0001 then
        local heightDiff = self.height - targetHeight
        self.y = self.y + heightDiff
        self.height = targetHeight
        self.settings.hudPosY = self.y
    end
end

function DraggableHUD:drawRow(iconX, textX, textY, iconWidth, iconHeight, textSize, iconName, text, value, r, g, b)
    -- EN: Subtle colored background strip behind each row. The row color (r,g,b) reflects severity
    --     (green=good, amber=caution, red=critical), so the background tint gives an at-a-glance
    --     status even before reading the number.
    -- UA: Тонке кольорове тло позаду кожного рядка. Колір відображає стан (зелений=добре, бурштин, червоний).
    if r and g and b and self.backgroundOverlay then
        local rowH   = textSize + 0.006 * self.uiScale
        local rowTex = self.modDirectory .. "textures/hud_background.dds"
        local rowBg  = Overlay.new(rowTex, self.x, textY - 0.003 * self.uiScale, self.width, rowH)
        rowBg:setColor(r, g, b, 0.14)
        rowBg:render()
        rowBg:delete()
    end

    local icon = self.icons[iconName]
    if icon then
        local iconY = textY + textSize / 2 - iconHeight / 2
        icon:setPosition(iconX, iconY)
        icon:setColor(0.91, 0.87, 0.78, 0.60)
        icon:render()
    end

    if r and g and b then
        setTextColor(r, g, b, 0.95)
    else
        setTextColor(0.91, 0.87, 0.78, 0.95)
    end
    renderText(textX, textY, textSize, text)

    if self.backgroundOverlay then
        local lineY = textY - 0.004
        local lineTex = self.modDirectory .. "textures/hud_background.dds"
        local line = Overlay.new(lineTex, self.x + 0.005, lineY, self.width - 0.010, 0.0007)
        line:setColor(1, 1, 1, 0.07)
        line:render()
        line:delete()
    end
end

-- EN: Engine load → color: warm white < 60%, amber-yellow 60-85%, red > 85%.
-- UA: Навантаження двигуна → колір: тепло-білий < 60%, бурштиново-жовтий 60-85%, червоний > 85%.
function DraggableHUD:getLoadColor(load)
    if load < 60 then
        return {0.91, 0.87, 0.78}
    elseif load < 85 then
        return {0.91, 0.78, 0.25}
    else
        return {0.89, 0.29, 0.29}
    end
end

function DraggableHUD:isMouseOverHeader(posX, posY)
    return posX >= self.x and posX <= (self.x + self.width) and
           posY >= (self.y + self.height) and posY <= (self.y + self.height + self.headerHeight)
end

function DraggableHUD:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.settings.showHUD then return false end
    if button ~= Input.MOUSE_BUTTON_LEFT then return false end

    if self.menuButtonArea and isDown then
        if posX >= self.menuButtonArea.x and posX <= (self.menuButtonArea.x + self.menuButtonArea.w) and
           posY >= self.menuButtonArea.y and posY <= (self.menuButtonArea.y + self.menuButtonArea.h) then
            if g_realisticHarvestManager then
                g_realisticHarvestManager:toggleMenu(self.vehicle)
                return true
            end
        end
    end

    if isDown and self:isMouseOverHeader(posX, posY) then
        if not self.dragging then
            self.dragStartX  = posX
            self.dragOffsetX = posX - self.x
            self.dragStartY  = posY
            self.dragOffsetY = posY - self.y
            self.dragging = true
            self.lastDragTimeStamp = g_time
            if RHM_Debug and RHM_Debug.isEnabled("UI") then print("RHM: Drag started") end
            return true
        end
    elseif isUp then
        if self.dragging then
            self.dragging = false
            if RHM_Debug and RHM_Debug.isEnabled("UI") then
                print(string.format("RHM: Drag stopped at (%.3f, %.3f)", self.x, self.y))
            end
            if self.settings and self.settings.save then
                self.settings:save()
            end
            return true
        end
    end

    return false
end

function DraggableHUD:moveTo(x, y)
    x = math.max(0, math.min(1 - self.width, x))
    y = math.max(0, math.min(1 - (self.height + self.headerHeight), y))
    self:setPosition(x, y)
    self.settings.hudPosX = x
    self.settings.hudPosY = y
end

function DraggableHUD:delete()
    if self.backgroundOverlay then self.backgroundOverlay:delete() end
    if self.headerOverlay then self.headerOverlay:delete() end

    for _, icon in pairs(self.icons) do
        if icon then icon:delete() end
    end

    if RHM_Debug and RHM_Debug.isEnabled("UI") then
        print("RHM: DraggableHUD unloaded")
    end
end

return DraggableHUD