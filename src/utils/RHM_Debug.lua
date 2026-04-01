-- EN: Centralized debug logging system for the Realistic Harvesting mod.
--     Controls which modules are allowed to print debug output to the game log.
-- UA: Централізована система керування дебаг-логами для мода Realistic Harvesting.
--     EN: Determines which modules are allowed to output debug information to the game log.
--     UA: Визначає, які модулі мають право виводити відлагоджувальну інформацію в лог гри.
RHM_Debug = {}

-- EN: Master switch. Set to true when you need a diagnostic log session, false for release.
--     DEV: Enabled for store integration debugging — flip back to false before publishing.
-- UA: Головний вимикач. true — для діагностики, false — для релізу.
RHM_Debug.MASTER_ENABLE = true

-- EN: Per-module debug toggles. Only active when MASTER_ENABLE = true.
-- UA: Налаштування по окремих модулях. Активні лише при MASTER_ENABLE = true.
RHM_Debug.Modules = {
    -- EN: Main manager (game load, HUD, initialization)
    -- UA: Основний менеджер (завантаження гри, HUD, ініціалізація)
    Manager = false,

    -- EN: Combine specialization logic (crop detection, speed limiting)
    -- UA: Логіка комбайна (відбір культур, обмеження швидкості)
    Combine = false,

    -- EN: Load calculator (yield, crop types, engine load % and math)
    -- UA: Калькулятор навантаження (врожайність, типи культур, навантаження % і математика)
    LoadCalculator = false,

    -- EN: Combine memory (fan, rotor, sieve setting changes)
    -- UA: Пам'ять комбайна (зміна налаштувань вентилятора, ротора і тд)
    CombineMemory = false,

    -- EN: Network events (packet exchange between server and client)
    -- UA: Мережеві події (обмін пакетами між сервером та клієнтом)
    Network = false,

    -- EN: Menu UI (settings menu open/close, clicks)
    -- UA: Інтерфейс меню (відкриття налаштувань, кліки)
    UI = false,

    -- EN: Store/shop integration — logs every step of upgrade tier injection and vehicle config read-back.
    --     Produces a full diagnostic dump so we can pinpoint exactly where the store pipeline breaks.
    -- UA: Інтеграція з магазином — логує кожен крок вставки конфігурацій і зчитування при завантаженні.
    Shop = true,
}

-- EN: Checks whether debug output is allowed for a specific module.
-- UA: Перевіряє чи дозволено виведення логів для конкретного модуля.
function RHM_Debug.isEnabled(moduleName)
    if not RHM_Debug.MASTER_ENABLE then
        return false
    end

    local isEnabled = RHM_Debug.Modules[moduleName]
    if isEnabled == nil then
        -- EN: If module is not found, logging is disabled by default.
        -- UA: Якщо модуль не знайдено, лог вимкнено за замовчуванням.
        return false
    end

    return isEnabled
end

-- EN: Convenience function to print a debug message for a specific module.
-- UA: Зручна функція для виведення дебаг-повідомлення для конкретного модуля.
function RHM_Debug.log(moduleName, message)
    if RHM_Debug.isEnabled(moduleName) then
        print(string.format("RHM [%s]: %s", moduleName, message))
    end
end
