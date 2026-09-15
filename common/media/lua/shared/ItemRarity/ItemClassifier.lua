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
    -- Accessory is a distinct functional route.  It must not fall through to
    -- generic MISC merely because it is also wearable.
    accessory = "ACCESSORY",
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

local function normalizedString(value)
    if value == nil then
        return nil
    end
    local text = tostring(value)
    if text == "" then
        return nil
    end
    text = string.gsub(text, "^%s*(.-)%s*$", "%1")
    return text ~= "" and string.lower(text) or nil
end

local function bodyLocationSuffix(location)
    local normalized = normalizedString(location)
    if not normalized then
        return nil
    end
    return string.match(normalized, ":([^:]+)$") or normalized
end

local ACCESSORY_DISPLAY_CATEGORIES = {
    clothjew = true,
    clothacc = true,
}

-- These slots have an accessory/cosmetic role even though their ScriptItem
-- type is usually base:clothing.  Keep the matching on a parsed body-location
-- segment so, for example, "underwear" is never mistaken for an ear slot.
local ACCESSORY_BODY_LOCATIONS = {
    eye = true,
    eyes = true,
    lefteye = true,
    righteye = true,
    ear = true,
    ears = true,
    leftear = true,
    rightear = true,
    neck = true,
    necklace = true,
    wrist = true,
    leftwrist = true,
    rightwrist = true,
    finger = true,
    leftfinger = true,
    rightfinger = true,
    belt = true,
    belly = true,
    tail = true,
}

local CLOTHING_DISPLAY_CATEGORIES = {
    clothbody = true,
    clothleg = true,
    clothfeet = true,
    clothunder = true,
    clothhead = true,
    clothmask = true,
}

local CONTAINER_BODY_LOCATIONS = {
    satchel = true,
    backpack = true,
}

local function hasContainerFunction(metadata)
    local capacity = tonumber(metadata.capacity)
    local maxItemSize = tonumber(metadata.maxItemSize)
    return (capacity and capacity > 0)
        or (maxItemSize and maxItemSize > 0)
        or (metadata.acceptItemFunction and metadata.acceptItemFunction ~= "")
        or CONTAINER_BODY_LOCATIONS[bodyLocationSuffix(metadata.bodyLocation)] == true
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
        itemType = nil,
        bodyLocation = nil,
        capacity = nil,
        maxItemSize = nil,
        acceptItemFunction = nil,
    }

    local manager = getScriptManager and getScriptManager() or nil
    local scriptItem = manager and manager:FindItem(fullType) or nil
    if not scriptItem then
        return metadata
    end
    -- Transient scan-only bridge object. LootAnalyzer consumes it immediately
    -- and clears its copy after Utility dispatch; it is never published in
    -- the client registry.
    metadata._scriptItem = scriptItem

    local displayCategory = callMethod(scriptItem, "getDisplayCategory")
    local scriptType = callMethod(scriptItem, "getType")
    local itemType = callMethod(scriptItem, "getItemType")
    local bodyLocation = callMethod(scriptItem, "getBodyLocation")
    local capacity = callMethod(scriptItem, "getCapacity")
    local maxItemSize = callMethod(scriptItem, "getMaxItemSize")
    local acceptItemFunction = callMethod(scriptItem, "getAcceptItemFunction")
    metadata.displayCategory = displayCategory and tostring(displayCategory) or nil
    metadata.scriptType = scriptType and tostring(scriptType) or nil
    metadata.itemType = itemType and tostring(itemType) or nil
    metadata.bodyLocation = bodyLocation and tostring(bodyLocation) or nil
    metadata.capacity = tonumber(capacity)
    metadata.maxItemSize = tonumber(maxItemSize)
    metadata.acceptItemFunction = acceptItemFunction and tostring(acceptItemFunction) or nil
    return metadata
end

function ItemRarityItemClassifier.getFunctionalCategory(fullType)
    local metadata = ItemRarityItemClassifier.getScriptMetadata(fullType)
    local displayCategory = normalizedString(metadata.displayCategory)
    local bodyLocation = bodyLocationSuffix(metadata.bodyLocation)

    -- Existing specific DisplayCategory routes always win.  In particular,
    -- this preserves food, medical, literature, weapon and explicit container
    -- categories before considering wearable fallbacks.
    local mappedCategory = displayCategory and CATEGORY_BY_DISPLAY_CATEGORY[displayCategory] or nil
    if mappedCategory and mappedCategory ~= "CLOTHING" then
        return mappedCategory, metadata
    end

    -- ProtectiveGear is an explicit Clothing route and is intentionally kept
    -- ahead of the wearable fallback taxonomy.
    if displayCategory == "protectivegear" then
        return "CLOTHING", metadata
    end

    -- A wearable container can expose ClothBack/base:clothing at runtime.
    -- Route it by its structural carrying signal before wearable taxonomy.
    if hasContainerFunction(metadata) then
        return "CONTAINER", metadata
    end

    -- Jewellery/accessory display categories and unequivocal accessory body
    -- slots take precedence over the generic base:clothing fallback.
    if ACCESSORY_DISPLAY_CATEGORIES[displayCategory] or ACCESSORY_BODY_LOCATIONS[bodyLocation] then
        return "ACCESSORY", metadata
    end

    -- B42 exposes these runtime DisplayCategory values for ordinary worn
    -- garments.  They are the structural equivalents of the legacy generic
    -- "Clothing" display category.
    if mappedCategory == "CLOTHING"
        or CLOTHING_DISPLAY_CATEGORIES[displayCategory]
        or (displayCategory and string.sub(displayCategory, 1, 5) == "cloth") then
        return "CLOTHING", metadata
    end

    -- Last wearable fallback: only a known clothing ScriptItem that was not
    -- already proven to be a container or accessory reaches this branch.
    local wearableType = normalizedString(metadata.itemType) or normalizedString(metadata.scriptType)
    if wearableType == "base:clothing" then
        return "CLOTHING", metadata
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
