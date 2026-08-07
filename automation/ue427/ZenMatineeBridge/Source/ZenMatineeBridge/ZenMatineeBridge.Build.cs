using System.IO;
using UnrealBuildTool;

public class ZenMatineeBridge : ModuleRules
{
    public ZenMatineeBridge(ReadOnlyTargetRules Target) : base(Target)
    {
        PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

        string ConverterDirectory = Path.Combine(
            EngineDirectory,
            "Plugins",
            "MovieScene",
            "MatineeToLevelSequence",
            "Source",
            "MatineeToLevelSequence"
        );
        string ConverterPrivateDirectory = Path.Combine(ConverterDirectory, "Private");

        PrivateIncludePaths.AddRange(
            new string[]
            {
                Path.Combine(ConverterDirectory, "Public"),
                ConverterPrivateDirectory
            }
        );

        ExternalDependencies.Add(Path.Combine(ConverterPrivateDirectory, "MatineeConverter.cpp"));
        ExternalDependencies.Add(Path.Combine(ConverterPrivateDirectory, "MatineeToLevelSequenceConverter.cpp"));

        PrivateDependencyModuleNames.AddRange(
            new string[]
            {
                "Analytics",
                "AssetRegistry",
                "BlueprintGraph",
                "ContentBrowser",
                "Core",
                "CoreUObject",
                "EditorStyle",
                "Engine",
                "GameplayCameras",
                "InputCore",
                "Json",
                "Kismet",
                "LevelEditor",
                "LevelSequence",
                "MovieScene",
                "MovieSceneTools",
                "MovieSceneTracks",
                "Slate",
                "SlateCore",
                "TemplateSequence",
                "TimeManagement",
                "ToolMenus",
                "UnrealEd"
            }
        );

        PrivateIncludePathModuleNames.AddRange(
            new string[]
            {
                "AssetTools",
                "MovieSceneTools",
                "Settings",
                "WorkspaceMenuStructure"
            }
        );

        DynamicallyLoadedModuleNames.Add("AssetTools");
    }
}
