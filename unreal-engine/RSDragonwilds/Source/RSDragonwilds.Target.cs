using UnrealBuildTool;
using System.Collections.Generic;

public class RSDragonwildsTarget : TargetRules
{
	public RSDragonwildsTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Game;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_6;
		ExtraModuleNames.Add("Dominion");
	}
}
