#pragma once

#include "Commandlets/Commandlet.h"
#include "ZenMatineeBridgeCommandlet.generated.h"

UCLASS()
class ZENMATINEEBRIDGE_API UZenMatineeBridgeCommandlet : public UCommandlet
{
    GENERATED_BODY()

public:
    UZenMatineeBridgeCommandlet();
    virtual int32 Main(const FString& Params) override;
};
