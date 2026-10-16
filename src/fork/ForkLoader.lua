-- EN: Fork entry point. Upstream's main.lua carries exactly ONE line for the whole fork —
--     the source() of this file — so upstream merges only ever touch that line. Everything the
--     fork adds is loaded from here, after upstream's own scripts, so every class it wraps
--     already exists.
-- UA: Точка входу форку. У main.lua оригіналу — рівно ОДИН рядок для всього форку: source()
--     цього файлу, тож злиття з оригіналом торкаються лише його. Усе, що додає форк,
--     завантажується звідси після скриптів оригіналу.
local modDirectory = g_currentModDirectory

-- EN: Training mode. Order is logical rather than required: these modules reference one
--     another only from inside functions.
-- UA: Режим навчання. Порядок логічний, а не обов'язковий — модулі звертаються один до одного
--     лише всередині функцій.
source(modDirectory .. "src/training/TrainingMode.lua")
source(modDirectory .. "src/training/SignalConditioner.lua")
source(modDirectory .. "src/training/TelemetryProvider.lua")
source(modDirectory .. "src/training/TrainingInput.lua")
source(modDirectory .. "src/hud/CornerPostHUD.lua")

-- EN: Must come last: it wraps classes defined by upstream and by the modules above.
-- UA: Має бути останнім: обгортає класи оригіналу та модулів вище.
source(modDirectory .. "src/fork/TrainingBridge.lua")
