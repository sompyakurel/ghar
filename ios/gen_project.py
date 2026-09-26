#!/usr/bin/env python3
"""Generate Ghar.xcodeproj/project.pbxproj by hand.

A .xcodeproj is just a folder containing this one text file (plus an
optional shared scheme). Xcode reads it to learn: which Swift files belong
to the app, how to build them, and what the app is called.
"""
import re
from pathlib import Path

# Fixed 24-char hex IDs for every object in the project.
P = {
    "project":        "111111111111111111111111",
    "main_group":     "222222222222222222222222",
    "ghar_group":     "333333333333333333333333",
    "products_group": "444444444444444444444444",
    "target":         "555555555555555555555555",
    "app_ref":        "666666666666666666666666",
    "ref_gharapp":    "777777777777777777777777",
    "ref_contentview":"888888888888888888888888",
    "ref_models":     "999999999999999999999999",
    "ref_gharapi":    "AAAAAAAAAAAAAAAAAAAAAAAA",
    "build_gharapp":  "BBBBBBBBBBBBBBBBBBBBBBBB",
    "build_contentview": "CCCCCCCCCCCCCCCCCCCCCCCC",
    "build_models":   "DDDDDDDDDDDDDDDDDDDDDDDD",
    "build_gharapi":  "EEEEEEEEEEEEEEEEEEEEEEEE",
    "sources_phase":  "FFFFFFFFFFFFFFFFFFFFFFFF",
    "frameworks_phase": "121212121212121212121212",
    "resources_phase":  "343434343434343434343434",
    "proj_cfg_list":  "565656565656565656565656",
    "target_cfg_list":"787878787878787878787878",
    "proj_debug":     "9A9A9A9A9A9A9A9A9A9A9A9A",
    "proj_release":   "BCBCBCBCBCBCBCBCBCBCBCBC",
    "target_debug":   "DEDEDEDEDEDEDEDEDEDEDEDE",
    "target_release": "F0F0F0F0F0F0F0F0F0F0F0F0",
}

SWIFT_FILES = [
    ("ref_gharapp", "build_gharapp", "GharApp.swift"),
    ("ref_contentview", "build_contentview", "ContentView.swift"),
    ("ref_models", "build_models", "Models.swift"),
    ("ref_gharapi", "build_gharapi", "GharAPI.swift"),
]

build_files = "\n".join(
    f"\t\t{P[b]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {P[r]} /* {name} */; }};"
    for r, b, name in SWIFT_FILES
)
file_refs = "\n".join(
    f"\t\t{P[r]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};"
    for r, b, name in SWIFT_FILES
)

pbxproj = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{build_files}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{P["app_ref"]} /* Ghar.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Ghar.app; sourceTree = BUILT_PRODUCTS_DIR; }};
{file_refs}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{P["frameworks_phase"]} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{P["main_group"]} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["ghar_group"]} /* Ghar */,
\t\t\t\t{P["products_group"]} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{P["ghar_group"]} /* Ghar */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["ref_gharapp"]} /* GharApp.swift */,
\t\t\t\t{P["ref_contentview"]} /* ContentView.swift */,
\t\t\t\t{P["ref_models"]} /* Models.swift */,
\t\t\t\t{P["ref_gharapi"]} /* GharAPI.swift */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{P["products_group"]} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{P["app_ref"]} /* Ghar.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{P["target"]} /* Ghar */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {P["target_cfg_list"]} /* Build configuration list for PBXNativeTarget "Ghar" */;
\t\t\tbuildPhases = (
\t\t\t\t{P["sources_phase"]} /* Sources */,
\t\t\t\t{P["frameworks_phase"]} /* Frameworks */,
\t\t\t\t{P["resources_phase"]} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Ghar;
\t\t\tproductName = Ghar;
\t\t\tproductReference = {P["app_ref"]} /* Ghar.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{P["project"]} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tbuildConfigurationList = {P["proj_cfg_list"]} /* Build configuration list for PBXProject "Ghar" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {P["main_group"]};
\t\t\tproductRefGroup = {P["products_group"]} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{P["target"]} /* Ghar */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{P["resources_phase"]} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{P["sources_phase"]} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{P["build_gharapp"]} /* GharApp.swift in Sources */,
\t\t\t\t{P["build_contentview"]} /* ContentView.swift in Sources */,
\t\t\t\t{P["build_models"]} /* Models.swift in Sources */,
\t\t\t\t{P["build_gharapi"]} /* GharAPI.swift in Sources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{P["proj_debug"]} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{P["proj_release"]} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{P["target_debug"]} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Ghar;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.education";
\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.sompyakurel.Ghar;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{P["target_release"]} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = Ghar;
\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.education";
\t\t\t\tINFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
\t\t\t\tINFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
\t\t\t\tINFOPLIST_KEY_UILaunchScreen_Generation = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.sompyakurel.Ghar;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{P["proj_cfg_list"]} /* Build configuration list for PBXProject "Ghar" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{P["proj_debug"]} /* Debug */,
\t\t\t\t{P["proj_release"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{P["target_cfg_list"]} /* Build configuration list for PBXNativeTarget "Ghar" */ = {{
\t\t\t\tisa = XCConfigurationList;
\t\t\t\tbuildConfigurations = (
\t\t\t\t\t{P["target_debug"]} /* Debug */,
\t\t\t\t\t{P["target_release"]} /* Release */,
\t\t\t\t);
\t\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\t\tdefaultConfigurationName = Release;
\t\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {P["project"]} /* Project object */;
}}
"""

SCHEME = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.3">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{P["target"]}"
               BuildableName = "Ghar.app"
               BlueprintName = "Ghar"
               ReferencedContainer = "container:Ghar.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{P["target"]}"
            BuildableName = "Ghar.app"
            BlueprintName = "Ghar"
            ReferencedContainer = "container:Ghar.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{P["target"]}"
            BuildableName = "Ghar.app"
            BlueprintName = "Ghar"
            ReferencedContainer = "container:Ghar.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


def validate(text: str) -> None:
    defined = set(re.findall(r"^\t\t([0-9A-F]{24})(?: /\*.*?\*/)? = \{", text, re.M))
    # also catch "XXXX /* ... */ = {" occurrences already covered; plus rootObject refs
    referenced = set(re.findall(r"\b([0-9A-F]{24})\b", text))
    missing = referenced - defined
    assert not missing, f"referenced but not defined: {missing}"
    for name, pid in P.items():
        assert len(pid) == 24 and re.fullmatch(r"[0-9A-F]+", pid), f"bad id {name}"
    print(f"OK: {len(defined)} objects defined, all {len(referenced)} references resolve.")


def main() -> None:
    validate(pbxproj)
    out = Path.home() / "workspace" / "heritage-app" / "ios" / "Ghar.xcodeproj"
    (out / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)
    (out / "project.pbxproj").write_text(pbxproj, encoding="utf-8")
    (out / "xcshareddata" / "xcschemes" / "Ghar.xcscheme").write_text(SCHEME, encoding="utf-8")
    print(f"wrote {out}/project.pbxproj")
    print(f"wrote {out}/xcshareddata/xcschemes/Ghar.xcscheme")


if __name__ == "__main__":
    main()
