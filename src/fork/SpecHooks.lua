-- EN: Installs the fork's hooks on upstream's rhm_Combine specialization at the one moment they survive.
--
--     Why this exists
--     upstream's main.lua sources src/rhm_Combine.lua, whose first line is an unconditional
--     `rhm_Combine = {}`. The file is ALSO listed in modDesc.xml's <specializations>, and when the engine
--     registers a specialization it sources the file again in the mod's environment
--     (mods.lua:998-1005 -> SpecializationManager:addSpecialization, line 97) and then resolves the
--     class from that environment (ClassUtil.getClassObject). So the table the game uses is the one from
--     the SECOND load, and anything installed on the first is discarded. Only specialization files are
--     affected (rhm_Combine, rhm_Cutter); upstream's other classes are sourced once.
--
--     What this does
--     Modules register an installer with ForkSpecHooks.add(). install() runs them against the current
--     rhm_Combine, once per table. It is called when the fork layer loads (harmless; covers the case
--     where nothing is re-sourced) and again right after the engine has registered the rhm_Combine
--     specialization - which is after the second load and before the engine reads the class's functions
--     (registerEventListener, registerOverwrittenFunctions and registerFunctions all happen later, in
--     TypeManager:finalizeTypes). A class replaced a second time is simply hooked afresh.
--
--     Rule for fork code: never wrap rhm_Combine directly at load time; use ForkSpecHooks.add().
--
-- UA: Встановлює хуки форку на специфікацію rhm_Combine в єдиний момент, коли вони виживають.
--     main.lua оригіналу виконує rhm_Combine.lua, що починається з безумовного `rhm_Combine = {}`.
--     Рушій при реєстрації специфікації виконує файл удруге, і грою використовується таблиця з ДРУГОГО
--     завантаження - усе, встановлене на першу, втрачається. Тому хуки реєструються тут і ставляться
--     після реєстрації специфікації, але до того, як рушій прочитає функції класу.
ForkSpecHooks = {}

local installers = {}

-- EN: Register fn() to install hooks on the CURRENT global rhm_Combine. fn must not assume the table
--     it sees is the one it saw last time.
function ForkSpecHooks.add(name, fn)
    installers[#installers + 1] = { name = name, fn = fn }
end

-- EN: Run every installer against the current rhm_Combine, once per table. Returns true if it ran.
function ForkSpecHooks.install()
    local cls = rhm_Combine
    if type(cls) ~= "table" or cls.__forkHooksInstalled then return false end
    cls.__forkHooksInstalled = true
    for _, inst in ipairs(installers) do
        local ok, err = pcall(inst.fn)
        if not ok then
            Logging.warning("[RHM-fork] hook set '%s' failed to install: %s", inst.name, tostring(err))
        end
    end
    return true
end

-- EN: The trigger: after the engine registers upstream's rhm_Combine specialization. The name and class
--     name are mod-prefixed ("<modName>.rhm_Combine") for mod specializations.
if SpecializationManager and type(SpecializationManager.addSpecialization) == "function" then
    SpecializationManager.addSpecialization = Utils.appendedFunction(SpecializationManager.addSpecialization,
        function(self, name, className, filename)
            if tostring(className or name or ""):find("rhm_Combine$") then
                ForkSpecHooks.install()
            end
        end)
else
    Logging.warning("[RHM-fork] SpecHooks: SpecializationManager.addSpecialization not found - " ..
        "rhm_Combine hooks may be lost when the engine re-sources the specialization")
end
