require "ItemRarity/RarityConfig"

-- Public read-only lookup surface. The UI never reaches into scanner state.
ItemRarity = ItemRarity or {}
ItemRarity.registry = ItemRarity.registry or {}
ItemRarity.registryReady = ItemRarity.registryReady or false

function ItemRarity.setRegistry(entries)
    ItemRarity.registry = type(entries) == "table" and entries or {}
    ItemRarity.registryReady = true
end

function ItemRarity.getByFullType(fullType)
    if type(fullType) ~= "string" then return nil end
    return ItemRarity.registry[fullType]
end

function ItemRarity.get(item)
    if not item or type(item.getFullType) ~= "function" then return nil end
    local ok, fullType = pcall(function() return item:getFullType() end)
    if not ok then return nil end
    return ItemRarity.getByFullType(fullType)
end

function ItemRarity.getVisual(tier)
    return ItemRarityConfig.visuals and ItemRarityConfig.visuals[tier] or nil
end

function ItemRarity.getRegistryCount()
    local count = 0
    for _ in pairs(ItemRarity.registry) do count = count + 1 end
    return count
end

-- Server/host console entry point. The scanner owns the implementation so the
-- manual operation cannot diverge from the OnPostDistributionMerge pipeline.
function ItemRarity.rescan()
    if ItemRarityScanner and type(ItemRarityScanner.rescan) == "function" then
        return ItemRarityScanner.rescan("ItemRarity.rescan()")
    end

    -- A client-side debug console does not own server loot tables. Forward its
    -- request to the host; the host then calls the same scanner method above.
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "rescan", {})
        local message = "ItemRarity.rescan() requested from the client; waiting for the host scan."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end

    local message = "ItemRarity.rescan() is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit five-run, aggregate-only dev profiler. The host owns the scanner;
-- a client console uses the same forwarding convention as ItemRarity.rescan.
-- This never runs during ordinary loading or a normal manual rescan.
function ItemRarity.profilePerformance()
    if ItemRarityScanner and type(ItemRarityScanner.rescanForPerformance) == "function" then
        require "ItemRarity/Diagnostics/RuntimePerformanceProfiler"
        if ItemRarityRuntimePerformanceProfiler and ItemRarityRuntimePerformanceProfiler.runFiveScans then
            return ItemRarityRuntimePerformanceProfiler.runFiveScans()
        end
    end
    -- B42 client→server commands take module/command/args. Unlike the older
    -- shared dev helpers, this new profiler must also work from a client-only
    -- debug console, where prepending an IsoPlayer prevents dispatch.
    if sendClientCommand then
        sendClientCommand("ItemRarity", "performanceProfile", {})
        local message = "ItemRarity.profilePerformance() requested from the client; waiting for the host profile."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity.profilePerformance() is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit host-side forensic report for gameplay observations.  It consumes
-- the current scan only and never rescans, republishes, or changes a tier.
function ItemRarity.writeGameplayAnomalyAudit()
    if ItemRarityGameplayAnomalyAudit and type(ItemRarityGameplayAnomalyAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityGameplayAnomalyAudit.write(ItemRarityScanner.results)
    end
    if sendClientCommand then
        sendClientCommand("ItemRarity", "gameplayAnomalyAudit", {})
        local message = "ItemRarity gameplay anomaly audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity gameplay anomaly audit is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Forensic helper: asks the host to serialize the current registry without
-- recalculating it. It mirrors rescan's client→server routing because a
-- client debug console only owns the compact UI registry.
function ItemRarity.writeRegistrySnapshot(label)
    if ItemRarityRegistrySnapshot and type(ItemRarityRegistrySnapshot.write) == "function" then
        return ItemRarityRegistrySnapshot.write(label)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "snapshot", { label = tostring(label or "CURRENT") })
        local message = "ItemRarity.writeRegistrySnapshot() requested from the client; waiting for the host writer."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity.writeRegistrySnapshot() is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Requests a server-side, read-only Clothing cost calibration.  It does not
-- rescan or mutate the active registry; the host merely writes a diagnostic
-- from the already-computed result set.
function ItemRarity.writeClothingCostCalibration()
    if ItemRarityClothingCostCalibration and type(ItemRarityClothingCostCalibration.write) == "function" and ItemRarityScanner then
        return ItemRarityClothingCostCalibration.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "clothingCostCalibration", {})
        local message = "ItemRarity Clothing cost calibration requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Clothing cost calibration is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Read-only absolute-mechanical-value audit for Clothing.  The host writes a
-- simulation from its current result set and never republishes a registry.
function ItemRarity.writeClothingMechanicalValueAudit()
    if ItemRarityClothingMechanicalValueReport and type(ItemRarityClothingMechanicalValueReport.write) == "function" and ItemRarityScanner then
        return ItemRarityClothingMechanicalValueReport.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "clothingMechanicalValue", {})
        local message = "ItemRarity absolute Clothing mechanical-value audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Clothing mechanical-value audit is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Read-only comparison of active per-slot Clothing components against a
-- lower-body absolute-component simulation. It never rescans or republishes.
function ItemRarity.writeClothingAbsoluteComponentsAudit()
    if ItemRarityClothingAbsoluteComponentsAudit and type(ItemRarityClothingAbsoluteComponentsAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityClothingAbsoluteComponentsAudit.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "clothingAbsoluteComponents", {})
        local message = "ItemRarity Clothing absolute-components audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Clothing absolute-components audit is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit simulation of a structural `base:clothing` classifier fallback.
-- The server clones current rows and writes a report; it never publishes the
-- simulated tiers or changes the active classifier.
function ItemRarity.writeClothingClassifierFallbackSimulation()
    if ItemRarityClothingClassifierFallbackSimulation and type(ItemRarityClothingClassifierFallbackSimulation.write) == "function" and ItemRarityScanner then
        return ItemRarityClothingClassifierFallbackSimulation.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "clothingClassifierFallbackSimulation", {})
        local message = "ItemRarity Clothing classifier fallback simulation requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Clothing classifier fallback simulation is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Read-only Food runtime audit.  It runs server-side and is deliberately
-- separate from FoodUtility, which has not been implemented yet.
function ItemRarity.writeFoodRuntimeAudit()
    if ItemRarityFoodRuntimeAudit and type(ItemRarityFoodRuntimeAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityFoodRuntimeAudit.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "foodRuntimeAudit", {})
        local message = "ItemRarity Food runtime audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Food runtime audit is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Read-only audit of the static ScriptItem bridge against fresh runtime Food
-- instances. It never republishes a registry or recalculates a tier.
function ItemRarity.writeFoodStaticSourceAudit()
    if ItemRarityFoodStaticSourceAudit and type(ItemRarityFoodStaticSourceAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityFoodStaticSourceAudit.write(ItemRarityScanner.results)
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "foodStaticSourceAudit", {})
        local message = "ItemRarity Food static-source audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity Food static-source audit is unavailable: this Lua context cannot reach the host registry."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit host-side feasibility audit for a future ToolUtility. It only
-- reads the current scan/ScriptItem bridge; it cannot rescan or mutate the
-- registry. The client console forwards it to the host just like the other
-- forensic writers.
function ItemRarity.writeToolUtilityAudit()
    if ItemRarityToolUtilityAudit and type(ItemRarityToolUtilityAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityToolUtilityAudit.write(ItemRarityScanner.results)
    end
    if sendClientCommand then
        sendClientCommand("ItemRarity", "toolUtilityAudit", {})
        local message = "ItemRarity ToolUtility feasibility audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity ToolUtility feasibility audit is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit, read-only FirearmUtility audit for the current SHOTGUN family.
-- The client forwards the request to the host; no scan or registry mutation
-- can occur through this diagnostic path.
function ItemRarity.writeShotgunUtilityAudit()
    if ItemRarityShotgunUtilityAudit and type(ItemRarityShotgunUtilityAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityShotgunUtilityAudit.write(ItemRarityScanner.results)
    end
    if sendClientCommand then
        sendClientCommand("ItemRarity", "shotgunUtilityAudit", {})
        local message = "ItemRarity SHOTGUN Utility audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity SHOTGUN Utility audit is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit coverage audit for firearms that exist in ScriptManager but may be
-- absent from final loot distributions. It is diagnostic-only: no scan,
-- candidate, Utility, registry or tier state is changed.
function ItemRarity.writeFirearmCoverageAudit()
    if ItemRarityFirearmCoverageAudit and type(ItemRarityFirearmCoverageAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityFirearmCoverageAudit.write(ItemRarityScanner.results)
    end
    if sendClientCommand then
        sendClientCommand("ItemRarity", "firearmCoverageAudit", {})
        local message = "ItemRarity firearm coverage audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity firearm coverage audit is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Explicit global coverage simulation. It only calculates a temporary
-- ScriptManager shadow universe, never scans loot tables or republishes data.
function ItemRarity.writeScriptItemCoverageAudit()
    if ItemRarityScriptItemCoverageAudit and type(ItemRarityScriptItemCoverageAudit.write) == "function" and ItemRarityScanner then
        return ItemRarityScriptItemCoverageAudit.write(ItemRarityScanner.results)
    end
    if sendClientCommand then
        sendClientCommand("ItemRarity", "scriptItemCoverageAudit", {})
        local message = "ItemRarity global ScriptItem coverage audit requested from the client; waiting for the host report."
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity global ScriptItem coverage audit is unavailable: this Lua context cannot reach the host scanner."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end

-- Reloads an explicitly permitted server-side diagnostic writer.  Normal
-- ItemRarity runtime files remain intentionally outside this API; changing
-- active pipeline code still requires the normal controlled validation flow.
function ItemRarity.reloadDiagnostic(key)
    local allowed = { clothingMechanicalValue=true, clothingAbsoluteComponents=true, clothingClassifierFallback=true, clothingCostCalibration=true, foodRuntimeAudit=true, foodStaticSourceAudit=true }
    if not allowed[key] then
        local message = "ItemRarity.reloadDiagnostic() rejected an unknown diagnostic key."
        if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
        return nil, message
    end
    local player = getSpecificPlayer and getSpecificPlayer(0) or (getPlayer and getPlayer() or nil)
    if sendClientCommand and player then
        sendClientCommand(player, "ItemRarity", "reloadDiagnostic", { key=key })
        local message = "ItemRarity server diagnostic reload requested: " .. key
        if ItemRarityUtils and ItemRarityUtils.info then ItemRarityUtils.info(message) else print(message) end
        return true, message
    end
    local message = "ItemRarity.reloadDiagnostic() cannot reach the host."
    if ItemRarityUtils and ItemRarityUtils.warn then ItemRarityUtils.warn(message) else print(message) end
    return nil, message
end
