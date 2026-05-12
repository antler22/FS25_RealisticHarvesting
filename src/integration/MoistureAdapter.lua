-- EN: Soft dependency bridge for the external 'Moisture System' mod.
--     Safely fetches grain moisture data if the mod is present; returns 0 if not installed.
--     This adapter is intentionally side-effect-free — if the external mod is absent,
--     all calls return 0 and no penalty is applied.
-- UA: Безпечний місток для зовнішнього моду 'Moisture System'.
--     Безпечно отримує дані вологості зерна якщо мод встановлено, інакше повертає 0.
MoistureAdapter = {}
MoistureAdapter.isActive = false

--- Checks if the MoistureSystem mod is loaded and caches the result.
--  Called once from RealisticHarvestManager:onMissionLoaded().
function MoistureAdapter.initialize()
    if g_currentMission ~= nil and g_currentMission.MoistureSystem ~= nil then
        MoistureAdapter.isActive = true
    else
        MoistureAdapter.isActive = false
    end
end

--- Returns grain moisture % (0–100) for a specific object node + fill type.
--  Falls back to 0 on any error or if the mod is absent.
---@param node number  The scene node ID (e.g. vehicle.components[1].node)
---@param fillType number  FS25 fill type enum value
---@return number Moisture percentage 0.0–100.0
function MoistureAdapter.getObjectMoisture(node, fillType)
    if not MoistureAdapter.isActive or not node or not fillType then return 0 end
    local ok, val = pcall(function()
        return g_currentMission.MoistureSystem:getObjectMoisture(node, fillType)
    end)
    if ok and val then return val * 100 end
    return 0
end

--- Returns grain moisture % (0–100) at a specific world-space position.
--  Used as fallback when fill type is UNKNOWN.
---@param x number  World X coordinate
---@param z number  World Z coordinate
---@return number Moisture percentage 0.0–100.0
function MoistureAdapter.getMoistureAtPosition(x, z)
    if not MoistureAdapter.isActive or not x or not z then return 0 end
    local ok, val = pcall(function()
        return g_currentMission.MoistureSystem:getMoistureAtPosition(x, z)
    end)
    if ok and val then return val * 100 end
    return 0
end
