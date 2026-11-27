#pragma once

#include "CoreMinimal.h"
#include "Commandlets/Commandlet.h"
#include "GenerateArcaneWildsDamageBridgeCommandlet.generated.h"

UCLASS()
class UGenerateArcaneWildsDamageBridgeCommandlet : public UCommandlet
{
	GENERATED_BODY()

public:
	UGenerateArcaneWildsDamageBridgeCommandlet();
	virtual int32 Main(const FString& Params) override;
};
