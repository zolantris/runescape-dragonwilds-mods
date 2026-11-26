#include "GenerateArcaneWildsDamageBridgeCommandlet.h"

#include "AssetRegistry/AssetRegistryModule.h"
#include "Components/ActorComponent.h"
#include "DamageComponent.h"
#include "DamageFunctionLibrary.h"
#include "EDamageClass.h"
#include "EReactionDirectionality.h"
#include "EdGraph/EdGraph.h"
#include "EdGraphSchema_K2.h"
#include "Engine/Blueprint.h"
#include "Engine/BlueprintGeneratedClass.h"
#include "GameFramework/Actor.h"
#include "K2Node_CallFunction.h"
#include "K2Node_DynamicCast.h"
#include "K2Node_FunctionEntry.h"
#include "K2Node_FunctionResult.h"
#include "K2Node_MakeArray.h"
#include "K2Node_MakeStruct.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "Kismet/GameplayStatics.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Misc/PackageName.h"
#include "TypeDamage.h"
#include "UObject/Package.h"
#include "UObject/SavePackage.h"

DEFINE_LOG_CATEGORY_STATIC(LogArcaneWildsBPGen, Log, All);

namespace
{
	bool ConnectPins(const UEdGraphSchema_K2* Schema, UEdGraphPin* FromPin, UEdGraphPin* ToPin, const TCHAR* Label)
	{
		if (!FromPin || !ToPin)
		{
			UE_LOG(LogArcaneWildsBPGen, Error, TEXT("Missing pin for connection [%s]: From=%s To=%s"),
				Label, FromPin ? *FromPin->PinName.ToString() : TEXT("NULL"), ToPin ? *ToPin->PinName.ToString() : TEXT("NULL"));
			return false;
		}
		const bool bOk = Schema->TryCreateConnection(FromPin, ToPin);
		if (!bOk)
		{
			UE_LOG(LogArcaneWildsBPGen, Error, TEXT("TryCreateConnection failed [%s]: %s -> %s"),
				Label, *FromPin->PinName.ToString(), *ToPin->PinName.ToString());
		}
		return bOk;
	}

	template <typename TNode>
	TNode* SpawnNode(UEdGraph* Graph, int32 PosX, int32 PosY)
	{
		TNode* Node = NewObject<TNode>(Graph);
		Node->CreateNewGuid();
		Node->NodePosX = PosX;
		Node->NodePosY = PosY;
		Graph->AddNode(Node, false, false);
		return Node;
	}
}

UGenerateArcaneWildsDamageBridgeCommandlet::UGenerateArcaneWildsDamageBridgeCommandlet()
{
	IsClient = false;
	IsEditor = true;
	IsServer = false;
	LogToConsole = true;
}

int32 UGenerateArcaneWildsDamageBridgeCommandlet::Main(const FString& Params)
{
	const FString PackagePath = TEXT("/Game/Mods/ArcaneWilds/BFL_ArcaneWildsDamage");
	const FString AssetName   = TEXT("BFL_ArcaneWildsDamage");

	UE_LOG(LogArcaneWildsBPGen, Display, TEXT("Generating Blueprint Function Library: %s"), *PackagePath);

	UPackage* Package = CreatePackage(*PackagePath);
	if (!Package)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("Failed to create package %s"), *PackagePath);
		return 1;
	}
	Package->FullyLoad();

	// Replace any existing Blueprint in the package cleanly
	if (UObject* Existing = StaticFindObject(UBlueprint::StaticClass(), Package, *AssetName))
	{
		Existing->Rename(nullptr, GetTransientPackage(), REN_DontCreateRedirectors | REN_NonTransactional);
	}

	UBlueprint* BP = FKismetEditorUtilities::CreateBlueprint(
		UBlueprintFunctionLibrary::StaticClass(),
		Package,
		FName(*AssetName),
		BPTYPE_FunctionLibrary,
		UBlueprint::StaticClass(),
		UBlueprintGeneratedClass::StaticClass(),
		FName(TEXT("ArcaneWildsBPGen"))
	);
	if (!BP)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("FKismetEditorUtilities::CreateBlueprint failed"));
		return 1;
	}

	// Create function graph: ApplyArcaneWildsDamage
	UEdGraph* FuncGraph = FBlueprintEditorUtils::CreateNewGraph(
		BP,
		FName(TEXT("ApplyArcaneWildsDamage")),
		UEdGraph::StaticClass(),
		UEdGraphSchema_K2::StaticClass()
	);
	FBlueprintEditorUtils::AddFunctionGraph<UFunction>(BP, FuncGraph, /*bIsUserCreated=*/true, static_cast<UFunction*>(nullptr));

	const UEdGraphSchema_K2* Schema = CastChecked<UEdGraphSchema_K2>(FuncGraph->GetSchema());

	// Locate auto-created FunctionEntry node
	UK2Node_FunctionEntry* EntryNode = nullptr;
	for (UEdGraphNode* Node : FuncGraph->Nodes)
	{
		if (UK2Node_FunctionEntry* Candidate = Cast<UK2Node_FunctionEntry>(Node))
		{
			EntryNode = Candidate;
			break;
		}
	}
	if (!EntryNode)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("FunctionEntry node missing from new function graph"));
		return 1;
	}

	EntryNode->AddExtraFlags(FUNC_Public | FUNC_Static | FUNC_BlueprintCallable);

	// Define input parameters matching ArcaneWilds Lua Tier 1 call
	FEdGraphPinType ActorPinType;
	ActorPinType.PinCategory = UEdGraphSchema_K2::PC_Object;
	ActorPinType.PinSubCategoryObject = AActor::StaticClass();

	FEdGraphPinType FloatPinType;
	FloatPinType.PinCategory = UEdGraphSchema_K2::PC_Real;
	FloatPinType.PinSubCategory = UEdGraphSchema_K2::PC_Float;

	FEdGraphPinType DamageClassPinType;
	DamageClassPinType.PinCategory = UEdGraphSchema_K2::PC_Byte;
	DamageClassPinType.PinSubCategoryObject = StaticEnum<EDamageClass>();

	FEdGraphPinType VectorPinType;
	VectorPinType.PinCategory = UEdGraphSchema_K2::PC_Struct;
	VectorPinType.PinSubCategoryObject = TBaseStructure<FVector>::Get();

	FEdGraphPinType IntPinType;
	IntPinType.PinCategory = UEdGraphSchema_K2::PC_Int;

	FEdGraphPinType BoolPinType;
	BoolPinType.PinCategory = UEdGraphSchema_K2::PC_Boolean;

	UEdGraphPin* PinTarget       = EntryNode->CreateUserDefinedPin(FName(TEXT("Target")), ActorPinType, EGPD_Output);
	UEdGraphPin* PinInstigator   = EntryNode->CreateUserDefinedPin(FName(TEXT("Instigator")), ActorPinType, EGPD_Output);
	UEdGraphPin* PinDamageAmount = EntryNode->CreateUserDefinedPin(FName(TEXT("DamageAmount")), FloatPinType, EGPD_Output);
	UEdGraphPin* PinDamageClass  = EntryNode->CreateUserDefinedPin(FName(TEXT("DamageClass")), DamageClassPinType, EGPD_Output);
	UEdGraphPin* PinHitLoc       = EntryNode->CreateUserDefinedPin(FName(TEXT("HitLocation")), VectorPinType, EGPD_Output);
	UEdGraphPin* PinInstLoc      = EntryNode->CreateUserDefinedPin(FName(TEXT("InstigatorLocation")), VectorPinType, EGPD_Output);
	UEdGraphPin* PinForce        = EntryNode->CreateUserDefinedPin(FName(TEXT("Force")), FloatPinType, EGPD_Output);
	UEdGraphPin* PinAttackId     = EntryNode->CreateUserDefinedPin(FName(TEXT("AttackId")), IntPinType, EGPD_Output);
	(void)PinInstLoc;

	// Node 1: Target->GetComponentByClass(UDamageComponent::StaticClass())
	UK2Node_CallFunction* GetCompNode = SpawnNode<UK2Node_CallFunction>(FuncGraph, 250, 0);
	GetCompNode->FunctionReference.SetExternalMember(FName(TEXT("GetComponentByClass")), AActor::StaticClass());
	GetCompNode->AllocateDefaultPins();

	if (UEdGraphPin* CompClassPin = GetCompNode->FindPin(TEXT("ComponentClass")))
	{
		CompClassPin->DefaultObject = UDamageComponent::StaticClass();
	}

	// Node 2: Cast to UDamageComponent
	UK2Node_DynamicCast* CastNode = SpawnNode<UK2Node_DynamicCast>(FuncGraph, 550, 0);
	CastNode->TargetType = UDamageComponent::StaticClass();
	CastNode->AllocateDefaultPins();

	// Node 3: Make FTypeDamage struct (Amount = DamageAmount)
	UK2Node_MakeStruct* MakeTypeDmgNode = SpawnNode<UK2Node_MakeStruct>(FuncGraph, 550, 260);
	MakeTypeDmgNode->StructType = FTypeDamage::StaticStruct();
	MakeTypeDmgNode->AllocateDefaultPins();

	// Node 4: MakeArray<FTypeDamage> with 1 element
	UK2Node_MakeArray* MakeArrNode = SpawnNode<UK2Node_MakeArray>(FuncGraph, 820, 260);
	MakeArrNode->NumInputs = 1;
	MakeArrNode->AllocateDefaultPins();

	// Node 5: UGameplayStatics::GetTimeSeconds(Instigator)
	UK2Node_CallFunction* GetTimeNode = SpawnNode<UK2Node_CallFunction>(FuncGraph, 550, 460);
	GetTimeNode->FunctionReference.SetExternalMember(FName(TEXT("GetTimeSeconds")), UGameplayStatics::StaticClass());
	GetTimeNode->AllocateDefaultPins();

	// Node 6: UDamageComponent::PredictDamage(...)
	UK2Node_CallFunction* PredictNode = SpawnNode<UK2Node_CallFunction>(FuncGraph, 1080, 0);
	PredictNode->FunctionReference.SetExternalMember(FName(TEXT("PredictDamage")), UDamageComponent::StaticClass());
	PredictNode->AllocateDefaultPins();

	if (UEdGraphPin* DirPin = PredictNode->FindPin(TEXT("Directionality")))
	{
		DirPin->DefaultValue = TEXT("Outwards");
	}

	// Node 7: UDamageFunctionLibrary::ApplyDamage(Target, DamageEvent)
	UK2Node_CallFunction* ApplyDmgNode = SpawnNode<UK2Node_CallFunction>(FuncGraph, 1500, 0);
	ApplyDmgNode->FunctionReference.SetExternalMember(FName(TEXT("ApplyDamage")), UDamageFunctionLibrary::StaticClass());
	ApplyDmgNode->AllocateDefaultPins();

	// Node 8a: FunctionResult (success path)
	UK2Node_FunctionResult* ReturnOkNode = SpawnNode<UK2Node_FunctionResult>(FuncGraph, 1850, 0);
	ReturnOkNode->AllocateDefaultPins();
	UEdGraphPin* PinReturnOk = ReturnOkNode->CreateUserDefinedPin(FName(TEXT("ReturnValue")), BoolPinType, EGPD_Input);

	// Node 8b: FunctionResult (cast failed -> false)
	UK2Node_FunctionResult* ReturnFailNode = SpawnNode<UK2Node_FunctionResult>(FuncGraph, 880, -180);
	ReturnFailNode->AllocateDefaultPins();
	UEdGraphPin* PinReturnFail = ReturnFailNode->CreateUserDefinedPin(FName(TEXT("ReturnValue")), BoolPinType, EGPD_Input);
	if (PinReturnFail)
	{
		PinReturnFail->DefaultValue = TEXT("false");
	}

	// Wire Data Pins
	bool bAllWired = true;
	bAllWired &= ConnectPins(Schema, PinTarget, GetCompNode->FindPin(UEdGraphSchema_K2::PN_Self), TEXT("Target->GetComp.Self"));
	bAllWired &= ConnectPins(Schema, GetCompNode->GetReturnValuePin(), CastNode->GetCastSourcePin(), TEXT("GetComp->Cast.Object"));

	bAllWired &= ConnectPins(Schema, PinDamageAmount, MakeTypeDmgNode->FindPin(TEXT("Amount")), TEXT("DamageAmount->MakeTypeDamage.Amount"));
	bAllWired &= ConnectPins(Schema, MakeTypeDmgNode->FindPin(FTypeDamage::StaticStruct()->GetFName()), MakeArrNode->FindPin(TEXT("[0]")), TEXT("MakeTypeDamage->MakeArray[0]"));

	bAllWired &= ConnectPins(Schema, PinInstigator, GetTimeNode->FindPin(TEXT("WorldContextObject")), TEXT("Instigator->GetTimeSeconds"));

	bAllWired &= ConnectPins(Schema, CastNode->GetCastResultPin(), PredictNode->FindPin(UEdGraphSchema_K2::PN_Self), TEXT("Cast->PredictDamage.Self"));
	bAllWired &= ConnectPins(Schema, PinDamageClass, PredictNode->FindPin(TEXT("DamageClass")), TEXT("DamageClass->PredictDamage"));
	bAllWired &= ConnectPins(Schema, MakeArrNode->GetOutputPin(), PredictNode->FindPin(TEXT("TypeDamages")), TEXT("MakeArray->PredictDamage.TypeDamages"));
	bAllWired &= ConnectPins(Schema, GetTimeNode->GetReturnValuePin(), PredictNode->FindPin(TEXT("ApplicationTime")), TEXT("TimeSeconds->PredictDamage.ApplicationTime"));
	bAllWired &= ConnectPins(Schema, PinInstigator, PredictNode->FindPin(TEXT("Instigator")), TEXT("Instigator->PredictDamage.Instigator"));
	bAllWired &= ConnectPins(Schema, PinInstigator, PredictNode->FindPin(TEXT("Source")), TEXT("Instigator->PredictDamage.Source"));
	bAllWired &= ConnectPins(Schema, PinHitLoc, PredictNode->FindPin(TEXT("Location")), TEXT("HitLocation->PredictDamage.Location"));
	bAllWired &= ConnectPins(Schema, PinForce, PredictNode->FindPin(TEXT("Force")), TEXT("Force->PredictDamage.Force"));
	bAllWired &= ConnectPins(Schema, PinAttackId, PredictNode->FindPin(TEXT("AttackId")), TEXT("AttackId->PredictDamage.AttackId"));

	bAllWired &= ConnectPins(Schema, PinTarget, ApplyDmgNode->FindPin(TEXT("Target")), TEXT("Target->ApplyDamage.Target"));
	bAllWired &= ConnectPins(Schema, PredictNode->GetReturnValuePin(), ApplyDmgNode->FindPin(TEXT("DamageEvent")), TEXT("PredictDamage->ApplyDamage.DamageEvent"));
	bAllWired &= ConnectPins(Schema, ApplyDmgNode->GetReturnValuePin(), PinReturnOk, TEXT("ApplyDamage->ReturnValue"));

	// Wire Exec Pins
	bAllWired &= ConnectPins(Schema, EntryNode->FindPin(UEdGraphSchema_K2::PN_Then), CastNode->GetExecPin(), TEXT("Entry->Cast.Exec"));
	bAllWired &= ConnectPins(Schema, CastNode->GetValidCastPin(), PredictNode->GetExecPin(), TEXT("CastOk->PredictDamage.Exec"));
	bAllWired &= ConnectPins(Schema, CastNode->GetInvalidCastPin(), ReturnFailNode->GetExecPin(), TEXT("CastFail->ReturnFail.Exec"));
	bAllWired &= ConnectPins(Schema, PredictNode->GetThenPin(), ApplyDmgNode->GetExecPin(), TEXT("PredictDamage->ApplyDamage.Exec"));
	bAllWired &= ConnectPins(Schema, ApplyDmgNode->GetThenPin(), ReturnOkNode->GetExecPin(), TEXT("ApplyDamage->ReturnOk.Exec"));

	if (!bAllWired)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("One or more Blueprint pin connections failed."));
		return 1;
	}

	// Mark modified & compile Blueprint bytecode
	FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(BP);
	FKismetEditorUtilities::CompileBlueprint(BP, EBlueprintCompileOptions::None);

	if (BP->Status == BS_Error)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("Blueprint compilation failed with errors!"));
		return 1;
	}

	FAssetRegistryModule::AssetCreated(BP);
	Package->MarkPackageDirty();

	const FString PackageFilename = FPackageName::LongPackageNameToFilename(PackagePath, FPackageName::GetAssetPackageExtension());
	IFileManager::Get().MakeDirectory(*FPaths::GetPath(PackageFilename), true);

	FSavePackageArgs SaveArgs;
	SaveArgs.TopLevelFlags = RF_Public | RF_Standalone;
	SaveArgs.Error = GError;
	SaveArgs.SaveFlags = SAVE_NoError;

	const bool bSaved = UPackage::SavePackage(Package, BP, *PackageFilename, SaveArgs);
	if (!bSaved)
	{
		UE_LOG(LogArcaneWildsBPGen, Error, TEXT("Failed to save Blueprint package to %s"), *PackageFilename);
		return 1;
	}

	UE_LOG(LogArcaneWildsBPGen, Display, TEXT("Successfully generated, compiled, and saved: %s"), *PackageFilename);
	return 0;
}
