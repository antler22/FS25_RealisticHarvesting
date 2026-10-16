-- EN: Fork defaults that differ from upstream's, applied from outside so upstream's files stay
--     unedited.
--
--     Target engine load: 95 %.
--     The throughput anchors in cropThroughput.xml are PEAK figures (100 % engine load). The speed
--     controller holds the machine at the per-machine "target engine load" setting, so that setting
--     decides how close to the anchor a machine actually works. Upstream's default is 80 %, which
--     runs every machine about 16 % below the anchors; the fork's default was 95 %.
--
--     Only the DEFAULT changes. The slider (70-100 %) is untouched, saved machine settings and
--     saved crop profiles keep whatever the player set, and a machine whose settings were saved on
--     the fork already carries 95.
--
-- UA: Значення за замовчуванням форку, що відрізняються від оригіналу; застосовуються ззовні.
--     Цільове навантаження двигуна: 95 %. Опорні точки — це ПІКОВІ значення (100 % навантаження),
--     а контур швидкості тримає машину на цільовому навантаженні. Типове значення оригіналу — 80 %,
--     що робить кожну машину повільнішою за опорні точки приблизно на 16 %. Змінюється лише типове
--     значення; повзунок і збережені налаштування не чіпаємо.
ForkDefaults = {}

ForkDefaults.TARGET_ENGINE_LOAD = 95

local orig = RHM_CombineMemory and RHM_CombineMemory.new
if type(orig) ~= "function" then
    Logging.warning("[RHM-fork] Defaults: RHM_CombineMemory.new not found — target load default stays at upstream's")
else
    RHM_CombineMemory.new = function(...)
        local self = orig(...)
        if self and self.currentSettings then
            self.currentSettings.targetEngineLoad = ForkDefaults.TARGET_ENGINE_LOAD
        end
        return self
    end
end
