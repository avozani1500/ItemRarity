if isServer() then return end

require "ItemRarity/RarityAPI"
require "ItemRarity/RarityUtils"

local lastRevision = nil

local function loadRegistry(force)
    if not ModData or not ModData.getOrCreate then return end
    local data = ModData.getOrCreate(ItemRarityConfig.registryModDataKey)
    if type(data) ~= "table" or type(data.entries) ~= "table" then return end
    local revision = tonumber(data.revision) or 0
    if not force and lastRevision == revision then return false end
    ItemRarity.setRegistry(data.entries)
    lastRevision = revision
    ItemRarityUtils.info("Client registry ready: " .. ItemRarity.getRegistryCount() .. " items (revision " .. revision .. ").")
    return true
end

-- ModData.transmit() updates the global ModData entry. UI rendering invokes
-- this lightweight revision check, so a live registry is adopted without
-- waiting for a new world or a client-only scan.
function ItemRarity.refreshRegistry()
    return loadRegistry(false)
end

if Events and Events.OnInitGlobalModData then Events.OnInitGlobalModData.Add(function() loadRegistry(true) end) end
if Events and Events.OnGameStart then Events.OnGameStart.Add(function() loadRegistry(true) end) end
