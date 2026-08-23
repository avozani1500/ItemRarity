if isServer() then return end

require "ItemRarity/RarityAPI"
require "ItemRarity/RarityUtils"

-- Client-only, read-only supplement for the Light/Fire audit. B42 exposes
-- getLightStrength()/getLightDistance() to the client UI (the vanilla radial
-- menu uses them) but not through the server ScriptItem bridge. This writer
-- reads fresh temporary items and the already-published registry only.
ItemRarityLightFireClientAudit = ItemRarityLightFireClientAudit or {}

local function invoke(object, method)
    if not object then return nil end
    local ok, fn = pcall(function() return object[method] end)
    if not ok or type(fn) ~= "function" then return nil end
    local called, value = pcall(function() return fn(object) end)
    return called and value or nil
end

local function scriptText(script, getter, field)
    local value = invoke(script, getter)
    if value == nil and field then
        local ok; ok, value = pcall(function() return script[field] end)
        if not ok then value = nil end
    end
    return value == nil and "" or tostring(value)
end

local function field(object, getter, script, scriptGetter, scriptField)
    local value = invoke(object, getter)
    if value == nil and script then value = invoke(script, scriptGetter or getter) end
    if value == nil and script and scriptField then
        local ok; ok, value = pcall(function() return script[scriptField] end)
        if not ok then value = nil end
    end
    return value
end

local function num(value) return type(value) == "number" and value or nil end
local function tag(tags, name) return tags:find("base:" .. name, 1, true) ~= nil end
local function safe(value)
    if value == nil then return "N/A" end
    if type(value) == "number" then return string.format("%.6f", value) end
    return tostring(value):gsub("[\r\n|]", " ")
end
local function estimatedUses(delta)
    if type(delta) == "number" and delta > 0 and delta <= 1 then return math.max(1, math.floor(1 / delta + .5)) end
    return nil
end
local function profile(r, kind)
    return table.concat({kind, r.lightStrength or 0, r.lightDistance or 0, r.useDelta or 0, tostring(r.torchCone), tostring(r.activated), tostring(r.battery)}, ":")
end
local function profiles(rows, kind)
    local set,n={},0; for _,r in ipairs(rows) do set[profile(r,kind)]=true end; for _ in pairs(set) do n=n+1 end; return n
end
local function lightOrder(a,b)
    if (a.lightStrength or 0) ~= (b.lightStrength or 0) then return (a.lightStrength or 0) > (b.lightStrength or 0) end
    if (a.lightDistance or 0) ~= (b.lightDistance or 0) then return (a.lightDistance or 0) > (b.lightDistance or 0) end
    if (a.uses or 0) ~= (b.uses or 0) then return (a.uses or 0) > (b.uses or 0) end
    return a.fullType < b.fullType
end
local function fireOrder(a,b)
    if (a.uses or 0) ~= (b.uses or 0) then return (a.uses or 0) > (b.uses or 0) end
    return a.fullType < b.fullType
end
local function rows(writer, title, records, order)
    table.sort(records, order)
    writer:write("\n"..title.."\n")
    writer:write("rank | fullType | DisplayCategory | ItemType | strength | distance | TorchCone | UseDelta | estimatedUses* | battery evidence | activated | equippable | weight | tags | classification\n")
    for i,r in ipairs(records) do
        writer:write(table.concat({i,r.fullType,r.displayCategory,r.itemType,safe(r.lightStrength),safe(r.lightDistance),tostring(r.torchCone),safe(r.useDelta),safe(r.uses),r.battery,tostring(r.activated),tostring(r.equippable),safe(r.weight),r.tags,r.classification}," | ").."\n")
    end
end

function ItemRarityLightFireClientAudit.write()
    if not getScriptManager or not getFileWriter or not ItemRarity or type(ItemRarity.registry) ~= "table" then return nil end
    local lights,fires,partial={}, {}, {}
    local manager=getScriptManager()
    for fullType in pairs(ItemRarity.registry) do
        local script=manager:FindItem(fullType)
        if script then
            local made,item=pcall(function() return script:InstanceItem(nil,false) end)
            if not made then item=nil end
            local tags=scriptText(script,"getTags","tags"):lower()
            local display=scriptText(script,"getDisplayCategory","displayCategory")
            local strength=num(field(item,"getLightStrength",script,"getLightStrength","lightStrength"))
            local distance=num(field(item,"getLightDistance",script,"getLightDistance","lightDistance"))
            local delta=num(field(item,"getUseDelta",script,"getUseDelta","useDelta"))
            local hasLight=(strength or 0)>0 or (distance or 0)>0
            local fire=tag(tags,"startfire")
            local category=display:lower()
            local categoryOnly=(category=="lightsource" or category=="firesource")
            if hasLight or fire or categoryOnly then
                local scriptBattery=field(item,"isUsesBattery",script,"isUsesBattery","usesBattery") == true or tag(tags,"usesbattery")
                local record={ fullType=fullType, displayCategory=display, itemType=scriptText(script,"getItemType","itemType"), tags=tags,
                    lightStrength=strength, lightDistance=distance, useDelta=delta, uses=estimatedUses(delta),
                    torchCone=field(item,"isTorchCone",script,"isTorchCone","torchCone") == true,
                    activated=field(item,"canBeActivated",script,"isActivatedItem","activatedItem") == true,
                    equippable=field(item,"canBeEquipped",script,"canBeEquipped","canBeEquipped") == true,
                    weight=num(field(item,"getActualWeight",script,"getActualWeight","actualWeight")),
                    battery=scriptBattery and "DECLARED" or (tag(tags,"flashlight") and "FLASHLIGHT_TAG_ONLY" or "NONE_DECLARED"), classification="" }
                if hasLight and fire then
                    record.classification="SPECIAL_PARTIAL dual-function; listed in both separate rankings"
                    table.insert(partial,record); table.insert(lights,record); table.insert(fires,record)
                elseif hasLight then record.classification="LIGHTSOURCE"; table.insert(lights,record)
                elseif fire then record.classification="FIRESOURCE"; table.insert(fires,record)
                else record.classification="SPECIAL_PARTIAL category-only; no measurable light/start-fire evidence"; table.insert(partial,record) end
            end
        end
    end
    local writer=getFileWriter("ItemRarity_LightFireAudit.txt",true,false); if not writer then return nil end
    writer:write("Item Rarity LightSource / FireResource audit (CLIENT READ-ONLY)\n")
    writer:write("Uses vanilla client light getters; does not alter candidates, tiers, registry or scanner state.\n")
    writer:write("* estimatedUses = 1 / UseDelta only for inspection, not a duration unit or final score.\n")
    writer:write(string.format("LIGHTSOURCE_MEMBERS=%d (%d mechanical profiles) | FIRESOURCE_MEMBERS=%d (%d profiles) | SPECIAL_PARTIAL=%d\n",#lights,profiles(lights,"L"),#fires,profiles(fires,"F"),#partial))
    rows(writer,"LIGHTSOURCE ORDER — strength, distance, estimated uses (diagnostic only)",lights,lightOrder)
    rows(writer,"FIRESOURCE ORDER — estimated uses (diagnostic only)",fires,fireOrder)
    rows(writer,"SPECIAL_PARTIAL / DUAL-FUNCTION",partial,function(a,b) return a.fullType<b.fullType end)
    writer:close()
    ItemRarityUtils.info(string.format("Client Light/Fire audit written: lights=%d | fires=%d | partial=%d.",#lights,#fires,#partial))
    return true
end
