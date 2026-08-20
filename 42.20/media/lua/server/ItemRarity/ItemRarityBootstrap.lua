require "ItemRarity/RarityUtils"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityScanner"

ItemRarityUtils.info("Loaded experimental loot scanner.")
local postDistributionMergeSeen = false

local function scanWhenReady(source)
    if ItemRarityScanner.hasScanned then
        return
    end

    if type(ProceduralDistributions) ~= "table" or type(ProceduralDistributions.list) ~= "table" then
        ItemRarityUtils.debug("Scan deferred (" .. source .. "): ProceduralDistributions is not ready.")
        return
    end

    if type(SuburbsDistributions) ~= "table" then
        ItemRarityUtils.debug("Scan deferred (" .. source .. "): SuburbsDistributions is not ready.")
        return
    end

    ItemRarityUtils.info("Starting experimental loot scan (" .. source .. ").")
    ItemRarityScanner.scan(source)
end

-- Third-party loot mods commonly register their mutations on
-- OnPreDistributionMerge.  Do not scan at script load: doing so observes the
-- unmodified vanilla tables.  OnPostDistributionMerge is the first point at
-- which the merged final tables are expected to be available.
if Events and Events.OnPostDistributionMerge then
    Events.OnPostDistributionMerge.Add(function()
        postDistributionMergeSeen = true
        ItemRarityScanner.setDistributionMergeReady("OnPostDistributionMerge")
        scanWhenReady("OnPostDistributionMerge")
    end)
else
    ItemRarityUtils.warn("OnPostDistributionMerge is unavailable; using the startup fallback.")
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(function()
        if not postDistributionMergeSeen then
            scanWhenReady("OnGameStart fallback")
        end
    end)
end

-- Allows the shared ItemRarity.rescan() API to be issued from a client-side
-- debug console. The host remains the sole owner of loot tables and registry.
if Events and Events.OnClientCommand then
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module == "ItemRarity" and command == "rescan" then
            ItemRarityScanner.rescan("client console request")
        elseif module == "ItemRarity" and command == "snapshot" then
            require "ItemRarity/Diagnostics/RegistrySnapshot"
            if ItemRarityRegistrySnapshot and ItemRarityRegistrySnapshot.write then
                ItemRarityRegistrySnapshot.write(args and args.label or "CURRENT")
            end
        elseif module == "ItemRarity" and command == "clothingCostCalibration" then
            require "ItemRarity/Diagnostics/ClothingCostCalibration"
            if ItemRarityClothingCostCalibration and ItemRarityClothingCostCalibration.write then
                ItemRarityClothingCostCalibration.write(ItemRarityScanner.results)
            end
        elseif module == "ItemRarity" and command == "clothingMechanicalValue" then
            require "ItemRarity/Diagnostics/ClothingMechanicalValueReport"
            if ItemRarityClothingMechanicalValueReport and ItemRarityClothingMechanicalValueReport.write then
                ItemRarityClothingMechanicalValueReport.write(ItemRarityScanner.results)
            end
        elseif module == "ItemRarity" and command == "reloadDiagnostic" then
            -- The debug console is client-side, but report writers run on the
            -- host.  Restrict server-side reload to an explicit allow-list;
            -- this supports fast diagnostic iteration without turning the
            -- client command channel into an arbitrary file loader.
            local files = {
                clothingMechanicalValue = "media/lua/server/ItemRarity/Diagnostics/ClothingMechanicalValueReport.lua",
                clothingCostCalibration = "media/lua/server/ItemRarity/Diagnostics/ClothingCostCalibration.lua",
            }
            local key = args and tostring(args.key or "") or ""
            local path = files[key]
            if path and reloadLuaFile then
                reloadLuaFile(path)
                ItemRarityUtils.info("Server diagnostic reloaded: " .. key)
            elseif not path then
                ItemRarityUtils.warn("Rejected unknown server diagnostic reload request: " .. key)
            end
        end
    end)
end

ItemRarityUtils.info("Waiting for final distribution merge before scanning.")
