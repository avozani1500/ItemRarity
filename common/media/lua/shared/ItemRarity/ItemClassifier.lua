require "ItemRarity/RarityUtils"

ItemRarityItemClassifier = ItemRarityItemClassifier or {}

local CATEGORY_BY_DISPLAY_CATEGORY = {
    weapon = "WEAPON",
    weaponcrafted = "WEAPON",
    cookingweapon = "WEAPON",
    materialweapon = "WEAPON",
    householdweapon = "WEAPON",
    junkweapon = "WEAPON",
    sportsweapon = "WEAPON",
    gardeningweapon = "WEAPON",
    instrumentweapon = "WEAPON",
    fishingweapon = "WEAPON",
    animalpartweapon = "WEAPON",
    weaponpart = "WEAPON_PART",
    weaponimprovised = "WEAPON",
    brokenweapon = "WEAPON",
    tool = "TOOL",
    toolweapon = "TOOL",
    gardening = "TOOL",
    camping = "TOOL",
    fishing = "TOOL",
    trapping = "TOOL",
    paint = "TOOL",
    instrument = "TOOL",
    food = "FOOD",
    cooking = "FOOD",
    medical = "MEDICAL",
    firstaid = "MEDICAL",
    wound = "MEDICAL",
    bandage = "MEDICAL",
    clothing = "CLOTHING",
    protectivegear = "CLOTHING",
    container = "CONTAINER",
    bag = "CONTAINER",
    watercontainer = "CONTAINER",
    literature = "LITERATURE",
    skillbook = "LITERATURE",
    reciperesource = "LITERATURE",
    cartography = "LITERATURE",
    electronics = "ELECTRONICS",
    communications = "ELECTRONICS",
    security = "ELECTRONICS",
    vehicle = "VEHICLE_PART",
    vehiclemaintenance = "VEHICLE_PART",
    material = "MATERIAL",
    animalpart = "MATERIAL",
    ammo = "AMMO",
    explosives = "AMMO",
    accessory = "MISC",
    furniture = "MISC",
    memento = "MISC",
    junk = "MISC",
    household = "MISC",
    appearance = "MISC",
    lightsource = "MISC",
    firesource = "MISC",
    water = "MISC",
    sports = "MISC",
    entertainment = "MISC",
    generic = "MISC",
}

local function callMethod(object, name)
    if not object or type(object[name]) ~= "function" then
        return nil
    end

    local ok, result = pcall(function()
        return object[name](object)
    end)
    return ok and result or nil
end

function ItemRarityItemClassifier.getModule(fullType)
    if type(fullType) ~= "string" then
        return "UNKNOWN"
    end
    return string.match(fullType, "^([^.]+)%.") or "UNKNOWN"
end

function ItemRarityItemClassifier.getScriptMetadata(fullType)
    local metadata = {
        module = ItemRarityItemClassifier.getModule(fullType),
        displayCategory = nil,
        scriptType = nil,
    }

    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(fullType) or nil
    if not scriptItem then
        return metadata
    end

    local displayCategory = callMethod(scriptItem, "getDisplayCategory")
    local scriptType = callMethod(scriptItem, "getType")
    metadata.displayCategory = displayCategory and tostring(displayCategory) or nil
    metadata.scriptType = scriptType and tostring(scriptType) or nil
    return metadata
end

function ItemRarityItemClassifier.getFunctionalCategory(fullType)
    local metadata = ItemRarityItemClassifier.getScriptMetadata(fullType)
    local displayCategory = metadata.displayCategory
    if type(displayCategory) == "string" then
        local normalized = string.lower(displayCategory)
        if CATEGORY_BY_DISPLAY_CATEGORY[normalized] then
            return CATEGORY_BY_DISPLAY_CATEGORY[normalized], metadata
        end
    end
    return "UNKNOWN", metadata
end

function ItemRarityItemClassifier.getLootClassification(fullType, itemData)
    if itemData and itemData.occurrences and itemData.occurrences > 0 then
        return "NATURAL_LOOT"
    end

    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(fullType) or nil
    if scriptItem then
        return "NO_LOOT_DATA"
    end
    return "UNKNOWN"
end
