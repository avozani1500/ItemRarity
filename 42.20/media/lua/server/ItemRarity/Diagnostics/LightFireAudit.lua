require "ItemRarity/RarityUtils"

-- Read-only structural audit for a future LightSource / FireResource utility.
-- It deliberately does not create candidates, scores, tiers or registry fields.
-- A dual-function item is listed in each relevant analysis, but is never given
-- a combined score or silently compared against a pure light/fire item.
ItemRarityLightFireAudit = ItemRarityLightFireAudit or {}

local function call(object, getter, field)
    if not object then return nil end
    local ok, method = pcall(function() return object[getter] end)
    if ok and type(method) == "function" then
        local called, value = pcall(function() return method(object) end)
        if called and value ~= nil then return value end
    end
    local fieldOk, value = pcall(function() return object[field] end)
    if fieldOk then return value end
    return nil
end

local function metric(script, runtime, getter, field)
    -- Light-related values are not exposed consistently on ScriptItem in B42;
    -- a fresh temporary instance supplies the same declared static values for
    -- drainables without becoming part of scanner state or the registry.
    local value = call(runtime, getter, field)
    if value ~= nil then return value end
    return call(script, getter, field)
end

local function number(script, runtime, getter, field)
    local value = metric(script, runtime, getter, field)
    return type(value) == "number" and value or nil
end

local function bool(script, runtime, getter, field)
    local value = metric(script, runtime, getter, field)
    return value == true
end

local function text(object, getter, field)
    local value = call(object, getter, field)
    return value ~= nil and tostring(value) or ""
end

local function tagsOf(script)
    local tags = text(script, "getTags", "tags"):lower()
    return tags
end

local function hasTag(tags, tag)
    return tags:find("base:" .. tag, 1, true) ~= nil
end

local function safe(value)
    if value == nil then return "N/A" end
    if type(value) == "number" then return string.format("%.6f", value) end
    return tostring(value):gsub("[\r\n|]", " ")
end

local function usesFrom(useDelta)
    -- Only an estimate for a recognised drainable light/fire source.  The
    -- report keeps UseDelta visible because some actions spend one use rather
    -- than time, and V1 must verify that distinction before scoring it.
    if type(useDelta) == "number" and useDelta > 0 and useDelta <= 1 then
        return math.max(1, math.floor((1 / useDelta) + .5))
    end
    return nil
end

local function profile(record, kind)
    return table.concat({
        kind,
        string.format("%.4f", record.lightStrength or 0),
        string.format("%.4f", record.lightDistance or 0),
        tostring(record.torchCone),
        string.format("%.6f", record.useDelta or 0),
        tostring(record.usesBattery),
        tostring(record.activated),
        tostring(record.equippable),
        tostring(record.fireStarter),
        tostring(record.replaceOnDeplete or ""),
        tostring(record.replaceOnUse or ""),
    }, ":")
end

local function sortLight(a, b)
    if (a.lightStrength or 0) ~= (b.lightStrength or 0) then return (a.lightStrength or 0) > (b.lightStrength or 0) end
    if (a.lightDistance or 0) ~= (b.lightDistance or 0) then return (a.lightDistance or 0) > (b.lightDistance or 0) end
    if (a.estimatedUses or 0) ~= (b.estimatedUses or 0) then return (a.estimatedUses or 0) > (b.estimatedUses or 0) end
    return a.fullType < b.fullType
end

local function sortFire(a, b)
    if (a.estimatedUses or 0) ~= (b.estimatedUses or 0) then return (a.estimatedUses or 0) > (b.estimatedUses or 0) end
    if (a.useDelta or 999) ~= (b.useDelta or 999) then return (a.useDelta or 999) < (b.useDelta or 999) end
    return a.fullType < b.fullType
end

local function countProfiles(records, kind)
    local profiles = {}
    for _, record in ipairs(records) do profiles[profile(record, kind)] = true end
    local count = 0; for _ in pairs(profiles) do count = count + 1 end
    return count
end

local function writeRows(writer, title, rows, order)
    table.sort(rows, order)
    writer:write("\n" .. title .. "\n")
    writer:write("rank | fullType | module | DisplayCategory | ItemType | lightStrength | lightDistance | TorchCone | UseDelta | estimatedUses* | UsesBattery | activated | equippable | weight | replaceOnDeplete | replaceOnUse | tags | note\n")
    for index, r in ipairs(rows) do
        writer:write(table.concat({
            tostring(index), r.fullType, r.module, r.displayCategory, r.itemType,
            safe(r.lightStrength), safe(r.lightDistance), tostring(r.torchCone), safe(r.useDelta),
            safe(r.estimatedUses), tostring(r.usesBattery), tostring(r.activated), tostring(r.equippable),
            safe(r.weight), safe(r.replaceOnDeplete), safe(r.replaceOnUse), r.tags, r.note,
        }, " | ") .. "\n")
    end
end

function ItemRarityLightFireAudit.write(results)
    if type(results) ~= "table" or not getScriptManager or not getFileWriter then return nil end

    local all, lights, fires, partial = {}, {}, {}, {}
    local bridge = { lightStrength=0, lightDistance=0, useDelta=0, usesBattery=0, activated=0, replaceOnDeplete=0, replaceOnUse=0 }
    for _, data in pairs(results) do
        local script = getScriptManager():FindItem(data.fullType)
        if script then
            local tags = tagsOf(script)
            local instance = nil
            local made, temporary = pcall(function() return script:InstanceItem(nil, false) end)
            if made then instance = temporary end
            local lightStrength = number(script, instance, "getLightStrength", "lightStrength")
            local lightDistance = number(script, instance, "getLightDistance", "lightDistance")
            local useDelta = number(script, instance, "getUseDelta", "useDelta")
            local usesBattery = bool(script, instance, "isUsesBattery", "usesBattery") or hasTag(tags, "usesbattery")
            local activated = bool(script, instance, "canBeActivated", "activatedItem")
            local fireStarter = hasTag(tags, "startfire")
            local light = (lightStrength or 0) > 0 or (lightDistance or 0) > 0
            local displayCategory = text(script, "getDisplayCategory", "displayCategory")
            local categorySignal = displayCategory:lower() == "lightsource" or displayCategory:lower() == "firesource"
            if light or fireStarter or categorySignal then
                local record = {
                    fullType=data.fullType, module=(data.fullType:match("^([^.]+)") or ""),
                    displayCategory=displayCategory, itemType=text(script, "getItemType", "itemType"), tags=tags,
                    lightStrength=lightStrength, lightDistance=lightDistance,
                    torchCone=bool(script, instance, "isTorchCone", "torchCone"), useDelta=useDelta,
                    estimatedUses=usesFrom(useDelta), usesBattery=usesBattery, activated=activated,
                    equippable=bool(script, instance, "canBeEquipped", "canBeEquipped") or bool(script, instance, "isEquipable", "equipable"),
                    weight=number(script, instance, "getActualWeight", "actualWeight") or number(script, instance, "getWeight", "weight"),
                    replaceOnDeplete=text(script, "getReplaceOnDeplete", "replaceOnDeplete"),
                    replaceOnUse=text(script, "getReplaceOnUse", "replaceOnUse"), fireStarter=fireStarter,
                    note="",
                }
                if lightStrength ~= nil then bridge.lightStrength=bridge.lightStrength+1 end
                if lightDistance ~= nil then bridge.lightDistance=bridge.lightDistance+1 end
                if useDelta ~= nil then bridge.useDelta=bridge.useDelta+1 end
                if usesBattery then bridge.usesBattery=bridge.usesBattery+1 end
                if activated then bridge.activated=bridge.activated+1 end
                if record.replaceOnDeplete ~= "" then bridge.replaceOnDeplete=bridge.replaceOnDeplete+1 end
                if record.replaceOnUse ~= "" then bridge.replaceOnUse=bridge.replaceOnUse+1 end

                if light and fireStarter then
                    record.note="DUAL_FUNCTION: listed separately; no combined ranking"
                    table.insert(partial, record); table.insert(lights, record); table.insert(fires, record)
                elseif light then
                    record.note="LIGHTSOURCE"
                    table.insert(lights, record)
                elseif fireStarter then
                    record.note="FIRESOURCE"
                    table.insert(fires, record)
                else
                    record.note="SPECIAL_PARTIAL: category signal, but no direct light/fire-start evidence"
                    table.insert(partial, record)
                end
                table.insert(all, record)
            end
        end
    end

    table.sort(all, function(a,b) return a.fullType < b.fullType end)
    local vanilla, modded = 0, 0
    for _, r in ipairs(all) do if r.module == "Base" then vanilla=vanilla+1 else modded=modded+1 end end
    local writer = getFileWriter("ItemRarity_LightFireAudit.txt", true, false)
    if not writer then return nil end
    writer:write("Item Rarity LightSource / FireResource audit (READ ONLY)\n")
    writer:write("No tier, utility candidate, registry field or active formula is changed.\n")
    writer:write("LIGHTSOURCE and FIRESOURCE are separate rankings. Dual-function records are duplicated into each relevant section but excluded from any combined score.\n")
    writer:write("* estimatedUses = 1 / UseDelta only for inspection; it is not yet interpreted as seconds/minutes or a final utility metric.\n\n")
    writer:write(string.format("CANDIDATES=%d | VANILLA=%d | MODDED=%d | LIGHTSOURCE_MEMBERS=%d (%d unique profiles) | FIRESOURCE_MEMBERS=%d (%d unique profiles) | SPECIAL_PARTIAL=%d\n",
        #all, vanilla, modded, #lights, countProfiles(lights, "LIGHT"), #fires, countProfiles(fires, "FIRE"), #partial))
    writer:write(string.format("BRIDGE AVAILABILITY AMONG CANDIDATES | LightStrength=%d | LightDistance=%d | UseDelta=%d | UsesBattery=%d | ActivatedItem=%d | ReplaceOnDeplete=%d | ReplaceOnUse=%d\n",
        bridge.lightStrength, bridge.lightDistance, bridge.useDelta, bridge.usesBattery, bridge.activated, bridge.replaceOnDeplete, bridge.replaceOnUse))
    writeRows(writer, "LIGHTSOURCE ORDER (strength, radius, estimated uses; diagnostic only)", lights, sortLight)
    writeRows(writer, "FIRESOURCE ORDER (estimated uses, UseDelta; diagnostic only)", fires, sortFire)
    writeRows(writer, "SPECIAL_PARTIAL / DUAL-FUNCTION RECORDS", partial, function(a,b) return a.fullType < b.fullType end)
    writer:write("\nALL CANDIDATES\n")
    writeRows(writer, "ALL", all, function(a,b) return a.fullType < b.fullType end)
    writer:close()
    ItemRarityUtils.info(string.format("Light/Fire audit written: candidates=%d | light members=%d | fire members=%d | partial=%d.", #all, #lights, #fires, #partial))
    return true
end
