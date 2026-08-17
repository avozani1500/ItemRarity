ItemRarityClothingReports = ItemRarityClothingReports or {}

-- Development-only entry point. Dependencies are loaded lazily from
-- UtilityCalculator.writeReports(), so normal runtime scans never load them.
function ItemRarityClothingReports.writeAll(results)
    ItemRarityClothingWearabilityReports.write(results)
    ItemRarityClothingComparabilityReports.write(results)
    ItemRarityClothingSlotSimulationReports.writeV3(results)
    ItemRarityClothingEquipmentReports.write(results)
    ItemRarityClothingCalibrationReports.writeDirectSlotCalibration(results)
    ItemRarityClothingDiscoveryReports.writeDiscovery(results)
    ItemRarityClothingDiscoveryReports.writeActivation(results)
end
