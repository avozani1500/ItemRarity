require "ItemRarity/RarityUtils"

-- Read-only taxonomy and reference-population audit.  No active calculator,
-- FinalRarityTier, registry, config or UI table is modified here.
ItemRarityContainerTaxonomyReport = ItemRarityContainerTaxonomyReport or {}

local TARGETS = {
    "Base.Bag_Schoolbag", "Base.Bag_NormalHikingBag", "Base.Bag_BigHikingBag",
    "Base.Bag_ALICEpack", "Base.Bag_ALICE_BeltSus", "Base.Bag_FannyPackFront",
    "Base.KeyRing", "LB.Bag_LegendaryBackpack",
}

local WEIGHTS = { capacity=.35, weightReduction=.35, emptyWeight=.15, runSpeedModifier=.10, attachments=.05 }
local ORDER = { "capacity", "weightReduction", "emptyWeight", "runSpeedModifier", "attachments" }

local function call(object, method)
    if not object or type(object[method]) ~= "function" then return nil end
    local ok, value = pcall(function() return object[method](object) end)
    return ok and value or nil
end

local function fieldOrGetter(object, getter, field)
    local value = call(object, getter)
    if value ~= nil then return value end
    local ok, direct = pcall(function() return object and object[field] end)
    return ok and direct or nil
end

local function str(object, getter, field)
    local value = fieldOrGetter(object, getter, field)
    -- The B42 bridge exposes some absent enum fields as a Lua closure. That
    -- is not a body/equip location and must not become a fake taxonomy slot.
    if type(value) == "function" then return nil end
    return value == nil and nil or tostring(value)
end

local function num(object, getter, field)
    return tonumber(fieldOrGetter(object, getter, field))
end

local function lower(value) return string.lower(tostring(value or "")) end
local function has(text, fragment) return string.find(lower(text), fragment, 1, true) ~= nil end
local function n(value) return value == nil and "N/A" or string.format("%.2f", tonumber(value) or 0) end
local function moduleOf(fullType) return string.match(tostring(fullType), "^([^.]+)%.") or "UNKNOWN" end

local function scriptFor(fullType)
    local manager = getScriptManager and getScriptManager() or nil
    return manager and manager:FindItem(fullType) or nil
end

local function runtimeFor(script)
    if not script then return nil end
    local ok, item = pcall(function() return script:InstanceItem(nil, false) end)
    return ok and item or nil
end

local function sizeOf(collection)
    if not collection then return 0 end
    local size = call(collection, "size")
    if tonumber(size) then return tonumber(size) end
    return 0
end

local function structural(data)
    local script = scriptFor(data.fullType)
    local runtime = runtimeFor(script)
    local body = str(runtime, "canBeEquipped", "canBeEquipped") or str(runtime, "getBodyLocation", "bodyLocation")
        or str(script, "getBodyLocation", "bodyLocation") or ""
    local equip = str(runtime, "canBeEquipped", "canBeEquipped") or body
    local accept = str(runtime, "getAcceptItemFunction", "acceptItemFunction")
        or str(script, "getAcceptItemFunction", "acceptItemFunction") or ""
    local maxSize = num(runtime, "getMaxItemSize", "maxItemSize") or num(script, "getMaxItemSize", "maxItemSize")
    local attachments = sizeOf(call(runtime, "getAttachmentsProvided"))
    local metrics = data.utilityMetrics or {}
    return {
        script=script, runtime=runtime, body=lower(body), equip=lower(equip), accept=lower(accept), maxSize=maxSize,
        capacity=metrics.capacity, weightReduction=metrics.weightReduction, emptyWeight=metrics.emptyWeight,
        -- The existing B42 bridge may leave this nil. Preserve that fact in
        -- the audit instead of fabricating a zero speed modifier.
        runSpeedModifier=metrics.runSpeedModifier, attachments=attachments,
        rawAttachments=attachments, tags=lower(str(script, "getTags", "tags") or ""),
    }
end

local function taxonomy(s)
    -- Grouping is exclusively structural: accept restriction and equip/body
    -- location. DisplayName, fullType, module and icons never participate.
    if has(s.accept, "keyring") or has(s.tags, "keyring") then return "KEY_CONTAINER" end
    if has(s.body, "fanny") or has(s.equip, "fanny") then return "FANNY_PACK" end
    if has(s.body, "ammo") or has(s.equip, "ammo") then return "TORSO_AMMO" end
    if has(s.body, "webbing") or has(s.equip, "webbing") then return "TORSO_GENERAL" end
    if has(s.body, "satchel") or has(s.equip, "satchel") then return "TORSO_GENERAL" end
    if has(s.body, "belt") or has(s.equip, "belt") or has(s.body, "holster") or has(s.equip, "holster") then return "BELT_OR_ATTACHMENT" end
    if has(s.body, "back") or has(s.equip, "back") then return "BACK" end
    if s.capacity and s.capacity > 0 and s.maxSize and s.maxSize > 0 then return "SPECIALIZED_CASE" end
    if s.capacity and s.capacity > 0 then return "HANDHELD_GENERAL" end
    return "TRIVIAL_OR_SPECIAL"
end

local function profile(row)
    local m = row.metrics
    local values = {}
    for _, key in ipairs(ORDER) do table.insert(values, m[key] == nil and "-" or string.format("%.5f", m[key])) end
    return table.concat(values, ":")
end

local function sorted(values)
    table.sort(values)
    return values
end

local function quantile(values, percent)
    if #values == 0 then return nil end
    local index = 1 + (#values - 1) * (percent / 100)
    local lo, hi = math.floor(index), math.ceil(index)
    if lo == hi then return values[lo] end
    return values[lo] + (values[hi] - values[lo]) * (index - lo)
end

local function unique(values)
    local output, seen = {}, {}
    for _, value in ipairs(values) do if not seen[value] then seen[value]=true; table.insert(output, value) end end
    return sorted(output)
end

local function percentile(values, value, inverted)
    if value == nil or #values == 0 then return nil end
    local first, last
    for i, candidate in ipairs(values) do
        if candidate == value then first=first or i; last=i end
    end
    if not first then return nil end
    local p = #values == 1 and 50 or ((first + last - 2) / (2 * (#values - 1))) * 100
    return inverted and 100 - p or p
end

local function referenceScore(row, references)
    local numer, denom = 0, 0
    for _, key in ipairs(ORDER) do
        local values = {}
        for _, ref in ipairs(references) do if ref.metrics[key] ~= nil then table.insert(values, ref.metrics[key]) end end
        if row.metrics[key] ~= nil and #values > 0 then
            values=sorted(values)
            local low, high = quantile(values, 5), quantile(values, 95)
            local bounded = math.max(low, math.min(high, row.metrics[key]))
            local adjusted = {}
            for _, value in ipairs(values) do table.insert(adjusted, math.max(low, math.min(high, value))) end
            local p = percentile(unique(adjusted), bounded, key == "emptyWeight")
            if p ~= nil then numer=numer+p*WEIGHTS[key]; denom=denom+WEIGHTS[key] end
        end
    end
    return denom > 0 and numer / denom or nil
end

local function setText(set)
    local list = {}
    for value in pairs(set) do table.insert(list, value) end
    table.sort(list)
    return #list == 0 and "N/A" or table.concat(list, ",")
end

local function range(rows, field)
    local min, max
    for _, row in ipairs(rows) do
        local value = row.metrics[field]
        if value ~= nil then min=min and math.min(min,value) or value; max=max and math.max(max,value) or value end
    end
    return n(min) .. ".." .. n(max)
end

function ItemRarityContainerTaxonomyReport.write(results)
    if type(results) ~= "table" or not getFileWriter then return nil end
    local rows, groups = {}, {}
    for _, data in pairs(results) do
        if data.category == "CONTAINER" then
            local s = structural(data)
            local row = { data=data, metrics={capacity=s.capacity,weightReduction=s.weightReduction,emptyWeight=s.emptyWeight,runSpeedModifier=s.runSpeedModifier,attachments=s.attachments}, structural=s }
            row.group=taxonomy(s); row.profile=profile(row)
            table.insert(rows,row); groups[row.group]=groups[row.group] or {}; table.insert(groups[row.group],row)
        end
    end
    table.sort(rows,function(a,b) return a.data.fullType<b.data.fullType end)
    local writer=getFileWriter("ItemRarity_ContainerTaxonomy.txt",true,false)
    if not writer then return nil end
    writer:write("Item Rarity Container taxonomy/reference audit (READ ONLY)\n")
    writer:write("Taxonomy uses only runtime/script structure: AcceptItemFunction, Body/Equip location, capacity and MaxItemSize. Names/fullTypes are report labels only.\n")
    writer:write("Current active ContainerUtility is NOT modified. Runtime bridge may expose RunSpeedModifier as N/A; this is reported as unavailable, never coerced to zero.\n\n")
    writer:write("GROUP | fullTypes | uniqueProfiles | vanilla | modded | body/equip | capacity min..max | weightReduction min..max | emptyWeight min..max | runSpeed min..max | attachment counts | maxItemSize | accept restrictions\n")
    local groupNames={}
    for name in pairs(groups) do table.insert(groupNames,name) end
    table.sort(groupNames)
    for _, name in ipairs(groupNames) do
        local group=groups[name]; local profiles,bodies,accepts,maxSizes={}, {}, {}, {}; local vanilla,modded=0,0
        local attachments={}
        for _, row in ipairs(group) do
            profiles[row.profile]=true; bodies[row.structural.body .. "/" .. row.structural.equip]=true; accepts[row.structural.accept]=true
            maxSizes[tostring(row.structural.maxSize or "N/A")]=true; attachments[tostring(row.metrics.attachments or 0)]=true
            if moduleOf(row.data.fullType)=="Base" then vanilla=vanilla+1 else modded=modded+1 end
        end
        local count=0; for _ in pairs(profiles) do count=count+1 end
        writer:write(string.format("%s | %d | %d | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s\n", name,#group,count,vanilla,modded,setText(bodies),range(group,"capacity"),range(group,"weightReduction"),range(group,"emptyWeight"),range(group,"runSpeedModifier"),setText(attachments),setText(maxSizes),setText(accepts)))
    end
    writer:write("\nREFERENCE POPULATION SIMULATION (diagnostic only)\n")
    writer:write("fullType | proposedGroup | activeGroup | dynamic vanilla+mods score | vanilla-reference score | currentUtility | currentFinalTier | capacity | reduction | weight | run | attachments | maxItemSize | accept\n")
    local targets={}
    for _, fullType in ipairs(TARGETS) do
        for _, row in ipairs(rows) do if row.data.fullType==fullType then table.insert(targets,row) end end
    end
    for _, row in ipairs(targets) do
        local group=groups[row.group] or {}; local vanilla={}
        for _, ref in ipairs(group) do if moduleOf(ref.data.fullType)=="Base" then table.insert(vanilla,ref) end end
        writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n",row.data.fullType,row.group,tostring(row.data.utilitySubgroup),n(referenceScore(row,group)),n(referenceScore(row,vanilla)),n(row.data.utility),tostring(row.data.finalRarityTier),n(row.metrics.capacity),n(row.metrics.weightReduction),n(row.metrics.emptyWeight),n(row.metrics.runSpeedModifier),n(row.metrics.attachments),n(row.structural.maxSize),tostring(row.structural.accept)))
    end
    writer:write("\nALL CONTAINERS\n")
    writer:write("module | fullType | group | body | equip | capacity | reduction | weight | run | attachments | maxItemSize | accept | occurrences | activeUtility | finalTier\n")
    for _, row in ipairs(rows) do
        local d,s=row.data,row.structural
        writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n",moduleOf(d.fullType),d.fullType,row.group,s.body,s.equip,n(row.metrics.capacity),n(row.metrics.weightReduction),n(row.metrics.emptyWeight),n(row.metrics.runSpeedModifier),n(row.metrics.attachments),n(s.maxSize),s.accept,tostring(d.occurrences or 0),n(d.utility),tostring(d.finalRarityTier)))
    end
    writer:close()
    ItemRarityUtils.info("Container taxonomy audit written to Zomboid/Lua/ItemRarity_ContainerTaxonomy.txt (read-only).")
    return true
end
