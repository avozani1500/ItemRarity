require "ItemRarity/RarityUtils"

-- Diagnostic only.  Kept independent from ClothingMechanicalValueReport so
-- the B42 Lua compiler's 200-local limit cannot affect the active pipeline.
ItemRarityFoodQualityExperiment = ItemRarityFoodQualityExperiment or {}

local function clamp(v, low, high) return math.max(low, math.min(high, v)) end
local function n(v) return v ~= nil and string.format("%.2f", v) or "N/A" end

local function positiveRank(values, value)
    if value == nil or value <= 0 then return 0 end
    local positives = {}
    for _, v in ipairs(values) do if v > 0 then table.insert(positives, v) end end
    if #positives == 0 then return 0 end
    if #positives == 1 then return 50 end
    local below, equal = 0, 0
    for _, v in ipairs(positives) do
        if v < value then below = below + 1 elseif v == value then equal = equal + 1 end
    end
    return clamp(((below + equal * .5) / #positives) * 100, 0, 100)
end

local function groupWeights(group)
    if group == "DRINK" then return { .10, .10, .50, .15, .15 } end
    if group == "INGREDIENT" then return { .30, .20, .10, .20, .20 } end
    return { .40, .28, .08, .14, .10 }
end

local function calibrationWeights(group, calibration)
    if group == "DRINK" then
        if calibration == "HYDRATION" then return { .08,.08,.62,.12,.10 } end
        if calibration == "CONVENIENCE" then return { .10,.10,.50,.12,.18 } end
        return groupWeights(group)
    end
    if calibration == "SUSTENANCE" then return { .48,.28,.06,.10,.08 } end
    if calibration == "CONVENIENCE" then return { .36,.28,.08,.10,.18 } end
    return groupWeights(group)
end

local function score(c, weights)
    local benefit=c.sustenance*weights[1]+c.energy*weights[2]+c.hydration*weights[3]+c.preservation*weights[4]+c.convenience*weights[5]
    return benefit*(1-.50*(c.negative/100))
end

local function provisionalTier(quality, scarcity)
    local ceiling = quality < 25 and 1 or (quality < 45 and 2 or (quality < 65 and 3 or (quality < 80 and 4 or 5)))
    local inside = quality * (.75 + .25 * scarcity / 100)
    if ceiling == 5 and scarcity < 60 then return "EPIC" end
    if inside < 25 then return "COMMON" elseif inside < 45 then return "UNCOMMON" elseif inside < 65 then return "RARE" elseif inside < 80 then return "EPIC" end
    return ceiling == 5 and "EXOTIC" or "EPIC"
end

local function negativeMultiplier(negative, curve)
    local x=clamp((negative or 0)/100,0,1)
    local penalty = curve == "POWER15" and .80*(x^1.5) or (curve == "POWER20" and .95*(x^2.0) or .50*x)
    return math.max(0,1-penalty)
end

local function foodFocusedScore(c, model, curve, energyOverride)
    local weights = model == "A" and { .75,.20,.03,.02 } or (model == "B" and { .80,.15,.03,.02 } or { .85,.10,.03,.02 })
    local benefit=c.sustenance*weights[1]+(energyOverride or c.energy)*weights[2]+c.preservation*weights[3]+c.convenience*weights[4]
    return benefit*negativeMultiplier(c.negative,curve)
end

-- Mood has three independently bounded benefits.  Negative values in the
-- B42 Food fields mean the consumable *reduces* unhappiness/boredom/stress;
-- positive values remain adverse effects and stay in NegativeEffects.
-- Each benefit is capped at its robust p90 before combining them, so a single
-- extreme script value cannot outweigh sustenance by itself.
local function cappedBenefit(value, cap)
    if not value or value <= 0 or not cap or cap <= 0 then return 0 end
    return 100 * math.min(value, cap) / cap
end

local function moodBenefit(m, caps)
    local unhappy = cappedBenefit(math.max(0, -(m.unhappyChange or 0)), caps.unhappy)
    local boredom = cappedBenefit(math.max(0, -(m.boredomChange or 0)), caps.boredom)
    local stress = cappedBenefit(math.max(0, -(m.stressChange or 0)), caps.stress)
    return unhappy * .50 + boredom * .20 + stress * .30, unhappy, boredom, stress
end

local function foodMoodScore(c, energyOverride, model)
    -- Diagnostic candidate only: hunger is dominant, positive consumption
    -- effects are explicitly second, then energy/preservation/convenience.
    local weights = model == "B" and { .57, .23 } or (model == "C" and { .55, .25 } or { .60, .20 })
    local benefit = c.sustenance * weights[1] + c.mood * weights[2] + (energyOverride or c.energy) * .12 + c.preservation * .05 + c.convenience * .03
    return benefit * negativeMultiplier(c.negative, "POWER15")
end

local function positiveQuantile(values, percentile)
    local positives={}
    for _,v in ipairs(values) do if v and v>0 then table.insert(positives,v) end end
    table.sort(positives)
    if #positives == 0 then return 0 end
    local index=math.max(1,math.min(#positives,math.floor((#positives-1)*(percentile/100)+1.5)))
    return positives[index]
end

local function positiveDistribution(values)
    local positives={}
    for _,v in ipairs(values) do if v and v>0 then table.insert(positives,v) end end
    table.sort(positives)
    if #positives == 0 then return { count=0 } end
    return { count=#positives, min=positives[1], median=positiveQuantile(positives,50), p75=positiveQuantile(positives,75), p90=positiveQuantile(positives,90), p95=positiveQuantile(positives,95), max=positives[#positives] }
end

-- These curves are deliberately absolute transforms rather than percentile
-- ranks.  A monotonic transform followed by a percentile would preserve the
-- exact same ordering and therefore would not reduce calorie dominance.
local function normalizedEnergy(calories, p90, curve)
    local value=math.max(0,calories or 0)
    if value == 0 or p90 <= 0 then return 0 end
    if curve == "SQRT_P90" then return 100*math.sqrt(math.min(1,value/p90)) end
    if curve == "LOG_300" then return math.min(100,100*math.log(1+value/300)/math.log(1+p90/300)) end
    -- Fixed 600 kcal half-saturation: 300→33.3, 600→50, 1200→66.7,
    -- 2000→76.9 and 6000→90.9.  It makes the intended diminishing returns
    -- visible instead of merely changing the scale of a percentile.
    return 100*value/(value+600)
end

local function foodFocusedTier(quality, scarcity)
    -- Provisional conceptual ceiling: FoodQuality controls the available tier;
    -- Scarcity can only settle the position inside that ceiling.
    if quality < 30 then return "COMMON" end
    if quality < 50 then return "UNCOMMON" end
    if quality < 70 then return "RARE" end
    if quality < 85 then return "EPIC" end
    return scarcity >= 60 and "EXOTIC" or "EPIC"
end

local function rankingConfidence(count)
    return count >= 20 and "HIGH" or (count >= 8 and "MEDIUM" or "LOW")
end

local function utilityConfidence(m)
    local fields = { m.hungerChange, m.thirstChange, m.calories, m.daysTotallyRotten, m.cookable, m.unhappyChange, m.boredomChange, m.stressChange, m.foodSicknessChange, m.dangerousUncooked }
    local present = 0
    for _, value in ipairs(fields) do if value ~= nil then present = present + 1 end end
    return present >= 9 and "HIGH" or (present >= 6 and "MEDIUM" or "LOW")
end

local function preservation(m)
    local days = m.daysTotallyRotten or 0
    return days >= 100000000 and 1000000000 or days
end

local function compute(records)
    local groups = {}
    for _, r in ipairs(records) do
        if r.foodUtilityStatus == "ELIGIBLE" and (r.functionalGroup == "FOOD" or r.functionalGroup == "DRINK") then
            groups[r.functionalGroup] = groups[r.functionalGroup] or {}
            table.insert(groups[r.functionalGroup], r)
        end
    end
    for group, list in pairs(groups) do
        local reps, seen, samples = {}, {}, { hunger={}, calories={}, thirst={}, preservation={}, moodUnhappy={}, moodBoredom={}, moodStress={} }
        for _, r in ipairs(list) do if not seen[r.profile] then seen[r.profile]=true; table.insert(reps,r) end end
        for _, r in ipairs(reps) do
            local m=r.m
            table.insert(samples.hunger, m.hungerBenefit or 0)
            table.insert(samples.calories, m.calories or 0)
            table.insert(samples.thirst, m.thirstBenefit or 0)
            table.insert(samples.preservation, preservation(m))
            table.insert(samples.moodUnhappy, math.max(0, -(m.unhappyChange or 0)))
            table.insert(samples.moodBoredom, math.max(0, -(m.boredomChange or 0)))
            table.insert(samples.moodStress, math.max(0, -(m.stressChange or 0)))
        end
        local rankConfidence=rankingConfidence(#reps)
        local weights=groupWeights(group)
        local energyP90=positiveQuantile(samples.calories,90)
        local moodCaps={ unhappy=positiveQuantile(samples.moodUnhappy,90), boredom=positiveQuantile(samples.moodBoredom,90), stress=positiveQuantile(samples.moodStress,90) }
        local moodDistributions={ unhappy=positiveDistribution(samples.moodUnhappy), boredom=positiveDistribution(samples.moodBoredom), stress=positiveDistribution(samples.moodStress) }
        for _, r in ipairs(list) do
            local m=r.m
            local rawRisk=m.dangerousUncooked and 35 or 0
            local cook=m.cookable and math.min(100, ((m.minutesToCook or 60) / 60) * 55) or 0
            local convenience=math.max(0, 100-cook-rawRisk)
            local negative=math.min(100, math.max(0,m.unhappyChange or 0)*1.5 + math.max(0,m.boredomChange or 0)*2 + math.max(0,m.stressChange or 0)*100 + math.max(0,m.foodSicknessChange or 0)*2 + (m.poison and 100 or 0) + rawRisk)
            local c={
                sustenance=positiveRank(samples.hunger,m.hungerBenefit or 0),
                energy=positiveRank(samples.calories,m.calories or 0),
                hydration=positiveRank(samples.thirst,m.thirstBenefit or 0),
                preservation=positiveRank(samples.preservation,preservation(m)),
                convenience=convenience, negative=negative,
            }
            c.mood, c.moodUnhappy, c.moodBoredom, c.moodStress = moodBenefit(m, moodCaps)
            local quality=score(c,weights)
            local scarcity=100-(r.data.scarcityPercentile or (r.data.tableAvailability and r.data.tableAvailability.routeWeightedPercentile) or 50)
            r.foodQualityComponents=c; r.foodQuality=quality; r.scarcityStrength=scarcity
            r.foodUtilityConfidence=utilityConfidence(m); r.foodRankingConfidence=rankConfidence; r.foodProfileCount=#reps
            r.foodModels={ A=.70*scarcity+.30*quality, B=.25*scarcity+.75*quality, C=quality*(.75+.25*scarcity/100) }
            r.foodCalibrations={}
            for _, key in ipairs({"SUSTENANCE","BALANCED","CONVENIENCE"}) do
                local q=score(c,calibrationWeights(group,key)); local cScore=q*(.75+.25*scarcity/100)
                r.foodCalibrations[key]={ quality=q, modelC=cScore, tier=provisionalTier(q,scarcity) }
            end
            if group == "FOOD" then
                r.foodFocused={}
                for _, key in ipairs({"A","B","C"}) do
                    local q=foodFocusedScore(c,key)
                    r.foodFocused[key]={ quality=q, blend=.90*q+.10*scarcity, tier=foodFocusedTier(q,scarcity) }
                end
                r.foodNegativeCurves={}
                for _, curve in ipairs({"LINEAR","POWER15","POWER20"}) do
                    local q=foodFocusedScore(c,"B",curve)
                    r.foodNegativeCurves[curve]={ quality=q, blend=.90*q+.10*scarcity, tier=foodFocusedTier(q,scarcity) }
                end
                r.foodEnergyCurves={}
                for _,curve in ipairs({"SQRT_P90","LOG_300","SAT_600"}) do
                    local energy=normalizedEnergy(m.calories,energyP90,curve)
                    local q=foodFocusedScore(c,"B","POWER15",energy)
                    r.foodEnergyCurves[curve]={ raw=m.calories or 0, normalized=energy, quality=q, blend=.90*q+.10*scarcity, tier=foodFocusedTier(q,scarcity) }
                end
                local moodEnergy=normalizedEnergy(m.calories,energyP90,"SAT_600")
                r.foodMoodExperiment={ energyNormalized=moodEnergy, caps=moodCaps, distributions=moodDistributions, models={} }
                for _, key in ipairs({"A","B","C"}) do
                    local moodQuality=foodMoodScore(c,moodEnergy,key)
                    r.foodMoodExperiment.models[key]={ quality=moodQuality, blend=.95*moodQuality+.05*scarcity, tier=foodFocusedTier(moodQuality,scarcity) }
                end
            end
        end
    end
    return groups
end

local function sortedRows(records, model)
    local rows={}
    for _, r in ipairs(records) do if r.foodModels then table.insert(rows,r) end end
    table.sort(rows,function(a,b) local av,bv=a.foodModels[model],b.foodModels[model]; return av == bv and a.data.fullType < b.data.fullType or av > bv end)
    return rows
end

local function recommendedPrimary(r)
    local m, tags = r.m, r.tags or ""
    if r.foodUtilityStatus == "PARTIAL" then return "SPECIAL_PARTIAL" end
    if m.preparationRequired or m.preparationAmbiguous then return "SPECIAL_PARTIAL" end
    if string.find(tags,"ingredient",1,true) or string.find(tags,"isseed",1,true) or string.find(tags,"iscutting",1,true) or string.find(tags,"pizzasauce",1,true) then return "INGREDIENT" end
    -- B42 exposes EatType=Candrink for both beverages and canned soups.
    -- It therefore becomes drink evidence only together with hydration being
    -- the primary benefit. FoodType/solid food evidence keeps fruit as FOOD.
    local eatType=string.lower(tostring(m.eatType or ""))
    local eatSound=string.lower(tostring(m.customEatSound or ""))
    if string.find(eatType,"drink",1,true) and string.find(eatSound,"drinking",1,true) and (m.thirstBenefit or 0) > (m.hungerBenefit or 0) then return "DRINK" end
    if string.find(eatSound,"eating",1,true) then return "FOOD" end
    if tostring(m.foodType or "") ~= "" then return "FOOD" end
    if string.find(eatType,"drink",1,true) then return "FOOD" end
    if (m.thirstBenefit or 0) > (m.hungerBenefit or 0) then return "SPECIAL_PARTIAL" end
    return "FOOD"
end

local function writeFunctionAudit(writer, records)
    writer:write("\\nPRIMARY-FUNCTION AUDIT (classification only; FoodQuality/Model C unchanged)\\n")
    writer:write("DRINK requires structural drinking action (EatType containing drink) plus hydration greater than hunger. HYDRATION alone remains secondary; Candrink soup is FOOD when hunger is primary.\\n")
    writer:write("CURRENT_DRINK | fullType | HungerBenefit | ThirstBenefit | Calories | ItemType | EatType | CustomEatSound | FoodType | drainable | replaceOnUse | replaceOnDeplete | tags | current | recommended | secondaryFlags\\n")
    for _, r in ipairs(records) do
        if r.functionalGroup == "DRINK" then
            local m=r.m
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,n(m.hungerBenefit),n(m.thirstBenefit),n(m.calories),r.itemType,m.eatType,m.customEatSound,m.foodType,tostring((r.itemType or ""):find("drainable",1,true) ~= nil),m.replaceOnUse,m.replaceOnDeplete,r.tags,r.functionalGroup,recommendedPrimary(r),r.flags))
        end
    end
    writer:write("\\nHYDRATING FOOD / SOUP / TIN EXAMPLES | fullType | HungerBenefit | ThirstBenefit | Calories | EatType | CustomEatSound | FoodType | current | recommended | flags\\n")
    local count=0
    for _, r in ipairs(records) do
        if (r.m.thirstBenefit or 0) > 0 and r.functionalGroup ~= "DRINK" then
            count=count+1; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,n(r.m.hungerBenefit),n(r.m.thirstBenefit),n(r.m.calories),r.m.eatType,r.m.customEatSound,r.m.foodType,r.functionalGroup,recommendedPrimary(r),r.flags))
            if count >= 40 then break end
        end
    end
    for _, group in ipairs({"FOOD","DRINK","INGREDIENT"}) do
        local rows={}
        for _, r in ipairs(records) do if r.foodModels and r.functionalGroup == group then table.insert(rows,r) end end
        table.sort(rows,function(a,b) return a.foodQuality == b.foodQuality and a.data.fullType < b.data.fullType or a.foodQuality > b.foodQuality end)
        writer:write("\\nTOP FOODQUALITY "..group.." (5) | fullType | quality | C | Hunger | Thirst | Calories | flags\\n")
        for i,r in ipairs(rows) do if i>5 then break end; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,n(r.foodQuality),n(r.foodModels.C),n(r.m.hungerBenefit),n(r.m.thirstBenefit),n(r.m.calories),r.flags)) end
        table.sort(rows,function(a,b) return a.foodQuality == b.foodQuality and a.data.fullType < b.data.fullType or a.foodQuality < b.foodQuality end)
        writer:write("BOTTOM FOODQUALITY "..group.." (5) | fullType | quality | C | Hunger | Thirst | Calories | flags\\n")
        for i,r in ipairs(rows) do if i>5 then break end; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,n(r.foodQuality),n(r.foodModels.C),n(r.m.hungerBenefit),n(r.m.thirstBenefit),n(r.m.calories),r.flags)) end
    end
end

function ItemRarityFoodQualityExperiment.write(records)
    if type(records) ~= "table" or not getFileWriter then return end
    local groups=compute(records)
    local writer=getFileWriter("ItemRarity_FoodQualityExperiment.txt",true,false); if not writer then return end
    writer:write("Item Rarity FoodQuality zero-aware experiment (NOT ACTIVE; NO TIERS)\\n")
    writer:write("Zero/absent Sustenance, Energy, Hydration and Preservation are exactly 0 and excluded from that component's positive ranking population. FoodUtilityConfidence is absolute-attribute completeness; FoodRankingConfidence is only profile sample size.\\n")
    for _, model in ipairs({"A","B","C"}) do
        writer:write("\\nTOP "..model.." | fullType | function | score | quality | scarcity | utilityConfidence | rankingConfidence | sustain | energy | hydration | preservation | convenience | negative\\n")
        local count=0
        for _, r in ipairs(sortedRows(records,model)) do
            count=count+1; local c=r.foodQualityComponents
            writer:write(string.format("%d | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",count,r.data.fullType,r.functionalGroup,n(r.foodModels[model]),n(r.foodQuality),n(r.scarcityStrength),r.foodUtilityConfidence,r.foodRankingConfidence,n(c.sustenance),n(c.energy),n(c.hydration),n(c.preservation),n(c.convenience),n(c.negative)))
            if count>=20 then break end
        end
    end
    writer:write("\\nZERO-AWARE TARGETS | fullType | function | FoodQuality | Scarcity | C | UtilityConfidence | RankingConfidence | profiles | Sustain | Energy | Hydration | Preservation | Convenience | Negative\\n")
    local targets={ ["Base.CannedTomatoOpen"]=true,["Base.DogfoodOpen"]=true,["Base.Toast"]=true,["Base.CannedSardinesOpen"]=true,["Base.Rice"]=true,["Base.DriedKidneyBeans"]=true,["Base.Watermelon"]=true,["Base.PizzaWhole"]=true,["Base.PeanutButter"]=true,["Base.FrenchFries"]=true,["Base.CannedFruitBeverageOpen"]=true,["Base.Teabag2"]=true }
    for _, r in ipairs(records) do
        if targets[r.data.fullType] then
            if not r.foodModels then writer:write(r.data.fullType.." | SPECIAL_PARTIAL | unscored\\n")
            else local c=r.foodQualityComponents; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %d | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.functionalGroup,n(r.foodQuality),n(r.scarcityStrength),n(r.foodModels.C),r.foodUtilityConfidence,r.foodRankingConfidence,r.foodProfileCount,n(c.sustenance),n(c.energy),n(c.hydration),n(c.preservation),n(c.convenience),n(c.negative))) end
        end
    end
    writer:write("\\nFOODUTILITY V1 CALIBRATIONS (NOT ACTIVE; provisional tiers only)\\n")
    writer:write("INGREDIENT and SPECIAL_PARTIAL are intentionally unscored/PARTIAL. Model C remains FoodQuality-dominant; the three variants only shift dimension weights.\\n")
    writer:write("fullType | primary | flags | Sustain | Energy | Hydration | Preserve | Convenience | Negative | Scarcity | confidence | ranking | SustenanceQ/C/tier | BalancedQ/C/tier | ConvenienceQ/C/tier\\n")
    local v1Targets={ ["Base.Rice"]=true,["Base.DriedKidneyBeans"]=true,["Base.PizzaWhole"]=true,["Base.PeanutButter"]=true,["Base.Watermelon"]=true,["Base.CannedFruitBeverageOpen"]=true,["Base.CannedTomatoOpen"]=true,["Base.CannedSardinesOpen"]=true,["Base.DogfoodOpen"]=true,["Base.Toast"]=true,["Base.FrenchFries"]=true,["Base.Butter"]=true,["Base.Margarine"]=true,["Base.MapleSyrup"]=true,["Base.IcecreamMelted"]=true }
    for _,r in ipairs(records) do
        if v1Targets[r.data.fullType] then
            if not r.foodCalibrations then writer:write(r.data.fullType.." | "..r.functionalGroup.." | "..r.flags.." | PARTIAL (no quantified V1 score)\\n")
            else
                local c,a,b,d=r.foodQualityComponents,r.foodCalibrations.SUSTENANCE,r.foodCalibrations.BALANCED,r.foodCalibrations.CONVENIENCE
                writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s | %s/%s/%s | %s/%s/%s\\n",r.data.fullType,r.functionalGroup,r.flags,n(c.sustenance),n(c.energy),n(c.hydration),n(c.preservation),n(c.convenience),n(c.negative),n(r.scarcityStrength),r.foodUtilityConfidence,r.foodRankingConfidence,n(a.quality),n(a.modelC),a.tier,n(b.quality),n(b.modelC),b.tier,n(d.quality),n(d.modelC),d.tier))
            end
        end
    end
    writer:write("\\nFOOD-FOCUSED RECALIBRATION (NOT ACTIVE)\\n")
    writer:write("FOOD only: Hydration=0. A=75% Hunger +20% Calories +3% Preservation +2% Convenience; B=80/15/3/2; C=85/10/3/2. NegativeEffects remains a separate attenuation. Final blend is 90% FoodQuality +10% Scarcity. Provisional tier ceiling is driven by FoodQuality, never Scarcity.\\n")
    writer:write("fullType | Hunger | Calories | Preservation | Negative | Convenience | Scarcity | A quality/blend/tier | B quality/blend/tier | C quality/blend/tier\\n")
    local focusedTargets={ ["Base.Watermelon"]=true,["Base.Rice"]=true,["Base.DriedKidneyBeans"]=true,["Base.PizzaWhole"]=true,["Base.PeanutButter"]=true,["Base.Toast"]=true,["Base.DogfoodOpen"]=true,["Base.CannedTomatoOpen"]=true,["Base.CannedSardinesOpen"]=true,["Base.FrenchFries"]=true,["Base.IcecreamMelted"]=true }
    for _,r in ipairs(records) do
        if focusedTargets[r.data.fullType] then
            if not r.foodFocused then writer:write(r.data.fullType.." | "..r.functionalGroup.." | not FOOD / PARTIAL\\n")
            else
                local c,a,b,d=r.foodQualityComponents,r.foodFocused.A,r.foodFocused.B,r.foodFocused.C
                writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s/%s/%s | %s/%s/%s | %s/%s/%s\\n",r.data.fullType,n(c.sustenance),n(c.energy),n(c.preservation),n(c.negative),n(c.convenience),n(r.scarcityStrength),n(a.quality),n(a.blend),a.tier,n(b.quality),n(b.blend),b.tier,n(d.quality),n(d.blend),d.tier))
            end
        end
    end
    writer:write("\\nNEGATIVEEFFECTS CURVE COMPARISON (FOOD, B weights; NOT ACTIVE)\\n")
    writer:write("LINEAR = 1 - .50x; POWER15 = 1 - .80x^1.5; POWER20 = 1 - .95x^2.0. The progressive curves are gentler for small negatives and stronger for severe negatives.\\n")
    writer:write("fullType | NegativeEffects | Linear Q/blend/tier | Power1.5 Q/blend/tier | Power2.0 Q/blend/tier\\n")
    local negativeTargets={ ["Base.DogfoodOpen"]=true,["Base.BaitFish"]=true,["Base.ChickenWhole"]=true,["Base.PizzaWhole"]=true,["Base.Rice"]=true,["Base.Toast"]=true,["Base.FrenchFries"]=true,["Base.CannedTomatoOpen"]=true,["Base.IcecreamMelted"]=true }
    for _,r in ipairs(records) do
        if negativeTargets[r.data.fullType] and r.foodNegativeCurves then
            local a,b,d=r.foodNegativeCurves.LINEAR,r.foodNegativeCurves.POWER15,r.foodNegativeCurves.POWER20
            writer:write(string.format("%s | %s | %s/%s/%s | %s/%s/%s | %s/%s/%s\\n",r.data.fullType,n(r.foodQualityComponents.negative),n(a.quality),n(a.blend),a.tier,n(b.quality),n(b.blend),b.tier,n(d.quality),n(d.blend),d.tier))
        end
    end
    writer:write("\\nPREPARATION-REQUIRED STRUCTURAL AUDIT (NOT ACTIVE)\\n")
    writer:write("PREPARATION_REQUIRED requires an explicit B42 Food-runtime OnCooked callback. RemoveNegativeEffectOnCooked or ReplaceOnCooked alone are PREPARATION_AMBIGUOUS, because ready meals may be improved by cooking. Cookability, container return and EvolvedRecipe are diagnostic evidence only.\\n")
    writer:write("fullType | utilityStatus | partialReason | currentPrimary | recommendedPrimary | CantEat | IsCookable | OnCooked | RemoveNegativeOnCooked | ReplaceOnCooked | CookingSound | ReplaceOnUse | EvolvedRecipes | hunger | calories | flags\\n")
    for _,r in ipairs(records) do
        local m=r.m
        if r.foodUtilityStatus == "PARTIAL" and (r.foodPartialReason == "CANT_EAT_REQUIRED" or r.foodPartialReason == "PREPARATION_REQUIRED" or r.foodPartialReason == "PREPARATION_AMBIGUOUS") then
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.foodUtilityStatus,r.foodPartialReason,r.functionalGroup,recommendedPrimary(r),tostring(m.cantEat),tostring(m.cookable),m.onCooked,tostring(m.removeNegativeEffectOnCooked),m.replaceOnCooked,m.cookingSound,m.replaceOnUse,m.evolvedRecipes,n(m.hungerBenefit),n(m.calories),r.flags))
        end
    end
    writer:write("\\nENERGY DIMINISHING-RETURNS COMPARISON (FOOD only, B=80% Hunger/15% Energy/3% Preservation/2% Convenience, POWER15; NOT ACTIVE)\\n")
    writer:write("SQRT_P90 = 100*sqrt(min(calories/p90,1)); LOG_300 = 100*ln(1+calories/300)/ln(1+p90/300); SAT_600 = 100*calories/(calories+600). These are absolute transforms, not percentiles, so high calories cannot retain the same relative score merely by ordering first.\\n")
    writer:write("fullType | HungerComponent | EnergyRaw | SQRT energy/Q/final/tier | LOG energy/Q/final/tier | SAT600 energy/Q/final/tier | Preservation | NegativeMultiplier | Scarcity\\n")
    local energyTargets={ ["Base.PizzaWhole"]=true,["Base.Chocolate_HeartBox"]=true,["Base.IcecreamMelted"]=true,["Base.Pumpkin"]=true,["Base.PeanutButter"]=true,["Base.OatsRaw"]=true,["Base.MapleSyrup"]=true,["Base.Cereal"]=true,["Base.Ham"]=true,["Base.Toast"]=true,["Base.DogfoodOpen"]=true }
    for _,r in ipairs(records) do
        if energyTargets[r.data.fullType] then
            if not r.foodEnergyCurves then writer:write(r.data.fullType.." | "..r.functionalGroup.." | PARTIAL / not directly-scored FOOD\\n")
            else
                local c,a,b,d=r.foodQualityComponents,r.foodEnergyCurves.SQRT_P90,r.foodEnergyCurves.LOG_300,r.foodEnergyCurves.SAT_600
                writer:write(string.format("%s | %s | %s | %s/%s/%s/%s | %s/%s/%s/%s | %s/%s/%s/%s | %s | %s | %s\\n",r.data.fullType,n(c.sustenance),n(a.raw),n(a.normalized),n(a.quality),n(a.blend),a.tier,n(b.normalized),n(b.quality),n(b.blend),b.tier,n(d.normalized),n(d.quality),n(d.blend),d.tier,n(c.preservation),n(negativeMultiplier(c.negative,"POWER15")),n(r.scarcityStrength)))
            end
        end
    end
    writer:write("\\nFOODUTILITY V1 CONSERVATIVE ELIGIBILITY (NOT ACTIVE)\\n")
    writer:write("Eligible only: directly consumable FOOD (not CantEat/preparation) using B weights + POWER15, and structurally confirmed DRINK. INGREDIENT, SPECIAL_PARTIAL and preparation-required items are excluded/PARTIAL.\\n")
    local functionCount, drinkCount, partialCounts = 0, 0, {}
    for _,r in ipairs(records) do
        if r.foodUtilityStatus == "ELIGIBLE" and r.functionalGroup == "FOOD" then functionCount=functionCount+1 end
        if r.foodUtilityStatus == "ELIGIBLE" and r.functionalGroup == "DRINK" then drinkCount=drinkCount+1 end
        if r.foodUtilityStatus == "PARTIAL" then
            local reason=r.foodPartialReason or "SPECIAL_UNQUANTIFIED"
            partialCounts[reason]=(partialCounts[reason] or 0)+1
        end
    end
    writer:write(string.format("ELIGIBILITY | FOOD=%d | DRINK=%d | PARTIAL=%d\\n",functionCount,drinkCount,#records-functionCount-drinkCount))
    local partialNames={}; for reason in pairs(partialCounts) do table.insert(partialNames,reason) end; table.sort(partialNames)
    for _,reason in ipairs(partialNames) do writer:write(string.format("PARTIAL | %s | %d\\n",reason,partialCounts[reason])) end
    writer:write("POWER15 exact formula: x = NegativeEffects / 100; penalty = 0.80 * x^1.5; multiplier = 1 - penalty; quality = positive-benefit * multiplier. At x=0, penalty=0. At x=.10, penalty=.0253. At x=.35, penalty=.1657 versus linear .1750 (slightly gentler). At x=.75, penalty=.5196 versus linear .3750 (stronger). The crossover is x=.390625.\\n")
    local tiers={ COMMON=0,UNCOMMON=0,RARE=0,EPIC=0,EXOTIC=0 }; local eligible={}
    for _,r in ipairs(records) do
        local result=nil
        if r.functionalGroup == "FOOD" and r.foodNegativeCurves then result=r.foodNegativeCurves.POWER15
        elseif r.functionalGroup == "DRINK" and r.foodModels then result={ quality=r.foodQuality, blend=r.foodModels.C, tier=provisionalTier(r.foodQuality,r.scarcityStrength) } end
        if result then tiers[result.tier]=tiers[result.tier]+1; table.insert(eligible,{ r=r, result=result }) end
    end
    writer:write(string.format("ELIGIBLE_ITEMS=%d | C/U/R/E/X=%d/%d/%d/%d/%d\\n",#eligible,tiers.COMMON,tiers.UNCOMMON,tiers.RARE,tiers.EPIC,tiers.EXOTIC))
    table.sort(eligible,function(a,b) return a.result.quality == b.result.quality and a.r.data.fullType < b.r.data.fullType or a.result.quality > b.result.quality end)
    writer:write("\\nTOP 20 DIRECT FOOD/DRINK | fullType | function | quality | ModelC/90-10 blend | tier | Hunger | Calories | Negative | flags\\n")
    for i,row in ipairs(eligible) do if i>20 then break end; local r=row.r; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.functionalGroup,n(row.result.quality),n(row.result.blend),row.result.tier,n(r.m.hungerBenefit),n(r.m.calories),n(r.foodQualityComponents.negative),r.flags)) end
    table.sort(eligible,function(a,b) return a.result.quality == b.result.quality and a.r.data.fullType < b.r.data.fullType or a.result.quality < b.result.quality end)
    writer:write("\\nBOTTOM 20 DIRECT FOOD/DRINK | fullType | function | quality | ModelC/90-10 blend | tier | Hunger | Calories | Negative | flags\\n")
    for i,row in ipairs(eligible) do if i>20 then break end; local r=row.r; writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.functionalGroup,n(row.result.quality),n(row.result.blend),row.result.tier,n(r.m.hungerBenefit),n(r.m.calories),n(r.foodQualityComponents.negative),r.flags)) end
    writer:write("\\nHIGH-TIER SANITY CHECK (NOT ACTIVE)\\n")
    writer:write("fullType | primary | HungerBenefit | Calories | Preservation | Convenience | NegativeRaw | POWER15 multiplier | FoodQuality | Scarcity | FinalFoodScore | tier | UtilityConfidence | RankingConfidence | driver\\n")
    local function writeTierRows(tier, limit)
        local rows={}
        for _,row in ipairs(eligible) do if row.result.tier == tier then table.insert(rows,row) end end
        table.sort(rows,function(a,b) return a.result.blend == b.result.blend and a.r.data.fullType < b.r.data.fullType or a.result.blend > b.result.blend end)
        for i,row in ipairs(rows) do
            if i>limit then break end
            local r,c=row.r,row.r.foodQualityComponents
            local mult=r.functionalGroup == "FOOD" and negativeMultiplier(c.negative,"POWER15") or 1
            local driver = c.sustenance >= c.energy and "HUNGER" or "CALORIES"
            if c.preservation >= c.sustenance and c.preservation >= c.energy then driver="PRESERVATION" end
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,r.functionalGroup,n(r.m.hungerBenefit),n(r.m.calories),n(c.preservation),n(c.convenience),n(c.negative),n(mult),n(row.result.quality),n(r.scarcityStrength),n(row.result.blend),tier,r.foodUtilityConfidence,r.foodRankingConfidence,driver))
        end
    end
    writer:write("EXOTIC (all)\\n"); writeTierRows("EXOTIC",999)
    writer:write("EPIC (top 20)\\n"); writeTierRows("EPIC",20)
    writer:write("EPIC (10 lowest FoodQuality)\\n")
    local lowEpic={}; for _,row in ipairs(eligible) do if row.result.tier == "EPIC" then table.insert(lowEpic,row) end end
    table.sort(lowEpic,function(a,b) return a.result.quality == b.result.quality and a.r.data.fullType < b.r.data.fullType or a.result.quality < b.result.quality end)
    for i,row in ipairs(lowEpic) do
        if i>10 then break end
        local r=row.r
        writer:write(string.format("%s | %s | quality=%s | final=%s | Hunger=%s | Calories=%s | Scarcity=%s\\n",r.data.fullType,r.functionalGroup,n(row.result.quality),n(row.result.blend),n(r.m.hungerBenefit),n(r.m.calories),n(r.scarcityStrength)))
    end
    writer:write("\\nPOSITIVE-CONSUMPTION-EFFECTS AUDIT (NOT ACTIVE; no FinalRarityTier changes)\\n")
    writer:write("B42 sign semantics confirmed from runtime/script values: UnhappyChange < 0 reduces unhappiness, BoredomChange < 0 reduces boredom, StressChange < 0 reduces stress. Positive values are costs and remain inside NegativeEffects. FoodSicknessChange < 0 is medical/toxin treatment rather than mood and is reported but deliberately excluded from MoodBenefit V1. Fatigue/Endurance have no observed vanilla Food declarations.\\n")
    writer:write("MoodBenefit uses separately robust p90-capped reductions per signal, then 50% unhappiness +20% boredom +30% stress. Stress is never put on the Unhappiness/Boredom scale. Candidate hierarchy models: A=60% Hunger/20% Mood; B=57%/23%; C=55%/25%; all retain 12% SAT600 Energy +5% Preservation +3% Convenience, POWER15, and a 95% quality/5% Scarcity diagnostic blend. SAT600 remains experimental here and is NOT frozen.\\n")
    local distributionSource=nil
    for _,r in ipairs(records) do if r.foodMoodExperiment then distributionSource=r.foodMoodExperiment.distributions; break end end
    if distributionSource then
        writer:write("MOOD BENEFIT DISTRIBUTIONS (absolute reduction; positives only; unique FOOD mechanical profiles) | signal | count | min | median | p75 | p90(cap) | p95 | max\\n")
        for _,key in ipairs({"unhappy","boredom","stress"}) do
            local d=distributionSource[key]
            writer:write(string.format("%s | %d | %s | %s | %s | %s | %s | %s\\n",key,d.count or 0,n(d.min),n(d.median),n(d.p75),n(d.p90),n(d.p95),n(d.max)))
        end
    end
    writer:write("fullType | function | Hunger | Calories | UnhappyChange | BoredomChange | StressChange | FoodSicknessChange | Mood(unhappy/boredom/stress/total) | EnergySAT600 | Preservation | Negative | POWER15 | A Q/final/tier | B Q/final/tier | C Q/final/tier | Scarcity\\n")
    local moodTargets={ ["Base.Icecream"]=true,["Base.IcecreamMelted"]=true,["Base.PizzaWhole"]=true,["Base.Chocolate_HeartBox"]=true,["Base.PeanutButter"]=true,["Base.MapleSyrup"]=true,["Base.Cereal"]=true,["Base.DogfoodOpen"]=true,["Base.Toast"]=true }
    for _,r in ipairs(records) do
        if moodTargets[r.data.fullType] then
            if not r.foodMoodExperiment then
                writer:write(r.data.fullType.." | "..r.functionalGroup.." | PARTIAL / not directly-scored FOOD\\n")
            else
                local c,e=r.foodQualityComponents,r.foodMoodExperiment
                local a,b,d=e.models.A,e.models.B,e.models.C
                writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s/%s/%s/%s | %s | %s | %s | %s | %s/%s/%s | %s/%s/%s | %s/%s/%s | %s\\n",r.data.fullType,r.functionalGroup,n(r.m.hungerBenefit),n(r.m.calories),n(r.m.unhappyChange),n(r.m.boredomChange),n(r.m.stressChange),n(r.m.foodSicknessChange),n(c.moodUnhappy),n(c.moodBoredom),n(c.moodStress),n(c.mood),n(e.energyNormalized),n(c.preservation),n(c.negative),n(negativeMultiplier(c.negative,"POWER15")),n(a.quality),n(a.blend),a.tier,n(b.quality),n(b.blend),b.tier,n(d.quality),n(d.blend),d.tier,n(r.scarcityStrength)))
            end
        end
    end
    writer:write("\\nICECREAM SANITY | Normal and melted Icecream have equivalent Hunger/Calories in the loaded runtime. Any higher normal-Icecream MoodFoodQuality comes only from declared negative Unhappy/Stress changes, never from name/fullType logic.\\n")
    writer:write("\\nFOODUTILITY V1 MODEL A — FROZEN CANDIDATE (NOT ACTIVE)\\n")
    writer:write("A = 60% Hunger +20% independently-normalized MoodBenefit +12% SAT600 Energy +5% Preservation +3% Convenience; POWER15 attenuation; final=95% quality +5% Scarcity. FOOD has Hydration=0. DRINK remains separate; PARTIAL is excluded.\\n")
    local frozenTiers={ COMMON=0,UNCOMMON=0,RARE=0,EPIC=0,EXOTIC=0 }
    local frozenRows={}
    for _,r in ipairs(records) do
        local result=r.foodMoodExperiment and r.foodMoodExperiment.models.A or nil
        if result then
            frozenTiers[result.tier]=frozenTiers[result.tier]+1
            table.insert(frozenRows,{ r=r, result=result })
        end
    end
    writer:write(string.format("ELIGIBLE FOOD MODEL-A | C/U/R/E/X=%d/%d/%d/%d/%d | total=%d\\n",frozenTiers.COMMON,frozenTiers.UNCOMMON,frozenTiers.RARE,frozenTiers.EPIC,frozenTiers.EXOTIC,#frozenRows))
    local function orderByQualityDescending(a,b)
        return a.result.quality == b.result.quality and a.r.data.fullType < b.r.data.fullType or a.result.quality > b.result.quality
    end
    local function writeFrozen(label, tier, limit, ascending)
        local rows={}
        for _,row in ipairs(frozenRows) do if row.result.tier == tier then table.insert(rows,row) end end
        table.sort(rows,ascending and function(a,b) return a.result.quality == b.result.quality and a.r.data.fullType < b.r.data.fullType or a.result.quality < b.result.quality end or orderByQualityDescending)
        writer:write(label.." | fullType | quality | final | Hunger | Mood | EnergySAT600 | Preservation | Negative | Scarcity\\n")
        for i,row in ipairs(rows) do
            if i>limit then break end
            local r,c=row.r,row.r.foodQualityComponents
            writer:write(string.format("%s | %s | %s | %s | %s | %s | %s | %s | %s\\n",r.data.fullType,n(row.result.quality),n(row.result.blend),n(r.m.hungerBenefit),n(c.mood),n(r.foodMoodExperiment.energyNormalized),n(c.preservation),n(c.negative),n(r.scarcityStrength)))
        end
    end
    writeFrozen("EXOTIC (all)","EXOTIC",999,false)
    writeFrozen("EPIC (10 lowest quality)","EPIC",10,true)
    writeFrozen("RARE (10 highest quality)","RARE",10,false)
    writeFunctionAudit(writer, records)
    writer:close()
    ItemRarityUtils.info("FoodQuality zero-aware experiment written (diagnostic only).")
end
