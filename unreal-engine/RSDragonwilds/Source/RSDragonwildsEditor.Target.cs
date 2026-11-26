using UnrealBuildTool;
using System.Collections.Generic;

public class RSDragonwildsEditorTarget : TargetRules
{
	public RSDragonwildsEditorTarget(TargetInfo Target) : base(Target)
	{
		Type = TargetType.Editor;
		DefaultBuildSettings = BuildSettingsVersion.V5;
		IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_6;
		ExtraModuleNames.AddRange(new string[] { "Dominion", "DominionEditor" });
	}
}
