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

-- Reloads an explicitly permitted server-side diagnostic writer.  Normal
-- ItemRarity runtime files remain intentionally outside this API; changing
-- active pipeline code still requires the normal controlled validation flow.
function ItemRarity.reloadDiagnostic(key)
    local allowed = { clothingMechanicalValue=true, clothingCostCalibration=true }
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
