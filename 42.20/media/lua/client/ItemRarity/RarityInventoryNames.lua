if isServer() then return end

require "ISUI/ISInventoryPane"
require "ItemRarity/RarityAPI"
require "ItemRarity/RarityConfig"
require "ItemRarity/RarityPresentation"

-- Build 42 does not provide an inventory-name color event. This is deliberately
-- smaller than a UI replacement: it wraps only renderdetails() and swaps the
-- color argument of name draw calls during that one render pass.
ItemRarityInventoryNames = ItemRarityInventoryNames or {}

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
    if ItemRarity.refreshRegistry then ItemRarity.refreshRegistry() end
    local labels = {}
    local player = getSpecificPlayer and getSpecificPlayer(pane.player) or nil
    for _, stack in ipairs(pane.itemslist or {}) do
        local stackCount = stack.count or 0
        for _, item in ipairs(stack.items or {}) do
            local rarity, visualTier = ItemRarityPresentation.getItemRarity(item)
            local visual = ItemRarityPresentation.getRarityVisual(visualTier)
            -- COMMON intentionally retains the exact vanilla color.
            if visual and visualTier ~= "COMMON" then
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

local function patchInventoryPane(class)
    if type(class) ~= "table" or class.ItemRarityNameColorsPatched then return end
    local originalRenderDetails = class.renderdetails
    if type(originalRenderDetails) ~= "function" then return end

    class.renderdetails = function(self, doDragged)
        local originalDrawText = self.drawText
        local labels = buildLabelColors(self)

        -- This temporary instance method exists only while the native list is
        -- rendering. It preserves all layout, selection, clipping, and Clean
        -- UI behavior while changing names in the Item column alone.
        self.drawText = function(pane, value, x, y, r, g, b, a, font)
            local color = labels[value]
            local isNameColumn = x and pane.column2 and pane.column3
                and x >= pane.column2 and x < pane.column3
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
    class.ItemRarityNameColorsPatched = true
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
