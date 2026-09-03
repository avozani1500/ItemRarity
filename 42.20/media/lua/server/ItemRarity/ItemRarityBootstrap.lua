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
        elseif module == "ItemRarity" and command == "foodRuntimeAudit" then
            require "ItemRarity/Diagnostics/ClothingMechanicalValueReport"
            if ItemRarityFoodRuntimeAudit and ItemRarityFoodRuntimeAudit.write then
                ItemRarityFoodRuntimeAudit.write(ItemRarityScanner.results)
            end
        elseif module == "ItemRarity" and command == "lightFireAudit" then
            require "ItemRarity/Diagnostics/LightFireAudit"
            if ItemRarityLightFireAudit and ItemRarityLightFireAudit.write then
                ItemRarityLightFireAudit.write(ItemRarityScanner.results)
            end
        elseif module == "ItemRarity" and command == "firearmAudit" then
            ItemRarityUtils.info("FIREARM audit request received")
            local ok, result = pcall(function()
                require "ItemRarity/Diagnostics/FirearmAudit"
                if ItemRarityFirearmAudit and ItemRarityFirearmAudit.write then
                    return ItemRarityFirearmAudit.write(ItemRarityScanner.results)
                end
                return false
            end)
            if not ok then
                ItemRarityUtils.warn("FIREARM audit failed: " .. tostring(result))
            elseif not result then
                ItemRarityUtils.warn("FIREARM audit did not produce a report")
            end
        elseif module == "ItemRarity" and command == "reloadRuntimePipeline" then
            -- Deliberately fixed, small server-side reload path for normal
            -- development.  It does not load any diagnostics and therefore
            -- cannot trigger the historical Clothing report workload.
            if reloadLuaFile and ItemRarityScanner and not ItemRarityScanner.isScanning then
                local files = {
                    "media/lua/shared/ItemRarity/RarityConfig.lua",
                    "media/lua/server/ItemRarity/UtilityCalculator.lua",
                    "media/lua/server/ItemRarity/RarityRegistryPublisher.lua",
                }
                for _, path in ipairs(files) do reloadLuaFile(path) end
                ItemRarityUtils.info("Server runtime pipeline reloaded (lightweight)")
                ItemRarityScanner.rescan("lightweight runtime reload")
            else
                ItemRarityUtils.warn("Runtime pipeline reload skipped while scanner is busy or unavailable")
            end
        elseif module == "ItemRarity" and command == "reloadDiagnostic" then
            -- The debug console is client-side, but report writers run on the
            -- host.  Restrict server-side reload to an explicit allow-list;
            -- this supports fast diagnostic iteration without turning the
            -- client command channel into an arbitrary file loader.
            local files = {
                clothingMechanicalValue = "media/lua/server/ItemRarity/Diagnostics/ClothingMechanicalValueReport.lua",
                foodRuntimeAudit = "media/lua/server/ItemRarity/Diagnostics/ClothingMechanicalValueReport.lua",
                clothingCostCalibration = "media/lua/server/ItemRarity/Diagnostics/ClothingCostCalibration.lua",
                firearmAudit = "media/lua/server/ItemRarity/Diagnostics/FirearmAudit.lua",
            }
            local key = args and tostring(args.key or "") or ""
            local path = files[key]
            if path and reloadLuaFile then
                reloadLuaFile(path)
                ItemRarityUtils.info("Server diagnostic reloaded: " .. key)
                if key == "firearmAudit" then
                    if ItemRarityFirearmAudit and ItemRarityFirearmAudit.write then
                        ItemRarityFirearmAudit.write(ItemRarityScanner.results)
                    else
                        ItemRarityUtils.warn("FIREARM audit did not expose a writer after reload")
                    end
                end
            elseif not path then
                ItemRarityUtils.warn("Rejected unknown server diagnostic reload request: " .. key)
            end
        end
    end)
end

ItemRarityUtils.info("Waiting for final distribution merge before scanning.")
