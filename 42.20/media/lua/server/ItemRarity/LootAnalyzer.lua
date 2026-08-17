require "ItemRarity/RarityUtils"
require "ItemRarity/ItemClassifier"

ItemRarityLootAnalyzer = ItemRarityLootAnalyzer or {}
ItemRarityLootAnalyzer.items = {}

local function addUnique(list, set, value)
    if value and not set[value] then
        set[value] = true
        table.insert(list, value)
    end
end

function ItemRarityLootAnalyzer.analyze(rawOccurrences)
    local results = {}
    for _, occurrence in ipairs(rawOccurrences) do
        local data = results[occurrence.fullType]
        if not data then
            local category, metadata = ItemRarityItemClassifier.getFunctionalCategory(occurrence.fullType)
            data = {
                fullType = occurrence.fullType,
                module = metadata.module,
                category = category,
                displayCategory = metadata.displayCategory,
                scriptType = metadata.scriptType,
                occurrences = 0,
                proceduralOccurrences = 0,
                staticOccurrences = 0,
                totalWeight = 0,
                minWeight = nil,
                maxWeight = nil,
                distributions = {},
                distributionSet = {},
                rollsObserved = {},
                rollsSet = {},
                occurrencesData = {},
            }
            results[occurrence.fullType] = data
        end

        data.occurrences = data.occurrences + 1
        data.totalWeight = data.totalWeight + occurrence.weight
        data.minWeight = data.minWeight and math.min(data.minWeight, occurrence.weight) or occurrence.weight
        data.maxWeight = data.maxWeight and math.max(data.maxWeight, occurrence.weight) or occurrence.weight
        if occurrence.distributionType == "procedural" then
            data.proceduralOccurrences = data.proceduralOccurrences + 1
        else
            data.staticOccurrences = data.staticOccurrences + 1
        end
        addUnique(data.distributions, data.distributionSet, occurrence.distribution)
        if occurrence.rolls ~= nil then
            addUnique(data.rollsObserved, data.rollsSet, tostring(occurrence.rolls))
        end
        table.insert(data.occurrencesData, occurrence)
    end

    for _, data in pairs(results) do
        data.distributionCount = #data.distributions
        data.averageWeight = data.totalWeight / data.occurrences
        data.lootClassification = ItemRarityItemClassifier.getLootClassification(data.fullType, data)
    end

    ItemRarityLootAnalyzer.items = results
    return results
end

