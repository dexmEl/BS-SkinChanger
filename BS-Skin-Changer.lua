local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer
local Assets = ReplicatedStorage:WaitForChild("Assets", 30)
local Weapons = Assets and Assets:WaitForChild("Weapons", 30)
local Skins = Assets and Assets:WaitForChild("Skins", 30)
local WeaponAnimations = Assets and Assets:FindFirstChild("WeaponAnimations")
local WeaponModules = ReplicatedStorage:FindFirstChild("Database")
WeaponModules = WeaponModules and WeaponModules:FindFirstChild("Custom")
WeaponModules = WeaponModules and WeaponModules:FindFirstChild("Weapons")

local STATE_KEY = "__BS_SKIN_CHANGER_STATE"
local TEST_API_KEY = "__BS_SKIN_CHANGER_TEST_API"
local OFF = {
    Parent = 104,
    NameContainer = 112,
    Children = 120,
}
local WEAR_ORDER = {
    "Factory New",
    "Minimal Wear",
    "Field-Tested",
    "Well-Worn",
    "Battle-Scarred",
}
local CONFIG_PATHS = {
    "C:/matcha/BS-Config.lua",
    "BS-Config.lua",
    "workspace/BS-Config.lua",
}

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalize(value)
    return trim(value):lower():gsub("[^%w]", "")
end

local function normalizeTeam(value)
    local key = normalize(value)
    if key == "ct" or key == "counterterrorist" or key == "counterterrorists" then
        return "CT"
    end
    if key == "t" or key == "terrorist" or key == "terrorists" then
        return "T"
    end
    return nil
end

local function parseConfig(text)
    local parsed = { CT = {}, T = {} }
    local indexes = { CT = {}, T = {} }
    local errors = {}
    local section = nil
    local lineNumber = 0

    text = tostring(text or "")
    if text:sub(1, 3) == string.char(239, 187, 191) then
        text = text:sub(4)
    end

    for rawLine in (text .. "\n"):gmatch("(.-)\n") do
        lineNumber = lineNumber + 1
        local line = rawLine:gsub("\r", "")
        line = line:gsub("%s+%-%-.*$", "")
        line = trim(line)

        if line ~= "" and line:sub(1, 1) ~= "#" and line:sub(1, 2) ~= "--" then
            local header = line:match("^(.-)%s*:%s*$")
            if header then
                section = normalizeTeam(header)
                if not section then
                    errors[#errors + 1] = "line " .. lineNumber .. ": unknown team header '" .. header .. "'"
                end
            else
                local equals = line:find("=", 1, true)
                if not section then
                    errors[#errors + 1] = "line " .. lineNumber .. ": entry appears before a team header: " .. line
                elseif not equals then
                    errors[#errors + 1] = "line " .. lineNumber .. ": malformed entry: " .. line
                else
                    local item = trim(line:sub(1, equals - 1))
                    local skin = trim(line:sub(equals + 1))
                    if item == "" or skin == "" then
                        errors[#errors + 1] = "line " .. lineNumber .. ": item and skin must both be present"
                    else
                        local itemKey = item:lower()
                        local existing = indexes[section][itemKey]
                        local entry = { item = item, skin = skin, line = lineNumber }
                        if existing then
                            parsed[section][existing] = entry
                        else
                            parsed[section][#parsed[section] + 1] = entry
                            indexes[section][itemKey] = #parsed[section]
                        end
                    end
                end
            end
        end
    end

    return parsed, errors
end

local function findChildInsensitive(parent, wanted)
    if not parent then
        return nil
    end
    local direct = parent:FindFirstChild(wanted)
    if direct then
        return direct
    end
    local wantedLower = trim(wanted):lower()
    local wantedNormalized = normalize(wanted)
    for _, child in ipairs(parent:GetChildren()) do
        if child.Name:lower() == wantedLower or normalize(child.Name) == wantedNormalized then
            return child
        end
    end
    return nil
end

local function resolveSkinFolder(itemName, requestedSkin)
    local weaponSkins = findChildInsensitive(Skins, itemName)
    if not weaponSkins then
        return nil, "skin catalog not found for " .. itemName
    end

    local exact = findChildInsensitive(weaponSkins, requestedSkin)
    if exact then
        return exact
    end

    local lowered = trim(requestedSkin):lower()
    local base, number = lowered:match("^(.-)%s+phase%s*(%d+)$")
    if not base then
        base, number = lowered:match("^(.-)%s+pattern%s*(%d+)$")
    end
    if base and number then
        local patternName = normalize(base)
        for _, child in ipairs(weaponSkins:GetChildren()) do
            local childLower = child.Name:lower()
            local childBase, childNumber = childLower:match("^(.-)_pattern_(%d+)$")
            if childBase and normalize(childBase) == patternName and childNumber == number then
                return child
            end
        end
    end

    return nil, "skin '" .. requestedSkin .. "' not found for " .. itemName
end

local function itemClass(itemName)
    local weaponFolder = findChildInsensitive(Weapons, itemName)
    if weaponFolder and weaponFolder:FindFirstChild("Left Arm") and weaponFolder:FindFirstChild("Right Arm") then
        return "Glove"
    end

    local module = findChildInsensitive(WeaponModules, itemName)
    if module and typeof(decompile) == "function" then
        local ok, source = pcall(decompile, module)
        if ok and type(source) == "string" then
            local class = source:match('%["Class"%]%s*=%s*"([^"]+)"')
                or source:match('Class%s*=%s*"([^"]+)"')
            if class == "Melee" or class == "Glove" or class == "Weapon" then
                return class
            end
        end
    end

    local key = normalize(itemName)
    if key:find("knife", 1, true)
        or key == "karambit"
        or key:find("bayonet", 1, true)
        or key:find("dagger", 1, true)
        or key:find("kukri", 1, true) then
        return "Melee"
    end
    return "Weapon"
end

local function selectWear(modeFolder)
    if not modeFolder then
        return nil
    end
    for _, wearName in ipairs(WEAR_ORDER) do
        local wear = modeFolder:FindFirstChild(wearName)
        if wear then
            return wear
        end
    end
    local children = modeFolder:GetChildren()
    return children[1]
end

local function buildTeamJobs(teamName, parsed)
    local team = normalizeTeam(teamName)
    local errors = {}
    local jobs = {}
    if not team then
        return jobs, { "unknown active team: " .. tostring(teamName) }
    end

    local entries = parsed and parsed[team] or nil
    if type(entries) ~= "table" then
        return jobs, { "no configuration section for " .. team }
    end

    for _, entry in ipairs(entries) do
        local kind = itemClass(entry.item)
        local sourceName = entry.item
        if kind == "Melee" then
            sourceName = team == "CT" and "CT Knife" or "T Knife"
        elseif kind == "Glove" then
            sourceName = team == "CT" and "CT Glove" or "T Glove"
        end

        local sourceWeapon = findChildInsensitive(Weapons, sourceName)
        local targetWeapon = findChildInsensitive(Weapons, entry.item)
        local sourceSkins = findChildInsensitive(Skins, sourceName)
        local targetSkin, skinError = resolveSkinFolder(entry.item, entry.skin)

        local problem = nil
        if not sourceWeapon then
            problem = "base asset '" .. sourceName .. "' was not found"
        elseif not targetWeapon then
            problem = "weapon asset '" .. entry.item .. "' was not found"
        elseif not sourceSkins then
            problem = "skin catalog was not found for " .. sourceName
        elseif not targetSkin then
            problem = skinError
        else
            for _, modeName in ipairs({ "Camera", "Character" }) do
                local targetMode = targetSkin:FindFirstChild(modeName)
                if not selectWear(targetMode) then
                    problem = entry.item .. " " .. entry.skin .. " has no " .. modeName .. " wear template"
                    break
                end
            end
        end

        if problem then
            errors[#errors + 1] = "line " .. tostring(entry.line or "?") .. ": " .. problem
        else
            jobs[#jobs + 1] = {
                item = entry.item,
                skin = entry.skin,
                kind = kind,
                source = sourceName,
                sourceWeapon = sourceWeapon,
                targetWeapon = targetWeapon,
                sourceSkins = sourceSkins,
                targetSkin = targetSkin,
                targetSkinName = targetSkin.Name,
                sourceAnimations = WeaponAnimations and findChildInsensitive(WeaponAnimations, sourceName),
                targetAnimations = WeaponAnimations and findChildInsensitive(WeaponAnimations, entry.item),
            }
        end
    end

    return jobs, errors
end

local function buildActiveJobs(teamName, parsed)
    local team = normalizeTeam(teamName)
    if not team then
        return {}, { "unknown active team: " .. tostring(teamName) }
    end

    local jobs = {}
    local errors = {}
    for _, equipmentTeam in ipairs({ "CT", "T" }) do
        local equipmentJobs, equipmentErrors = buildTeamJobs(equipmentTeam, parsed)
        for _, message in ipairs(equipmentErrors) do
            errors[#errors + 1] = equipmentTeam .. ": " .. message
        end
        for _, job in ipairs(equipmentJobs) do
            if job.kind == "Melee" or job.kind == "Glove" then
                jobs[#jobs + 1] = job
            end
        end
    end

    local activeJobs, activeErrors = buildTeamJobs(team, parsed)
    for _, message in ipairs(activeErrors) do
        errors[#errors + 1] = team .. ": " .. message
    end
    for _, job in ipairs(activeJobs) do
        if job.kind == "Weapon" then
            jobs[#jobs + 1] = job
        end
    end
    return jobs, errors
end

_G[TEST_API_KEY] = {
    ParseConfig = parseConfig,
    NormalizeTeam = normalizeTeam,
    ResolveSkinFolder = resolveSkinFolder,
    ItemClass = itemClass,
    BuildTeamJobs = buildTeamJobs,
    BuildActiveJobs = buildActiveJobs,
}

local function rd(address)
    local ok, value = pcall(memory_read, "uintptr_t", address)
    return ok and value or nil
end

local function wr(address, value)
    local ok = pcall(memory_write, "uintptr_t", address, value)
    return ok
end

local function childBounds(parent)
    if not parent or not parent.Address then
        return nil
    end
    local vector = rd(parent.Address + OFF.Children)
    if not vector or vector == 0 then
        return nil
    end
    return rd(vector), rd(vector + 8)
end

local function findSlot(instance, parent)
    if not instance or not instance.Address or not parent or not parent.Address then
        return nil
    end
    local first, last = childBounds(parent)
    if not first or not last then
        return nil
    end
    for slot = first, last - 16, 16 do
        if rd(slot) == instance.Address then
            return slot
        end
    end
    return nil
end

local function restoreSwaps(restores)
    if type(restores) ~= "table" then
        return 0
    end
    local restored = 0
    for index = #restores, 1, -1 do
        local record = restores[index]
        if record.slot and record.oldAddress then
            wr(record.slot, record.oldAddress)
            if record.oldCtrl then
                wr(record.slot + 8, record.oldCtrl)
            end
            restored = restored + 1
        elseif record.slotA and record.slotB and record.a and record.b then
            wr(record.slotA, record.a)
            if record.ctrlA then
                wr(record.slotA + 8, record.ctrlA)
            end
            wr(record.slotB, record.b)
            if record.ctrlB then
                wr(record.slotB + 8, record.ctrlB)
            end
            if record.nameA then
                wr(record.a + OFF.NameContainer, record.nameA)
            end
            if record.nameB then
                wr(record.b + OFF.NameContainer, record.nameB)
            end
            if record.parentA then
                wr(record.a + OFF.Parent, record.parentA)
            end
            if record.parentB then
                wr(record.b + OFF.Parent, record.parentB)
            end
            restored = restored + 1
        end
    end
    return restored
end

local function prepareAlias(plans, usedSlots, source, target, sourceParent, targetParent, label, errors)
    if not source or not target or not sourceParent or not targetParent then
        errors[#errors + 1] = label .. ": missing instance or parent"
        return
    end
    if source.Address == target.Address then
        return
    end
    local sourceSlot = findSlot(source, sourceParent)
    local targetSlot = findSlot(target, targetParent)
    local sourceParentAddress = rd(source.Address + OFF.Parent)
    local targetParentAddress = rd(target.Address + OFF.Parent)
    if not sourceSlot or not targetSlot
        or sourceParentAddress ~= sourceParent.Address
        or targetParentAddress ~= targetParent.Address then
        errors[#errors + 1] = label .. ": could not validate live child slots"
        return
    end
    if usedSlots[sourceSlot] then
        errors[#errors + 1] = label .. ": source slot conflicts with another configured alias"
        return
    end
    usedSlots[sourceSlot] = true
    plans[#plans + 1] = {
        label = label,
        slot = sourceSlot,
        oldAddress = source.Address,
        oldCtrl = rd(sourceSlot + 8),
        targetAddress = target.Address,
        targetCtrl = rd(targetSlot + 8),
    }
end

local function addSkinAliases(job, plans, usedSlots, errors)
    for _, modeName in ipairs({ "Camera", "Character" }) do
        local targetMode = job.targetSkin:FindFirstChild(modeName)
        local targetWear = selectWear(targetMode)
        for _, sourceSkin in ipairs(job.sourceSkins:GetChildren()) do
            local sourceMode = sourceSkin:FindFirstChild(modeName)
            if sourceMode then
                for _, sourceWear in ipairs(sourceMode:GetChildren()) do
                    prepareAlias(
                        plans,
                        usedSlots,
                        sourceWear,
                        targetWear,
                        sourceMode,
                        targetMode,
                        job.source .. "." .. sourceSkin.Name .. "." .. modeName .. "." .. sourceWear.Name
                            .. " -> " .. job.item .. "." .. job.targetSkinName .. "." .. targetWear.Name,
                        errors
                    )
                end
            end
        end
    end
end

local function addAnimationAliases(job, plans, usedSlots, errors)
    if not job.sourceAnimations or not job.targetAnimations then
        errors[#errors + 1] = job.item .. ": animation folders were not found"
        return
    end
    for _, modeName in ipairs({ "CameraAnimations", "CharacterAnimations" }) do
        local sourceMode = job.sourceAnimations:FindFirstChild(modeName)
        local targetMode = job.targetAnimations:FindFirstChild(modeName)
        if sourceMode and targetMode then
            for _, sourceAnimation in ipairs(sourceMode:GetChildren()) do
                local targetAnimation = targetMode:FindFirstChild(sourceAnimation.Name)
                if targetAnimation then
                    prepareAlias(
                        plans,
                        usedSlots,
                        sourceAnimation,
                        targetAnimation,
                        sourceMode,
                        targetMode,
                        job.source .. "." .. modeName .. "." .. sourceAnimation.Name,
                        errors
                    )
                end
            end
        else
            errors[#errors + 1] = job.item .. ": missing " .. modeName
        end
    end
end

local function buildSwapPlans(jobs)
    local plans = {}
    local usedSlots = {}
    local errors = {}

    for _, job in ipairs(jobs) do
        if job.kind == "Melee" and job.source ~= job.item then
            prepareAlias(plans, usedSlots, job.sourceWeapon:FindFirstChild("Camera"), job.targetWeapon:FindFirstChild("Camera"), job.sourceWeapon, job.targetWeapon, job.source .. ".Camera -> " .. job.item, errors)
            prepareAlias(plans, usedSlots, job.sourceWeapon:FindFirstChild("Character"), job.targetWeapon:FindFirstChild("Character"), job.sourceWeapon, job.targetWeapon, job.source .. ".Character -> " .. job.item, errors)
            addAnimationAliases(job, plans, usedSlots, errors)
        elseif job.kind == "Glove" and job.source ~= job.item then
            prepareAlias(plans, usedSlots, job.sourceWeapon:FindFirstChild("Left Arm"), job.targetWeapon:FindFirstChild("Left Arm"), job.sourceWeapon, job.targetWeapon, job.source .. ".Left Arm -> " .. job.item, errors)
            prepareAlias(plans, usedSlots, job.sourceWeapon:FindFirstChild("Right Arm"), job.targetWeapon:FindFirstChild("Right Arm"), job.sourceWeapon, job.targetWeapon, job.source .. ".Right Arm -> " .. job.item, errors)
        end
        addSkinAliases(job, plans, usedSlots, errors)
    end

    return plans, errors
end

local function applyPlans(plans)
    local applied = {}
    for _, record in ipairs(plans) do
        local okAddress = wr(record.slot, record.targetAddress)
        local okCtrl = not record.targetCtrl or wr(record.slot + 8, record.targetCtrl)
        if not (okAddress and okCtrl) then
            restoreSwaps(applied)
            return nil, "memory write failed at " .. record.label
        end
        applied[#applied + 1] = record
        if rd(record.slot) ~= record.targetAddress then
            restoreSwaps(applied)
            return nil, "verification failed at " .. record.label
        end
    end
    return applied
end

local function loadConfig()
    if typeof(isfile) ~= "function" or typeof(readfile) ~= "function" then
        return nil, nil, "Matcha filesystem functions are unavailable"
    end
    local failures = {}
    for _, path in ipairs(CONFIG_PATHS) do
        local okExists, exists = pcall(isfile, path)
        if okExists and exists then
            local okRead, content = pcall(readfile, path)
            if okRead and type(content) == "string" then
                return content, path
            end
            failures[#failures + 1] = path .. ": " .. tostring(content)
        elseif not okExists then
            failures[#failures + 1] = path .. ": " .. tostring(exists)
        end
    end
    local suffix = #failures > 0 and (" (" .. table.concat(failures, "; ") .. ")") or ""
    return nil, nil, "BS-Config.lua was not found in Matcha's workspace" .. suffix
end

local function reportErrors(prefix, errors)
    for _, message in ipairs(errors or {}) do
        warn("[BS-Skin-Changer] " .. prefix .. ": " .. message)
    end
end

local function run()
    if not Assets or not Weapons or not Skins or not LocalPlayer then
        warn("[BS-Skin-Changer] Bloxstrike assets or LocalPlayer are unavailable")
        return
    end

    local memoryOk = pcall(memory_read, "int", game.Address)
    if not memoryOk then
        warn("[BS-Skin-Changer] Allow Unsafe LuaU is required for reversible asset swaps")
        return
    end

    local previous = _G[STATE_KEY]
    if type(previous) == "table" then
        previous.running = false
        if previous.jobId == game.JobId and previous.assetsAddress == Assets.Address then
            local count = restoreSwaps(previous.restores)
            if count > 0 then
                print("[BS-Skin-Changer] Restored " .. count .. " swaps from the previous run")
            end
        end
    end
    _G[STATE_KEY] = nil

    local configText, configPath, configError = loadConfig()
    if not configText then
        warn("[BS-Skin-Changer] " .. tostring(configError))
        warn("[BS-Skin-Changer] Matcha currently allows readfile only under C:/matcha/workspace; place the file at C:/matcha/workspace/BS-Config.lua")
        return
    end

    local parsed, parseErrors = parseConfig(configText)
    if #parseErrors > 0 then
        reportErrors("config", parseErrors)
        return
    end

    local state = {
        running = true,
        jobId = game.JobId,
        assetsAddress = Assets.Address,
        configPath = configPath,
        parsed = parsed,
        team = nil,
        restores = {},
        jobs = {},
    }
    _G[STATE_KEY] = state

    local function applyTeam(teamName)
        local team = normalizeTeam(teamName)
        if not team then
            return false
        end

        if #state.restores > 0 then
            restoreSwaps(state.restores)
            state.restores = {}
            state.jobs = {}
        end

        local jobs, jobErrors = buildActiveJobs(team, parsed)
        if #jobErrors > 0 then
            reportErrors(team, jobErrors)
            state.team = team
            return false
        end

        local plans, planErrors = buildSwapPlans(jobs)
        if #planErrors > 0 then
            reportErrors(team, planErrors)
            state.team = team
            return false
        end

        local applied, applyError = applyPlans(plans)
        if not applied then
            warn("[BS-Skin-Changer] " .. tostring(applyError))
            state.team = team
            return false
        end

        state.team = team
        state.restores = applied
        state.jobs = jobs
        local labels = {}
        for _, job in ipairs(jobs) do
            labels[#labels + 1] = job.item .. "=" .. job.skin
        end
        print("[BS-Skin-Changer] Applied " .. #jobs .. " selections for active team " .. team .. " using " .. #applied .. " reversible aliases")
        if #labels > 0 then
            print("[BS-Skin-Changer] " .. table.concat(labels, ", "))
        end
        if typeof(notify) == "function" then
            pcall(notify, "Bloxstrike Skin Changer", "Applied " .. #jobs .. " selections. Re-equip the currently held item once to refresh it.", 6)
        end
        return true
    end

    state.applyTeam = applyTeam
    _G.__BS_SKIN_CHANGER_STOP = function()
        local current = _G[STATE_KEY]
        if current ~= state then
            return
        end
        state.running = false
        local restored = restoreSwaps(state.restores)
        state.restores = {}
        _G[STATE_KEY] = nil
        print("[BS-Skin-Changer] Stopped and restored " .. restored .. " swaps")
    end

    local initialTeam = LocalPlayer:GetAttribute("Team")
    if normalizeTeam(initialTeam) then
        applyTeam(initialTeam)
    else
        print("[BS-Skin-Changer] Config loaded from " .. configPath .. "; waiting for a team assignment")
    end

    task.spawn(function()
        while state.running and _G[STATE_KEY] == state do
            local team = normalizeTeam(LocalPlayer:GetAttribute("Team"))
            if team and team ~= state.team then
                applyTeam(team)
            end
            task.wait(0.1)
        end
    end)
end

if _G.__BS_SKIN_CHANGER_TEST_MODE == true then
    print("[BS-Skin-Changer] Test mode ready")
else
    _G[TEST_API_KEY] = nil
    run()
end
