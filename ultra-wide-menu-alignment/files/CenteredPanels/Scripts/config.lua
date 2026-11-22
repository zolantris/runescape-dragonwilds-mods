local Config = {
    Enabled = true,
    CenterInventory = true,
    CenterContainers = true,
    CenterStations = true,
    CenterPauseMenu = true,
    MinX = 0.25,
    MaxX = 0.75,
    OffsetX = 0,
    SnapshotKeyPrimary = Key.NUM_SEVEN,
    SnapshotKeySecondary = Key.F7,
    ForceApplyKey = Key.NUM_EIGHT,
    NudgeRightKey = Key.ADD,
    NudgeLeftKey = Key.SUBTRACT,
    NudgeStepPx = 40,
    -- Exact Blueprint class names -> group key
    TargetPanels = {
        WBP_Inventory_MainPanel_C = "inventory",
        WBP_WorldActorInventory_MainPanel_C = "containers",
        WBP_Crafting_MainPanel_C = "stations",
        WBP_ProcessingStation_MainPanel_C = "stations",
        WBP_Composter_MainPanel_C = "stations",
        WBP_Enchanting_MainPanel_C = "stations",
        WBP_Building_MainPanel_C = "stations",
        WBP_Spellcasting_MainPanel_C = "stations",
        WBP_InGameScreensRoot_C = "pause_menu"
    }
}

return Config
