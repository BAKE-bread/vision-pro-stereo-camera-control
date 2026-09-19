"""Generate an ordinary Xcode project on Windows, without XcodeGen or file deletion."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
apple = root/'apple'
project = apple/'StereoStudio.xcodeproj'
project.mkdir(exist_ok=True)
objects = []


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def obj(name, contents):
    objects.append(f'{uid(name)} = {{ {contents} }};')
    return uid(name)


def quoted(value):
    return json.dumps(str(value), ensure_ascii=False)


source_ids, resource_ids, children = [], [], []
groups = {}
types = {'.swift': 'sourcecode.swift', '.usda': 'text', '.plist': 'text.plist.xml',
         '.metal': 'sourcecode.metal', '.xcprivacy': 'text.xml', '.strings': 'text.plist.strings',
         '.xcassets': 'folder.assetcatalog'}
for path in sorted((apple/'StereoStudio').rglob('*')):
    if path.suffix not in types or any(p.suffix == '.xcassets' for p in path.parents):
        continue
    relative = path.relative_to(apple).as_posix()
    kind = types[path.suffix]
    ref = obj(relative, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;')
    group = path.relative_to(apple/'StereoStudio').parts[0] if path.parent != apple/'StereoStudio' else 'Configuration'
    groups.setdefault(group, []).append(ref)
    if path.suffix != '.plist':
        build = obj('build:'+relative, f'isa = PBXBuildFile; fileRef = {ref};')
        (source_ids if path.suffix in ('.swift', '.metal') else resource_ids).append(build)
for name, refs in groups.items():
    children.append(obj('group:'+name, f'isa = PBXGroup; children = ({",".join(refs)},); name = {quoted(name)}; sourceTree = "<group>";'))

test_sources, test_children = [], []
for path in sorted((apple/'StereoStudioTests').rglob('*.swift')):
    relative = path.relative_to(apple).as_posix()
    ref = obj(relative, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;')
    test_children.append(ref)
    test_sources.append(obj('build:'+relative, f'isa = PBXBuildFile; fileRef = {ref};'))
children.append(obj('group:Tests', f'isa = PBXGroup; children = ({",".join(test_children)}); name = StereoStudioTests; sourceTree = "<group>";'))
obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = StereoStudio.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = StereoStudioTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
obj('products', f'isa = PBXGroup; children = ({uid("product")}, {uid("test-product")},); name = Products; sourceTree = "<group>";')
obj('rootgroup', f'isa = PBXGroup; children = ({",".join(children+[uid("products")])},); sourceTree = "<group>";')
obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(source_ids)},); runOnlyForDeploymentPostprocessing = 0;')
obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_ids)},); runOnlyForDeploymentPostprocessing = 0;')
obj('test-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(test_sources)}); runOnlyForDeploymentPostprocessing = 0;')
obj('test-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj('livekit-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/livekit/client-sdk-swift.git"; requirement = {kind = exactVersion; version = 2.17.0;};')
obj('livekit-product', f'isa = XCSwiftPackageProductDependency; package = {uid("livekit-package")}; productName = LiveKit;')
obj('livekit-build', f'isa = PBXBuildFile; productRef = {uid("livekit-product")};')
obj('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({uid("livekit-build")},); runOnlyForDeploymentPostprocessing = 0;')
for config in ('Debug', 'Release'):
    testability = 'YES' if config == 'Debug' else 'NO'
    obj('project-'+config, f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ CLANG_ENABLE_MODULES = YES; SDKROOT = xros; XROS_DEPLOYMENT_TARGET = 2.0; ENABLE_TESTABILITY = {testability}; DEBUG_INFORMATION_FORMAT = dwarf; ONLY_ACTIVE_ARCH = {testability}; "EXCLUDED_ARCHS[sdk=xrsimulator*]" = x86_64; }};')
    optimization = '"-Onone"' if config == 'Debug' else '"-O"'
    obj('target-'+config, f'''isa = XCBuildConfiguration; name = {config}; buildSettings = {{
        PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "io.bakebread.StereoStudio";
        INFOPLIST_FILE = StereoStudio/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = targeted; SWIFT_OPTIMIZATION_LEVEL = {optimization};
        TARGETED_DEVICE_FAMILY = 7; SUPPORTED_PLATFORMS = "xros xrsimulator";
        CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 0.1.0;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";
        ENABLE_USER_SCRIPT_SANDBOXING = YES;
    }};''')
    obj('tests-'+config, f'''isa = XCBuildConfiguration; name = {config}; buildSettings = {{
        PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = "io.bakebread.StereoStudio.Tests";
        GENERATE_INFOPLIST_FILE = YES; SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = targeted;
        SWIFT_OPTIMIZATION_LEVEL = {optimization}; TARGETED_DEVICE_FAMILY = 7;
        SUPPORTED_PLATFORMS = "xros xrsimulator"; CODE_SIGN_STYLE = Automatic;
        TEST_HOST = "$(BUILT_PRODUCTS_DIR)/StereoStudio.app/StereoStudio";
        BUNDLE_LOADER = "$(TEST_HOST)";
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks";
    }};''')
for target in ('project', 'target', 'tests'):
    obj(target+'-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(target+"-Debug")}, {uid(target+"-Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj('target', f'''isa = PBXNativeTarget; buildConfigurationList = {uid("target-configs")};
    buildPhases = ({uid("sources")}, {uid("frameworks")}, {uid("resources")},); buildRules = (); dependencies = ();
    name = StereoStudio; productName = StereoStudio; productReference = {uid("product")};
    productType = "com.apple.product-type.application"; packageProductDependencies = ({uid("livekit-product")},);''')
obj('test-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = StereoStudio;')
obj('test-dependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("test-proxy")};')
obj('tests', f'''isa = PBXNativeTarget; buildConfigurationList = {uid("tests-configs")};
    buildPhases = ({uid("test-sources")}, {uid("test-frameworks")},); buildRules = ();
    dependencies = ({uid("test-dependency")},); name = StereoStudioTests; productName = StereoStudioTests;
    productReference = {uid("test-product")}; productType = "com.apple.product-type.bundle.unit-test";''')
obj('project', f'''isa = PBXProject; attributes = {{ LastUpgradeCheck = 1630; }};
    buildConfigurationList = {uid("project-configs")}; compatibilityVersion = "Xcode 14.0";
    developmentRegion = en; knownRegions = (en, Base, "zh-Hans"); mainGroup = {uid("rootgroup")};
    productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = "";
    targets = ({uid("target")}, {uid("tests")},); packageReferences = ({uid("livekit-package")},);''')
text = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n'
(project/'project.pbxproj').write_text(text, encoding='utf-8')
schemes = project/'xcshareddata'/'xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="StereoStudio.app" BlueprintName="StereoStudio" ReferencedContainer="container:StereoStudio.xcodeproj"/>'
test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("tests")}" BuildableName="StereoStudioTests.xctest" BlueprintName="StereoStudioTests" ReferencedContainer="container:StereoStudio.xcodeproj"/>'
(schemes/'StereoStudio.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1630" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_reference}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''', encoding='utf-8')
print(project)

# Explicit opt-in scheme: never require a local service for ordinary unit tests.
local_scheme = (schemes/'StereoStudio.xcscheme').read_text(encoding='utf-8').replace(
    '</Testables></TestAction>',
    '</Testables><EnvironmentVariables><EnvironmentVariable key="STEREO_LOCAL_INTEGRATION" value="1" isEnabled="YES"/></EnvironmentVariables></TestAction>').replace(
    '<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES">',
    '<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO">')
(schemes/'StereoStudioLocal.xcscheme').write_text(local_scheme, encoding='utf-8')
