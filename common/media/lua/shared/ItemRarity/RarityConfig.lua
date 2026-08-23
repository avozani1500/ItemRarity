-- Experimental analysis settings. This mod never changes game loot.
ItemRarityConfig = ItemRarityConfig or {}

-- "A" = relative-table baseline, "B" = nominal item chance plus declared rolls,
-- "C" = equal-pool-exposure aggregation of B.  The selected value is only
-- reported; all three values are calculated for comparison.
ItemRarityConfig.tableAvailabilityStrategy = "A"

-- Strategy D is a normalized table-route approximation.  These are not game
-- multipliers and never affect loot generation.
ItemRarityConfig.poolExposure = {
    conditionalRouteFactor = 0.45,
    roomCoverageWeight = 0.50,
    containerCoverageWeight = 0.50,
}

-- Tier boundaries are percentile ranges inside an item's functional category.
-- Lower Strategy D percentile means lower modeled availability and therefore a
-- rarer tier. `maxExclusive` prevents overlaps at the experimental boundaries.
ItemRarityConfig.tierOrder = { "EXOTIC", "EPIC", "RARE", "UNCOMMON", "COMMON" }
ItemRarityConfig.tiers = {
    EXOTIC = { min = 0, max = 5, maxExclusive = true },
    EPIC = { min = 5, max = 15, maxExclusive = true },
    RARE = { min = 15, max = 35, maxExclusive = true },
    UNCOMMON = { min = 35, max = 65, maxExclusive = true },
    COMMON = { min = 65, max = 100, maxExclusive = false },
}

-- Confidence says how completely Strategy D's route model covers this item;
-- it does not change the score or prevent tier assignment.
ItemRarityConfig.routeCoverageConfidence = {
    highMinimum = 90,
    mediumMinimum = 70,
}

-- Visual-only MVP settings. These colors use the 0..1 RGBA values expected by
-- ISPanel/ObjectTooltip rendering. COMMON deliberately stays near vanilla.
ItemRarityConfig.visuals = {
    COMMON = { label = "Common", translationKey = "UI_ItemRarity_Common", color = { r = 0.90, g = 0.90, b = 0.90, a = 1.00 } },
    UNCOMMON = { label = "Uncommon", translationKey = "UI_ItemRarity_Uncommon", color = { r = 0.38, g = 0.82, b = 0.38, a = 1.00 } },
    RARE = { label = "Rare", translationKey = "UI_ItemRarity_Rare", color = { r = 0.36, g = 0.60, b = 1.00, a = 1.00 } },
    EPIC = { label = "Epic", translationKey = "UI_ItemRarity_Epic", color = { r = 0.72, g = 0.42, b = 0.94, a = 1.00 } },
    EXOTIC = { label = "Exotic", translationKey = "UI_ItemRarity_Exotic", color = { r = 1.00, g = 0.66, b = 0.20, a = 1.00 } },
}

-- RGB lives only in `visuals`; these are presentation-only opacities.
ItemRarityConfig.visualEffects = {
    UNCOMMON = { borderAlpha = 0.62 },
    RARE = { borderAlpha = 0.68 },
    EPIC = { borderAlpha = 0.76, glowAlpha = 0.18 },
    EXOTIC = { borderAlpha = 0.82, glowAlpha = 0.24 },
}

-- Internal development option. It is intentionally not a Sandbox option.
ItemRarityConfig.debugTooltip = false

-- Name colors are the primary MVP UI. The tooltip is kept as an optional
-- secondary detail, because scanning lists item-by-item defeats its purpose.
ItemRarityConfig.showTooltip = true

-- Server-owned global ModData key used by the singleplayer visual MVP.
ItemRarityConfig.registryModDataKey = "ItemRarity.Registry.v1"

-- Single switch for investigation/calibration output. Runtime logging,
-- Strategy D, Utility, FinalRarityTier, registry publishing and UI remain
-- active when this is false.
ItemRarityConfig.devReportsEnabled = false

-- Detailed scanner reports remain available for development, but are disabled
-- by default now that the normal mod behavior is visual lookup only.
ItemRarityConfig.diagnosticsEnabled = false

-- Experimental category utility.  This is deliberately independent from
-- Strategy D: scarcity always establishes the base tier and these values can
-- only request a one-tier refinement after the availability calculation.
ItemRarityConfig.utility = {
    enabled = true,
    -- The UI reads the server-published final tier only. It never calculates
    -- availability, Utility or percentiles during rendering.
    publishFinalTierToUI = true,
    diagnosticsEnabled = true,

    promotionThreshold = 85,
    demotionThreshold = 20,
    exoticUtilityThreshold = 95,
    exoticMinimumScarcity = 85,
    minimumConfidenceForAdjustment = "MEDIUM",
    exoticMinimumConfidence = "HIGH",

    -- Percentile ranks are calculated from unique mechanical profiles, after
    -- clamping each metric to these group-local quantiles.
    normalization = {
        winsorLowPercentile = 5,
        winsorHighPercentile = 95,
        minimumProfiles = 12,
        highConfidenceProfiles = 20,
        minimumValidAttributes = 3,
        highConfidenceValidAttributes = 4,
    },

    container = {
        promotionThreshold = 85,
        weights = {
            capacity = 0.35,
            weightReduction = 0.35,
            emptyWeight = 0.15,
            runSpeedModifier = 0.10,
            attachments = 0.05,
        },
        essential = { "capacity", "weightReduction" },
        -- ContainerUtility V2 compares only structurally equivalent slots.
        -- Each group's reference population is vanilla-only; loaded mods are
        -- scored against that stable reference but never reshape it.
        v2 = {
            utilityVersion = "V2_STRUCTURAL_VANILLA_REFERENCE",
            groups = {
                BACK = {
                    weights = { capacity = 0.35, weightReduction = 0.35, emptyWeight = 0.15, attachments = 0.05 },
                    essential = { "capacity", "weightReduction" },
                },
                TORSO_GENERAL = {
                    weights = { capacity = 0.25, weightReduction = 0.30, attachments = 0.30, emptyWeight = 0.15 },
                    essential = { "capacity", "weightReduction" },
                },
                FANNY_PACK = {
                    weights = { capacity = 0.50, weightReduction = 0.30, emptyWeight = 0.20 },
                    essential = { "capacity", "weightReduction" },
                },
                TORSO_AMMO = { weights = {}, essential = {} },
                KEY_CONTAINER = { weights = {}, essential = {} },
            },
        },
    },

    meleeWeapon = {
        -- Active V2 is the validated Model C with a deliberately small (10%)
        -- player-neutral tempo signal. It is not a DPS calculation: the B42
        -- animation owns real attack delay through SetMeleeDelay.
        utilityVersion = "V2_MODEL_C10",
        v2 = {
            offense = { averageDamage = 0.45, runtimeCritical = 0.25, multiHit = 0.20, attackTempo = 0.10 },
            efficiency = { strainProxy = 0.70, weight = 0.30 },
            control = { range = 0.60, knockdown = 0.40 },
            architecture = { offense = 0.45, efficiency = 0.25, control = 0.15, reliability = 0.15 },
            softBalance = { threshold = 35, factor = 0.125 },
        },
    },

    -- ClothingUtility is calculated for diagnostics only in this stage. Its
    -- score intentionally does not participate in active FinalRarityTier or
    -- UI publication until its simulation has been reviewed.
    clothing = {
        utilityVersion = "V1_EXPERIMENTAL",
        architecture = { protectionCoverage = 0.60, mobility = 0.15, weight = 0.10, durability = 0.10, weatherProtection = 0.05 },
        protection = { biteDefense = 0.50, scratchDefense = 0.35, bulletDefense = 0.15 },
        mobility = { runSpeedModifier = 0.70, combatSpeedModifier = 0.30 },
        weather = { insulation = 0.40, windResistance = 0.35, waterResistance = 0.25 },
        coverage = { minimumFactor = 0.70, maximumFactor = 1.00 },
        essential = { "biteDefense", "scratchDefense", "bulletDefense", "coverageEvidenceCount", "weight", "durability", "runSpeedModifier", "combatSpeedModifier", "insulation", "windResistance", "waterResistance" },
    },

    -- MedicalUtility V1 compares only treatments for the same medical
    -- problem. Efficacy dominates; real uses are secondary. Weight remains
    -- diagnostic-only because its gameplay cost is contextual for medicine.
    medical = {
        utilityVersion = "V1_EFFECT_90_USES_10",
        efficacyWeight = 0.90,
        usesWeight = 0.10,
        weightWeight = 0.00,
        mediumConfidenceProfiles = 2,
        highConfidenceProfiles = 8,
    },

    -- FoodUtility V1 deliberately has a different rarity philosophy from
    -- weapons/clothing: direct consumption quality establishes the tier band;
    -- scarcity is only a small refinement and an EXOTIC companion condition.
    food = {
        utilityVersion = "V1_H60_M20_E12_P5_C3_POWER15_SAT600",
        food = { hunger = 0.60, mood = 0.20, energy = 0.12, preservation = 0.05, convenience = 0.03 },
        mood = { unhappy = 0.50, boredom = 0.20, stress = 0.30, capPercentile = 90 },
        drink = { hunger = 0.10, energy = 0.10, hydration = 0.60, preservation = 0.10, convenience = 0.10 },
        energyHalfSaturationCalories = 600,
        negativePower = 1.5,
        negativeFactor = 0.80,
        scarcityWeight = 0.05,
        mediumConfidenceProfiles = 8,
        highConfidenceProfiles = 20,
        -- FoodQuality bands are intentionally absolute-quality bands, not
        -- percentiles. Scarcity may qualify an otherwise exceptional FOOD
        -- for EXOTIC but cannot rescue a weak consumable.
        tiers = { uncommon = 30, rare = 50, epic = 70, exotic = 85, exoticMinimumScarcity = 60 },
    },

    -- FishUtility is intentionally independent from FoodUtility. Fish stats
    -- are generated per instance from Fishing.onCreateFish, so this V1
    -- integrates the declared species size distribution instead of reading a
    -- random InventoryItem. Yield determines the ceiling; catch difficulty
    -- can only position a species inside that ceiling.
    fish = {
        utilityVersion = "V1_YIELD_H80_CAL20_SAT2000_DIFFICULTY_S60_P20_B20_MODEL_C",
        expectedYield = { hunger = 0.80, calories = 0.20, caloriesHalfSaturation = 2000 },
        catchDifficulty = { minimumSkill = 0.60, predatorReel = 0.20, baitProfile = 0.20 },
        position = { expectedYield = 0.80, catchDifficulty = 0.20 },
        -- All vanilla Fishing.onCreateFish species declare 159 base kcal in
        -- B42. The ScriptItem bridge does not reliably expose that component;
        -- this is a documented B42 fishing-system fallback, not an item rule.
        declaredBaseCaloriesFallback = 159,
        yieldTiers = { uncommon = 20, rare = 30, epic = 60, exotic = 85 },
    },

    -- LightFireUtility V1 has deliberately separate functional axes. Light
    -- sources are judged by what they illuminate and their drain duration;
    -- ignition sources are judged only by stable start-fire uses. A dual item
    -- takes the better resulting tier, never a combined score. Neither axis
    -- may produce EXOTIC in V1.
    lightFire = {
        utilityVersion = "V1_LIGHT85_DURATION15_FIRE_ABSOLUTE_EPIC_CAP",
        light = { illumination = 0.85, duration = 0.15, maxTier = "EPIC" },
        fireUses = { uncommon = 20, rare = 40, epic = 60, maxTier = "EPIC" },
    },

    -- Literature V1 is structural: SkillBook position alone owns its tier;
    -- reading mood has a bounded RARE ceiling; permanent recipes are scored
    -- from their unique LearnedRecipes; all remaining special literature is
    -- PARTIAL until its distinct mechanics are measured.
    literature = {
        utilityVersion = "V1_SKILLBOOK_MAP_MOOD_RECIPE_TRIVIAL",
        skillbookTiers = { [1] = "COMMON", [2] = "UNCOMMON", [3] = "RARE", [4] = "EPIC", [5] = "EXOTIC" },
        -- `LootMaps.Init[MapID]` is client-only vanilla Lua, while the
        -- scanner owns the server registry.  These are the MapIDs whose
        -- callbacks were verified in the local B42.20.2 ISMapDefinitions.lua.
        -- The key is MapID (the game's structural map identity), never an
        -- item fullType or city/display name. Unknown/modded MapIDs remain
        -- SPECIAL_PARTIAL until a client-to-server callback bridge exists.
        confirmedRevealMapIds = {
            LouisvilleMap1 = true, LouisvilleMap2 = true, LouisvilleMap3 = true,
            LouisvilleMap4 = true, LouisvilleMap5 = true, LouisvilleMap6 = true,
            LouisvilleMap7 = true, LouisvilleMap8 = true, LouisvilleMap9 = true,
            MarchRidgeMap = true, MuldraughMap = true, RiversideMap = true,
            RosewoodMap = true, WestpointMap = true,
        },
        mapFinalTier = "RARE",
        entertainment = { unhappyCap = 40, boredomCap = 50, stressCap = 50, uncommonMinimum = 25, rareMinimum = 60 },
        recipe = {
            recipeValueDenominatorOffset = 3,
            recipeValueWeight = 0.70,
            scarcityStrengthWeight = 0.30,
            tiers = { uncommon = 30, rare = 50, epic = 70, exotic = 85 },
        },
    },
}
