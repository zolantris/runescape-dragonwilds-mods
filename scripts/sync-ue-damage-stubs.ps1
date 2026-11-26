<#
.SYNOPSIS
    Syncs ONLY the minimal Dominion damage & floaties UHT interface headers from the gitignored
    UHTHeaderDump/Dominion/ folder into unreal-engine/RSDragonwilds/Source/Dominion/ so the UE 5.6
    project compiles cleanly in seconds for cooking Blueprint damage-bridge .pak mods.
#>
[CmdletBinding()]
param(
    [string]$HeaderDumpDir,
    [string]$TargetModuleDir
)

$ErrorActionPreference = "Stop"

$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if (-not $HeaderDumpDir) {
    $HeaderDumpDir = Join-Path $RepoRoot "UHTHeaderDump\Dominion"
}
if (-not $TargetModuleDir) {
    $TargetModuleDir = Join-Path $RepoRoot "unreal-engine\RSDragonwilds\Source\Dominion"
}

$SrcPublic = Join-Path $HeaderDumpDir "Public"
if (-not (Test-Path $SrcPublic)) {
    throw "UHTHeaderDump Dominion Public directory not found at: $SrcPublic`nRun UE4SS UHT dumper first and place UHTHeaderDump/ at repo root."
}

$DstPublic  = Join-Path $TargetModuleDir "Public"
$DstPrivate = Join-Path $TargetModuleDir "Private"

if (Test-Path $TargetModuleDir) {
    Remove-Item $TargetModuleDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $DstPublic, $DstPrivate | Out-Null

# Exact minimal header subset needed for Dominion Blueprint damage & floaties interfaces
$MinimalHeaders = @(
    "EDamageClass.h",
    "EStatusEffectType.h",
    "ETypeDamageOutcome.h",
    "EReactionDirectionality.h",
    "EDomDamageFloatiesStrategy.h",
    "EBlockResult.h",
    "EAnimaAttunementType.h",
    "DomId.h",
    "DominionDataAssetNetId.h",
    "DominionGameplayEffectHandle.h",
    "DominionGameplayEffectHandlesArray.h",
    "TypeDamage.h",
    "TypeDamageArray.h",
    "BlockOutcome.h",
    "DominionDamageEvent.h",
    "DominionPointDamageEvent.h",
    "FatalDamageInfo.h",
    "FloatiesModifierCollection.h",
    "OnDamageReceivedSignatureDynamicDelegate.h",
    "OnWillReceiveDamageDynamicDelegate.h",
    "DamageFunctionLibrary.h",
    "Damageable.h",
    "DamageComponent.h",
    "AiDamageComponent.h",
    "DamageFloatiesSubsystem.h",
    "DamageInflictionComponent.h"
)

# Headers that reference opaque Dominion UObject/AActor/UUserWidget classes in TSubclassOf/TWeakObjectPtr/UPROPERTY
$HeadersNeedingStubTypes = @(
    "BlockOutcome.h",
    "DominionDamageEvent.h",
    "DominionPointDamageEvent.h",
    "DominionGameplayEffectHandle.h",
    "FloatiesModifierCollection.h",
    "DamageFunctionLibrary.h",
    "Damageable.h",
    "DamageComponent.h",
    "DamageFloatiesSubsystem.h",
    "DamageInflictionComponent.h"
)

function Transform-UhtHeader {
    param(
        [string]$FileName,
        [string]$Content
    )

    $lines = $Content -split "`r?`n"
    $out = New-Object System.Collections.Generic.List[string]
    $addedIncludes = New-Object System.Collections.Generic.HashSet[string]

    function Add-IncludeOnce([string]$IncLine) {
        if ($addedIncludes.Add($IncLine)) {
            $out.Add($IncLine)
        }
    }

    foreach ($line in $lines) {
        # Map UE4SS CROSS-MODULE INCLUDE V2 comments to stock UE 5.6 includes
        if ($line -match 'CROSS-MODULE INCLUDE V2:.*-ObjectName=(\w+)') {
            $objName = $Matches[1]
            switch ($objName) {
                "BlueprintFunctionLibrary" { Add-IncludeOnce '#include "Kismet/BlueprintFunctionLibrary.h"' }
                "Vector_NetQuantize"       { Add-IncludeOnce '#include "Engine/NetSerialization.h"' }
                "Vector_NetQuantizeNormal" { Add-IncludeOnce '#include "Engine/NetSerialization.h"' }
                "GameplayTag"              { Add-IncludeOnce '#include "GameplayTagContainer.h"' }
                "GameplayTagContainer"     { Add-IncludeOnce '#include "GameplayTagContainer.h"' }
                "WorldSubsystem"           { Add-IncludeOnce '#include "Subsystems/WorldSubsystem.h"' }
                "SceneComponent"           { Add-IncludeOnce '#include "Components/SceneComponent.h"' }
                "ActorComponent"           { Add-IncludeOnce '#include "Components/ActorComponent.h"' }
                "Interface"                { Add-IncludeOnce '#include "UObject/Interface.h"' }
                "JgxSingleNativeComponentHostComponent" { Add-IncludeOnce '#include "Components/ActorComponent.h"' }
                "JgxNativeComponentReplacement"         { } # Stripped; not needed for Blueprint compilation
                default { } # CoreUObject Vector/Transform/etc. already in CoreMinimal.h
            }
            continue
        }

        # Inject DominionDamageStubTypes.h right before the .generated.h include where needed
        if (($HeadersNeedingStubTypes -contains $FileName) -and $line -match '^\s*#include\s+".*\.generated\.h"\s*$') {
            Add-IncludeOnce '#include "DominionDamageStubTypes.h"'
        }

        $fixedLine = $line
        if ($FileName -eq "DamageComponent.h") {
            $fixedLine = $fixedLine -replace 'public UJgxSingleNativeComponentHostComponent,\s*public IJgxNativeComponentReplacement', 'public UActorComponent'
            $fixedLine = $fixedLine -replace '^class UDamageComponent\s*:', 'class DOMINION_API UDamageComponent :'
        }
        elseif ($FileName -eq "AiDamageComponent.h") {
            $fixedLine = $fixedLine -replace '^class UAiDamageComponent\s*:', 'class DOMINION_API UAiDamageComponent :'
        }
        elseif ($FileName -eq "DamageFloatiesSubsystem.h") {
            $fixedLine = $fixedLine -replace '^class UDamageFloatiesSubsystem\s*:', 'class DOMINION_API UDamageFloatiesSubsystem :'
        }

        $out.Add($fixedLine)
    }

    return ($out -join "`r`n") + "`r`n"
}

Write-Host "=== Syncing Minimal Dominion Damage Stubs ===" -ForegroundColor Cyan
Write-Host "Source : $SrcPublic"
Write-Host "Target : $TargetModuleDir"

$copied = 0
foreach ($hdr in $MinimalHeaders) {
    $srcFile = Join-Path $SrcPublic $hdr
    if (-not (Test-Path $srcFile)) {
        throw "Required header missing in UHTHeaderDump: $srcFile"
    }
    $raw = Get-Content -Path $srcFile -Raw
    $transformed = Transform-UhtHeader -FileName $hdr -Content $raw
    Set-Content -Path (Join-Path $DstPublic $hdr) -Value $transformed -Encoding UTF8 -NoNewline
    $copied++
}

# 1. Minimal opaque UCLASS stubs referenced by pointer/TSubclassOf in the damage headers
$stubTypesH = @'
#pragma once
#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "GameFramework/Actor.h"
#include "DominionDamageStubTypes.generated.h"

// Minimal opaque stubs for Dominion types referenced as pointers / TSubclassOf by the damage interfaces.
// None of these are cooked into the mod .pak; they only allow UnrealHeaderTool & UnrealEditor to
// compile Blueprints referencing /Script/Dominion damage functions.

UCLASS(Blueprintable)
class DOMINION_API UFloatAttribute : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable)
class DOMINION_API UEquipment : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, EditInlineNew)
class DOMINION_API UDominionShape : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, EditInlineNew)
class DOMINION_API UDominionGameplayEffectData : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, ClassGroup=Custom)
class DOMINION_API UDominionGameplayEffectsComponent : public UActorComponent { GENERATED_BODY() };

UCLASS(Blueprintable)
class DOMINION_API USkillData : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable)
class DOMINION_API UDamageModifier : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, EditInlineNew)
class DOMINION_API UFatalDamageEventBase : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, ClassGroup=Custom)
class DOMINION_API UHitPointsComponent : public UActorComponent { GENERATED_BODY() };

UCLASS(Blueprintable, ClassGroup=Custom)
class DOMINION_API UHitReactionsComponent : public UActorComponent { GENERATED_BODY() };

UCLASS(Blueprintable, ClassGroup=Custom)
class DOMINION_API UGameplayTagsComponent : public UActorComponent { GENERATED_BODY() };

UCLASS(Blueprintable)
class DOMINION_API UFloatiesModifier : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable)
class DOMINION_API AFloatiesManager : public AActor { GENERATED_BODY() };

UCLASS(Blueprintable, EditInlineNew)
class DOMINION_API UFloatingDamageWidget : public UObject { GENERATED_BODY() };

UCLASS(Blueprintable, EditInlineNew)
class DOMINION_API UFloatingTextWidget : public UObject { GENERATED_BODY() };
'@
Set-Content -Path (Join-Path $DstPublic "DominionDamageStubTypes.h") -Value $stubTypesH -Encoding UTF8

# 2. Dominion.Build.cs (stock UE 5.6 dependencies ONLY - no Jagex/SPUD/EOS/CommonUI needed!)
$buildCs = @'
using UnrealBuildTool;

public class Dominion : ModuleRules
{
	public Dominion(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
		bLegacyPublicIncludePaths = false;

		PublicDependencyModuleNames.AddRange(new string[]
		{
			"Core",
			"CoreUObject",
			"Engine",
			"GameplayTags"
		});
	}
}
'@
Set-Content -Path (Join-Path $TargetModuleDir "Dominion.Build.cs") -Value $buildCs -Encoding UTF8

# 3. DominionModule.cpp
$moduleCpp = @'
#include "Modules/ModuleManager.h"

IMPLEMENT_PRIMARY_GAME_MODULE(FDefaultGameModuleImpl, Dominion, "Dominion");
'@
Set-Content -Path (Join-Path $DstPrivate "DominionModule.cpp") -Value $moduleCpp -Encoding UTF8

# 4. Single consolidated stub implementation file for all minimal damage structs & classes
$stubsCpp = @'
#include "Net/UnrealNetwork.h"
#include "DomId.h"
#include "DominionDataAssetNetId.h"
#include "DominionGameplayEffectHandle.h"
#include "DominionGameplayEffectHandlesArray.h"
#include "TypeDamage.h"
#include "TypeDamageArray.h"
#include "BlockOutcome.h"
#include "DominionDamageEvent.h"
#include "DominionPointDamageEvent.h"
#include "FatalDamageInfo.h"
#include "FloatiesModifierCollection.h"
#include "DamageFunctionLibrary.h"
#include "Damageable.h"
#include "DamageComponent.h"
#include "AiDamageComponent.h"
#include "DamageFloatiesSubsystem.h"
#include "DamageInflictionComponent.h"

// Struct constructors
FDomId::FDomId() : Value(0) {}
FDominionDataAssetNetId::FDominionDataAssetNetId() : NetId(0) {}
FDominionGameplayEffectHandle::FDominionGameplayEffectHandle() {}
FDominionGameplayEffectHandlesArray::FDominionGameplayEffectHandlesArray() : ArraySize(0) {}
FTypeDamage::FTypeDamage() : StatusEffect(EStatusEffectType::None), Amount(0.0f) {}
FTypeDamageArray::FTypeDamageArray() : ArraySize(0) {}

FBlockOutcome::FBlockOutcome()
	: Equipment(nullptr)
	, Result(EBlockResult::NotBlocking)
	, DamageMitigationPercentage(0.0f)
	, StaminaCost(0.0f)
	, ParryRefund(0.0f)
	, bParried(false)
	, bSpecialParry(false)
	, bPassiveBlock(false)
	, bEquipmentShouldLoseDurability(false)
	, bWasBlockableAttack(false)
{}

FDominionDamageEvent::FDominionDamageEvent()
	: Amount(0.0f)
	, AmountAbsorbedByShield(0.0f)
	, DamageClass(EDamageClass::None)
	, Instigator(nullptr)
	, Source(nullptr)
	, Directionality(EReactionDirectionality::UpToDown)
	, Force(0.0f)
	, AttackProperties(0)
	, StaminaCostMultiplier(0.0f)
	, HitReaction(nullptr)
	, DamageProperties(0)
	, AttackId(0)
	, bIsFatalHit(false)
	, Seed(0)
	, CachedDamageShouldHitReact(false)
	, ID(0)
{}

FDominionPointDamageEvent::FDominionPointDamageEvent()
	: DamageShape(nullptr)
	, DamageBlocked(0.0f)
{}

FFatalDamageInfo::FFatalDamageInfo()
	: KilledByPowerLevel(0.0f)
	, KilledByStatusEffectFlags(0)
	, bIsSet(false)
{}

FFloatiesModifierCollection::FFloatiesModifierCollection() {}

// UDamageFunctionLibrary
UDamageFunctionLibrary::UDamageFunctionLibrary() {}

TSubclassOf<UFloatAttribute> UDamageFunctionLibrary::GetResistanceClass(const EStatusEffectType Type)
{
	return nullptr;
}

bool UDamageFunctionLibrary::ApplyPointDamage(AActor* Target, const FDominionPointDamageEvent& PointDamageEvent)
{
	return false;
}

bool UDamageFunctionLibrary::ApplyDamage(AActor* Target, const FDominionDamageEvent& DamageEvent)
{
	return false;
}

// UDamageComponent
UDamageComponent::UDamageComponent(const FObjectInitializer& ObjectInitializer) : Super(ObjectInitializer)
{
	DefaultSkillUsedToDamageThisActor = nullptr;
	DamagedByDurabilityMultiplier = 1.0f;
	bCanReceiveCriticalHits = false;
	bShowDamageFloaties = true;
	bCanTakeDamage = true;
	bAwardsXPThroughPlayerDamageComponent = true;
}

void UDamageComponent::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);
	DOREPLIFETIME(UDamageComponent, FatalDamageInfo);
}

bool UDamageComponent::SetIsInvulnerable(bool bValue, const UObject* LockerObj) { return false; }
void UDamageComponent::SetCanTakeDamage(bool bValue) {}
void UDamageComponent::SetCanShowDamageFloaties(bool bInCanShowDamageFloaties) {}

FDominionDamageEvent UDamageComponent::PredictDamage(
	EDamageClass DamageClass, TArray<FTypeDamage> TypeDamages, float ApplicationTime,
	AActor* Instigator, UObject* Source, const FVector& Location,
	EReactionDirectionality Directionality, float Force, int32 AttackId)
{
	return FDominionDamageEvent{};
}

void UDamageComponent::OnRep_FatalDamageInfo() {}
void UDamageComponent::Multicast_ApplyPointDamageFromGameplayEffect_Implementation(const FDominionPointDamageEvent& PointDamageEvent, EDomDamageFloatiesStrategy FloatiesStrategy) {}
void UDamageComponent::Multicast_ApplyDamageFromGameplayEffect_Implementation(const FDominionDamageEvent& DamageEvent, EDomDamageFloatiesStrategy FloatiesStrategy) {}
USkillData* UDamageComponent::GetSkillUsedToDamageThisActor() const { return nullptr; }
bool UDamageComponent::CanTakeDamage() const { return false; }
bool UDamageComponent::CanBeDamagedBy_Implementation(const AActor* Instigator) const { return false; }

FDominionPointDamageEvent UDamageComponent::BP_PredictPointDamage(
	EDamageClass DamageClass, TArray<FTypeDamage> TypeDamages, float ApplicationTime,
	AActor* Instigator, UObject* Source, const FVector& Location, const FVector& Direction,
	EReactionDirectionality Directionality, float Force,
	TArray<UDominionGameplayEffectData*> OptionalGameplayEffectsToApply,
	int32 DamageProperties, int32 AttackProperties, int32 AttackId, float StaminaCostMultiplier,
	const UDominionShape* DamageShape, const FTransform& DamageShapeTransform,
	FName WeakPointEventName, bool bCanCauseCrits, bool bApplyGEsIfBlocked,
	float ParryWindowExtensionMs, const FVector& OverrideInstigatorLocation)
{
	return FDominionPointDamageEvent{};
}

void UDamageComponent::ApplyDamageFromGameplayEffect(const FDominionDamageEvent& DamageEvent, const bool bShowDamageFloatieIfZeroDamage, const bool bMulticast) {}

// UAiDamageComponent
UAiDamageComponent::UAiDamageComponent(const FObjectInitializer& ObjectInitializer) : Super(ObjectInitializer) {}
EAnimaAttunementType UAiDamageComponent::GetAppliedAnimaChargeAttunement() const { return EAnimaAttunementType::None; }
void UAiDamageComponent::AdjustPowerLevelForDamageInfliction(float AdditionalPowerLevel) {}

// UDamageFloatiesSubsystem
UDamageFloatiesSubsystem::UDamageFloatiesSubsystem()
{
	bShouldCreate = false;
	InitialWidgetCount = 16;
	DistanceFloatieOffsetCurve = nullptr;
	StatusEffectFloatieOffset = 25.0f;
	DamageWidgetClass = nullptr;
	TextWidgetClass = nullptr;
	FloatiesManager = nullptr;
}

void UDamageFloatiesSubsystem::DisplayText(const FText& Text, const FVector& Location) const {}
void UDamageFloatiesSubsystem::DisplayDamage(float Damage, const FVector& Location) const {}

// UDamageInflictionComponent
UDamageInflictionComponent::UDamageInflictionComponent(const FObjectInitializer& ObjectInitializer) : Super(ObjectInitializer)
{
	DamageAmount = 0.0f;
	DamageCooldown = 0.0f;
	DamageClass = EDamageClass::None;
	AttackPropertyFlags = 0;
	DamageForce = 0.0f;
	bCanCrit = false;
}

void UDamageInflictionComponent::Multicast_ApplyDamage_Implementation(UDamageComponent* DamageComponent, const FDominionPointDamageEvent& DamageEvent) {}
void UDamageInflictionComponent::InflictDamageWithLocationAndOrigin(AActor* Actor, const FVector& HitLocation, const FVector& DamageOrigin, const bool bOverrideInstigatorLocWithDamageOrigin) {}
void UDamageInflictionComponent::InflictDamage(AActor* Actor) {}
'@
Set-Content -Path (Join-Path $DstPrivate "DominionDamageStubs.cpp") -Value $stubsCpp -Encoding UTF8

Write-Host "Synced $copied minimal Dominion damage headers + stubs into: $TargetModuleDir" -ForegroundColor Green
