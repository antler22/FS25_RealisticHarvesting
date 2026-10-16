-- EN: Fork entry point. Upstream's main.lua carries exactly ONE block for the whole fork - the source() of
--     this file - so upstream merges only ever touch that block. Everything the fork adds is loaded from here,
--     after upstream's own scripts, so every class it wraps already exists.
-- UA: Точка входу форку. У main.lua оригіналу - рівно ОДИН блок для всього форку: source() цього файлу, тож
--     злиття з оригіналом торкаються лише його. Усе, що додає форк, завантажується звідси після скриптів
--     оригіналу.
local modDirectory = g_currentModDirectory

-- EN: First: the installer for hooks on rhm_Combine. The engine re-sources that specialization and replaces
--     the table, so those hooks must be registered here and applied afterwards (see SpecHooks.lua).
-- UA: Спершу: інсталер хуків на rhm_Combine - рушій перезавантажує цю специфікацію і підміняє таблицю.
source(modDirectory .. "src/fork/SpecHooks.lua")

-- EN: Training mode. Order is logical rather than required: these modules reference one another only from
--     inside functions.
-- UA: Режим навчання. Порядок логічний, а не обов'язковий.
source(modDirectory .. "src/training/TrainingMode.lua")
source(modDirectory .. "src/training/SignalConditioner.lua")
source(modDirectory .. "src/training/TelemetryProvider.lua")
source(modDirectory .. "src/training/TrainingInput.lua")
source(modDirectory .. "src/hud/CornerPostHUD.lua")

-- EN: Wraps classes defined by upstream and by the modules above.
-- UA: Обгортає класи оригіналу та модулів вище.
source(modDirectory .. "src/fork/TrainingBridge.lua")

-- EN: Real-throughput overlay: the fork's anchored capacity curves, applied through upstream's own energy
--     model. Needs RHM_LoadCalculator.
-- UA: Накладка реальної продуктивності: криві з опорними точками через модель енергії оригіналу.
source(modDirectory .. "src/fork/RealThroughputConfig.lua")
source(modDirectory .. "src/fork/RealThroughput.lua")

-- EN: The fork's moisture model, replacing upstream's moisture effects (load, loss, speed cap, optimum shift).
--     After RealThroughput so its load factor multiplies the already-anchored specific energy.
-- UA: Модель вологості форку замість ефектів вологості оригіналу. Після RealThroughput.
source(modDirectory .. "src/fork/MoistureModel.lua")

-- EN: Fork defaults that differ from upstream's (target engine load 95 %).
-- UA: Типові значення форку, що відрізняються від оригіналу (цільове навантаження 95 %).
source(modDirectory .. "src/fork/Defaults.lua")

-- EN: The fork's purchasable electronics tiers, replacing upstream's package ladder in the shop and feeding
--     upstream's gates from it. Needs rhm_Combine, the calibration GUI and RHM_Api.
-- UA: Купувані електронні рівні форку: замінюють драбину пакетів оригіналу в магазині та живлять його обмеження.
source(modDirectory .. "src/fork/ElectronicsTiers.lua")

-- EN: Manual working width for forage / pickup headers, with saving and multiplayer sync.
-- UA: Ручна робоча ширина для форажних жаток / підбирачів зі збереженням та синхронізацією.
source(modDirectory .. "src/fork/WorkWidth.lua")

-- EN: Hook rhm_Combine now (covers a build where nothing is re-sourced); SpecHooks hooks it again after the
--     engine registers the specialization and replaces the table.
-- UA: Хукаємо rhm_Combine зараз; SpecHooks зробить це знову після реєстрації специфікації.
ForkSpecHooks.install()
