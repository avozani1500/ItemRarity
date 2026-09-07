ItemRarityUtils = ItemRarityUtils or {}

local PREFIX = "[ItemRarity]"

local function log(level, message)
    print(PREFIX .. "[" .. level .. "] " .. tostring(message))
end

function ItemRarityUtils.info(message)
    log("INFO", message)
end

function ItemRarityUtils.warn(message)
    log("WARN", message)
end

function ItemRarityUtils.debug(message)
    log("DEBUG", message)
end

