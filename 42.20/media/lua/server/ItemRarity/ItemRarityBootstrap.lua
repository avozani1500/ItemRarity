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
        end
    end)
end

ItemRarityUtils.info("Waiting for final distribution merge before scanning.")
