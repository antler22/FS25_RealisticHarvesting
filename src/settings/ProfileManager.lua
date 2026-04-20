-- EN: Manages global user crop profiles, persisted in the FS25 modSettings folder.
--     Profiles store per-crop combine settings (fan, rotor, sieves, feeder) that the player
--     has manually saved, and are reloaded across game sessions.
-- UA: Керує глобальними профілями налаштувань культур, збережених у папці modSettings FS25.
--     Профілі зберігають налаштування комбайна для кожної культури (вентилятор, ротор, решета, подача),
--     які гравець зберіг вручну, і перезавантажуються між ігровими сесіями.
ProfileManager = {}
local ProfileManager_mt = Class(ProfileManager)

-- EN: XML root tag path used within the profiles XML file.
-- UA: Шлях кореневого тегу XML, що використовується у файлі профілів.
ProfileManager.XMLTAG = "realisticHarvestingProfiles.profiles"

-- EN: Complete list of all possible params across all machine types.
--     Used when reading profiles from XML — we try each name and only store it if present.
--     Add new params here when CombineSettingsDatabase.machineParams is extended.
-- UA: Повний список можливих параметрів для всіх типів машин.
ProfileManager.ALL_PARAMS = {
    -- grain
    "rotor", "concave", "upperSieve", "lowerSieve", "fan",
    -- forage
    "chopLength", "kernelProcessor", "acceleratorGap",
    -- root
    "shakingIntensity",
    -- shared (root/cotton legacy)
    "feeder",
    -- universal
    "targetEngineLoad",
}

-- EN: Creates a new ProfileManager instance with an empty profiles table.
-- UA: Створює новий екземпляр ProfileManager з порожньою таблицею профілів.
function ProfileManager.new()
    local self = setmetatable({}, ProfileManager_mt)
    self.profiles = {}
    return self
end

-- EN: Returns the absolute path to the profiles XML file in the modSettings directory.
--     Creates the modSettings and mod-specific subdirectory if they do not exist yet.
-- UA: Повертає абсолютний шлях до XML-файлу профілів у директорії modSettings.
--     Створює директорії modSettings і підпапку мода, якщо вони ще не існують.
function ProfileManager:getXmlFilePath()
    local userPath = getUserProfileAppPath()
    if not userPath then
        print("RHM: ERROR - Cannot get user profile path for profiles")
        return nil
    end

    local modSettingsPath = userPath .. "modSettings"
    local rhmPath = modSettingsPath .. "/FS25_RealisticHarvesting"

    if not fileExists(modSettingsPath) then
        createFolder(modSettingsPath)
    end

    if not fileExists(rhmPath) then
        createFolder(rhmPath)
    end

    return rhmPath .. "/profiles.xml"
end

-- EN: Loads all crop profiles from the XML file into memory.
--     Returns false if the file does not exist yet (first launch).
-- UA: Завантажує всі профілі культур з XML-файлу в пам'ять.
--     Повертає false, якщо файл ще не існує (перший запуск).
function ProfileManager:loadProfiles()
    local xmlPath = self:getXmlFilePath()
    print(string.format("RHM: [PROFILE-DIAG] loadProfiles called | path=%s | fileExists=%s", tostring(xmlPath), tostring(xmlPath ~= nil and fileExists(xmlPath) or false)))
    if not xmlPath or not fileExists(xmlPath) then
        print("RHM: [PROFILE-DIAG] loadProfiles EARLY EXIT - file does not exist yet")
        return false
    end

    local xml = XMLFile.load("RHM_Profiles", xmlPath)
    print(string.format("RHM: [PROFILE-DIAG] loadProfiles XMLFile.load result = %s", tostring(xml ~= nil)))
    if xml then
        self.profiles = {}
        local i = 0
        while true do
            local key = string.format("%s.profile(%d)", self.XMLTAG, i)
            if not xml:hasProperty(key) then
                break
            end

            -- EN: Read each profile entry by crop name.
            -- UA: Зчитуємо кожен запис профілю за назвою культури.
            local cropName = xml:getString(key .. "#cropName")
            if cropName then
                -- EN: Read all known params dynamically. Only store params that were
                --     actually written (non-nil), so old grain-only saves still load
                --     correctly without polluting forage/root entries with 50% defaults.
                -- UA: Зчитуємо всі відомі параметри динамічно. Зберігаємо тільки ті,
                --     що були реально записані, щоб старі зернові збереження
                --     не забруднювали форажні/коренеплодні значеннями 50%.
                local profile = {}
                for _, pName in ipairs(ProfileManager.ALL_PARAMS) do
                    local sentinel = (pName == "targetEngineLoad") and 9999 or -1
                    local v = xml:getInt(key .. "#" .. pName, sentinel)
                    if v ~= sentinel then
                        profile[pName] = v
                    end
                end
                -- EN: Legacy compat: old saves wrote "feeder" for what is now "concave" on grain machines.
                -- UA: Зворотна сумісність: старі збереження писали "feeder" замість "concave".
                if profile.feeder and not profile.concave then
                    profile.concave = profile.feeder
                end
                -- EN: Ensure targetEngineLoad always has a sane default.
                if not profile.targetEngineLoad then profile.targetEngineLoad = 95 end
                self.profiles[cropName] = profile
                print(string.format("RHM: [PROFILE-DIAG]   loaded profile[%d] cropName=%s targetEngineLoad=%s", i, tostring(cropName), tostring(profile.targetEngineLoad)))
            end
            i = i + 1
        end
        xml:delete()
        print(string.format("RHM: Loaded %d user crop profiles from %s", i, xmlPath))
        return true
    end
    return false
end

-- EN: Saves all currently loaded profiles back to the XML file on disk.
--     Called automatically after any profile change via saveProfile().
-- UA: Зберігає всі поточно завантажені профілі назад у XML-файл на диску.
--     Викликається автоматично після будь-якої зміни профілю через saveProfile().
function ProfileManager:saveProfiles()
    local xmlPath = self:getXmlFilePath()
    print(string.format("RHM: [PROFILE-DIAG] saveProfiles called | path=%s", tostring(xmlPath)))
    if not xmlPath then return false end

    local xml = XMLFile.create("RHM_Profiles", xmlPath, "realisticHarvestingProfiles")
    print(string.format("RHM: [PROFILE-DIAG] saveProfiles XMLFile.create result = %s | profileCount=%d", tostring(xml ~= nil), (function() local n=0; for _ in pairs(self.profiles) do n=n+1 end; return n end)()))
    if xml then
        local i = 0
        for cropName, settings in pairs(self.profiles) do
            print(string.format("RHM: [PROFILE-DIAG]   writing profile[%d] cropName=%s", i, tostring(cropName)))
            local key = string.format("%s.profile(%d)", self.XMLTAG, i)
            xml:setString(key .. "#cropName", cropName)
            -- EN: Write all params that are present in this profile (dynamic — no hardcoded list).
            -- UA: Записуємо всі параметри що є в профілі (динамічно — без жорсткого списку).
            for k, v in pairs(settings) do
                if type(v) == "number" then
                    xml:setInt(key .. "#" .. k, v)
                end
            end
            i = i + 1
        end
        xml:save()
        xml:delete()
        print(string.format("RHM: Saved %d user crop profiles to %s", i, xmlPath))
        return true
    end
    return false
end

-- EN: Returns the profile for a specific crop name, or nil if none is saved.
-- UA: Повертає профіль для конкретної назви культури, або nil якщо профілю немає.
function ProfileManager:getProfile(cropName)
    if not cropName then return nil end
    return self.profiles[cropName]
end

-- EN: Saves or overwrites a profile for a specific crop with the given settings.
--     Immediately persists the change to the XML file.
-- UA: Зберігає або перезаписує профіль для конкретної культури з заданими налаштуваннями.
--     Негайно зберігає зміну у XML-файл.
function ProfileManager:saveProfile(cropName, settings)
    if not cropName or not settings then return false end

    -- EN: Store all numeric settings keys — no hardcoded list, works for grain/forage/root/cotton.
    -- UA: Зберігаємо всі числові ключі налаштувань — без жорсткого списку, для всіх типів машин.
    local saved = {}
    for k, v in pairs(settings) do
        if type(v) == "number" then
            saved[k] = v
        end
    end
    if not saved.targetEngineLoad then saved.targetEngineLoad = 95 end
    self.profiles[cropName] = saved

    self:saveProfiles()
    return true
end
