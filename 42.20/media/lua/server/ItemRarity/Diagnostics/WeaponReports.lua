require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"

-- Historical WeaponUtility diagnostics. This module is loaded only by the
-- development-report path and never participates in WeaponUtility V2.
ItemRarityWeaponReports = ItemRarityWeaponReports or {}

function ItemRarityWeaponReports.writeV1ToV2(_)
    if not ItemRarityConfig.devReportsEnabled or not getFileWriter then return end
    local writer = getFileWriter("ItemRarity_WeaponUtilityV1toV2.txt", true, false)
    if not writer then return end
    writer:write("Item Rarity WeaponUtility V1 -> V2 historical archive\n")
    writer:write("The V1 runtime snapshot was removed after WeaponUtility V2 Model C10 was frozen.\n")
    writer:write("Historical V1-to-V2 outputs remain in prior Zomboid/Lua report files.\n")
    writer:write("The active pipeline calculates only WeaponUtility V2 and exposes no V1 fields in the registry.\n")
    writer:close()
    ItemRarityUtils.info("WeaponUtility V1 archive marker written to Zomboid/Lua/ItemRarity_WeaponUtilityV1toV2.txt.")
end
