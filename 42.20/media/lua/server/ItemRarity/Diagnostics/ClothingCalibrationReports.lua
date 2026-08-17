require "ItemRarity/RarityConfig"
require "ItemRarity/RarityUtils"

ItemRarityClothingCalibrationReports = ItemRarityClothingCalibrationReports or {}

-- Historical-only archive boundary.
--
-- The anatomy contribution, DIRECT_SLOT gate calibration, balanced EXOTIC
-- audit and Relative-vs-Absolute Protection proposals were all superseded by
-- the frozen ClothingUtility V1 P2/DIRECT_SLOT runtime. Their former outputs
-- remain in Zomboid/Lua reports and their experiments are intentionally not
-- reconstructed or executed during normal diagnostics.
local function archived(name)
    if ItemRarityConfig.devReportsEnabled then
        ItemRarityUtils.info("Historical Clothing diagnostic archived: " .. name .. " (inactive; ClothingUtility V1 unchanged).")
    end
end

function ItemRarityClothingCalibrationReports.writeAnatomicalContribution(_)
    archived("AnatomicalContribution")
end

function ItemRarityClothingCalibrationReports.writeDirectSlotCalibration(_)
    archived("DIRECT_SLOT gate / EXOTIC / RelativeAbsolute calibration")
end
