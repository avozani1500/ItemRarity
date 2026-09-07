if isServer() then return end

require "ISUI/ISInventoryPane"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"
require "ItemRarity/RarityUIOptions"

-- Build 42 does not provide an inventory-name color event. This is deliberately
-- smaller than a UI replacement: it wraps only renderdetails() and swaps the
-- color argument of name draw calls during that one render pass.
ItemRarityInventoryNames = ItemRarityInventoryNames or {}
-- Weak keys let closed inventory/container panes disappear without this
-- presentation cache keeping a UI instance alive.
ItemRarityInventoryNames.paneCaches = ItemRarityInventoryNames.paneCaches
    or setmetatable({}, { __mode = "k" })
ItemRarityInventoryNames.registryGeneration = ItemRarityInventoryNames.registryGeneration or 0

local function isVanillaErrorRed(r, g, b)
    return r and g and b and r >= 0.6 and g <= 0.05 and b <= 0.05
end

local function getItemName(item, player)
    if not item or type(item.getName) ~= "function" then return nil end
    local ok, name = pcall(function() return item:getName(player) end)
    return ok and name or nil
end

local function addNameColor(labels, label, color)
    if not label or not color then return end
    local current = labels[label]
    if current == nil then
        labels[label] = color
    elseif current ~= color then
        -- Two types with the same visible name but different tiers must stay
        -- vanilla, rather than receiving a potentially incorrect color.
        labels[label] = false
    end
end

local function buildLabelColors(pane)
    local labels = {}
    local player = getSpecificPlayer and getSpecificPlayer(pane.player) or nil
    for _, stack in ipairs(pane.itemslist or {}) do
        local stackCount = stack.count or 0
        for _, item in ipairs(stack.items or {}) do
            local rarity, visualTier = ItemRarityPresentation.getItemRarity(item)
            local visual = ItemRarityPresentation.getRarityVisual(visualTier)
            if visual and (visualTier ~= "COMMON" or not ItemRarityUIOptions.isEnabled("commonVanillaColor")) then
                local name = getItemName(item, player)
                addNameColor(labels, name, visual.color)
                if stackCount > 2 and name then
                    addNameColor(labels, name .. " (" .. (stackCount - 1) .. ")", visual.color)
                end
            end
        end
    end
    return labels
end

local function registryRevision()
    -- The client registry loader already performs this same inexpensive
    -- revision check. Keep the numeric revision in the cache key as well as
    -- the registry table identity, so a republish always invalidates every
    -- pane even if two revisions happen to carry equivalent entries.
    if not ModData or not ModData.getOrCreate or not ItemRarityConfig.registryModDataKey then return 0 end
    local data = ModData.getOrCreate(ItemRarityConfig.registryModDataKey)
    return type(data) == "table" and (tonumber(data.revision) or 0) or 0
end

local function paneListToken(pane)
    local list = pane.itemslist
    local first = list and list[1] or nil
    local last = list and list[#list] or nil
    -- refreshContainer() creates a new itemslist table and increments this
    -- counter for every ordinary content/sort/container refresh. The extra
    -- endpoints cover UI variants that replace a list without a counter bump,
    -- while avoiding a per-frame walk through stacks or InventoryItems.
    return {
        list = list,
        refresh = pane.refreshContainerCount or 0,
        size = list and #list or 0,
        first = first,
        last = last,
        firstName = first and first.name or nil,
        lastName = last and last.name or nil,
        firstCount = first and first.count or nil,
        lastCount = last and last.count or nil,
    }
end

local function samePaneListToken(a, b)
    return a and b
        and a.list == b.list
        and a.refresh == b.refresh
        and a.size == b.size
        and a.first == b.first
        and a.last == b.last
        and a.firstName == b.firstName
        and a.lastName == b.lastName
        and a.firstCount == b.firstCount
        and a.lastCount == b.lastCount
end

local function itemIdentity(item)
    if not item then return "nil" end
    if type(item.getID) == "function" then
        local ok, id = pcall(function() return item:getID() end)
        if ok and id ~= nil then return tostring(id) end
    end
    -- The fallback is only a string; it never keeps the Java InventoryItem.
    return tostring(item)
end

local function contentSignature(pane)
    local parts = {}
    for stackIndex, stack in ipairs(pane.itemslist or {}) do
        parts[#parts + 1] = table.concat({
            tostring(stackIndex),
            stack.name or "",
            tostring(stack.count or 0),
            tostring(#(stack.items or {})),
        }, ":")
        for _, item in ipairs(stack.items or {}) do
            local fullType = ""
            if item and type(item.getFullType) == "function" then
                local ok, value = pcall(function() return item:getFullType() end)
                if ok and value then fullType = value end
            end
            parts[#parts + 1] = itemIdentity(item) .. "@" .. fullType
        end
        parts[#parts + 1] = ";"
    end
    return table.concat(parts, "|")
end

local function getPaneLabelColors(pane)
    local registryChanged = ItemRarity.refreshRegistry and ItemRarity.refreshRegistry()
    if registryChanged then
        -- Only the first visible pane sees refreshRegistry() return true after
        -- a publish. A shared generation makes every pane invalidate on its
        -- next render, including when ModData retains table identity.
        ItemRarityInventoryNames.registryGeneration = ItemRarityInventoryNames.registryGeneration + 1
    end

    local cache = ItemRarityInventoryNames.paneCaches[pane]
    if not cache then
        cache = { rebuilds = 0, hits = 0 }
        ItemRarityInventoryNames.paneCaches[pane] = cache
    end

    local token = paneListToken(pane)
    local revision = tonumber(ItemRarity.clientRegistryRevision) or registryRevision()
    local inventoryToken = tostring(pane.inventory)
    local parentToken = tostring(pane.parent)
    local sameContext = cache.labels
        and cache.inventoryToken == inventoryToken
        and cache.parentToken == parentToken
        and cache.registry == ItemRarity.registry
        and cache.registryRevision == revision
        and cache.registryGeneration == ItemRarityInventoryNames.registryGeneration
        and cache.presentationGeneration == ItemRarityUIOptions.getGeneration()
    if sameContext and samePaneListToken(cache.listToken, token) then
        cache.hits = cache.hits + 1
        return cache.labels
    end

    -- Vanilla may rebuild `itemslist` for a bookkeeping refresh even when the
    -- visible content and order are identical. Only in that case do we walk
    -- the refreshed list to prove equality; normal renders still touch none
    -- of the stacks/items.
    local signature = contentSignature(pane)
    if sameContext and cache.contentSignature == signature then
        cache.listToken = token
        cache.hits = cache.hits + 1
        return cache.labels
    end

    -- Labels and colors are the only cached values. No InventoryItem or stack
    -- reference survives the build, so closing/reopening a container cannot
    -- retain an invalid item through this cache.
    cache.labels = buildLabelColors(pane)
    cache.inventoryToken = inventoryToken
    cache.parentToken = parentToken
    cache.registry = ItemRarity.registry
    cache.registryRevision = revision
    cache.registryGeneration = ItemRarityInventoryNames.registryGeneration
    cache.presentationGeneration = ItemRarityUIOptions.getGeneration()
    cache.listToken = token
    cache.contentSignature = signature
    cache.rebuilds = cache.rebuilds + 1
    return cache.labels
end

-- Development-only, read-only counters for measuring real redraw behavior.
-- Calling this does not render, rescan, or mutate the registry.
function ItemRarityInventoryNames.getCacheStats()
    local total = { panes = 0, rebuilds = 0, hits = 0 }
    for _, cache in pairs(ItemRarityInventoryNames.paneCaches) do
        total.panes = total.panes + 1
        total.rebuilds = total.rebuilds + (cache.rebuilds or 0)
        total.hits = total.hits + (cache.hits or 0)
    end
    return total
end

function ItemRarityInventoryNames.resetCacheStats()
    -- A deterministic measurement starts with cold caches. This is exposed
    -- only for manual profiling and does not touch item or registry state.
    ItemRarityInventoryNames.paneCaches = setmetatable({}, { __mode = "k" })
end

function ItemRarityInventoryNames.resetCacheCounters()
    for _, cache in pairs(ItemRarityInventoryNames.paneCaches) do
        cache.rebuilds, cache.hits = 0, 0
    end
end

local function patchInventoryPane(class)
    if type(class) ~= "table" then return end
    local originalRenderDetails = class.renderdetails
    if type(originalRenderDetails) ~= "function" then return end
    if originalRenderDetails == class.ItemRarityNameColorsWrapper then return end

    local wrapper = function(self, doDragged)
        if not ItemRarityUIOptions.isEnabled("colorInventoryNames") then
            return originalRenderDetails(self, doDragged)
        end
        local originalDrawText = self.drawText
        -- renderdetails() may refresh the pane before it draws any row. Build
        -- lazily on the first name-column draw, after that native refresh, so
        -- an add/remove never uses the previous list for even one frame.
        local labels = nil

        -- This temporary instance method exists only while the native list is
        -- rendering. It preserves all layout, selection, clipping, and Clean
        -- UI behavior while changing names in the Item column alone.
        self.drawText = function(pane, value, x, y, r, g, b, a, font)
            local isNameColumn = x and pane.column2 and pane.column3
                and x >= pane.column2 and x < pane.column3
            if isNameColumn and not labels then
                labels = getPaneLabelColors(pane)
            end
            local color = labels and labels[value] or nil
            if color and isNameColumn and not isVanillaErrorRed(r, g, b) then
                return originalDrawText(pane, value, x, y, color.r, color.g, color.b, a, font)
            end
            return originalDrawText(pane, value, x, y, r, g, b, a, font)
        end

        local ok, result = pcall(originalRenderDetails, self, doDragged)
        self.drawText = originalDrawText
        if not ok then error(result) end
        return result
    end
    class.ItemRarityNameColorsWrapper = wrapper
    class.renderdetails = wrapper
end

local function patchAvailableInventoryPanes()
    -- The first name is vanilla. The other two are Clean UI's public class
    -- references when its selectable inventory modes have been loaded.
    patchInventoryPane(ISInventoryPane)
    patchInventoryPane(CleanUI_Vanilla_ISInventoryPane)
    patchInventoryPane(CleanUI_Clean_ISInventoryPane)
end

patchAvailableInventoryPanes()
if Events and Events.OnGameStart then Events.OnGameStart.Add(patchAvailableInventoryPanes) end
