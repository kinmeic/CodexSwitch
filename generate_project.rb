#!/usr/bin/env ruby
# Generate Xcode project.pbxproj for CodexSwitch

require 'securerandom'

def gen_id
  SecureRandom.hex(12).upcase
end

# File definitions
swift_files = {
  "CodexSwitchApp" => "CodexSwitch/CodexSwitchApp.swift",
  "AppEnvironment" => "CodexSwitch/AppEnvironment.swift",
  "CodexProvider" => "CodexSwitch/Models/CodexProvider.swift",
  "AppState" => "CodexSwitch/ViewModels/AppState.swift",
  "ProxyServer" => "CodexSwitch/Services/ProxyServer.swift",
  "CodexConfigManager" => "CodexSwitch/Services/CodexConfigManager.swift",
  "ProtocolConverter" => "CodexSwitch/Services/ProtocolConverter.swift",
  "StreamingConverter" => "CodexSwitch/Services/StreamingConverter.swift",
  "ChatHistoryStore" => "CodexSwitch/Services/ChatHistoryStore.swift",
  "PresetProviders" => "CodexSwitch/Services/PresetProviders.swift",
  "MainWindow" => "CodexSwitch/Views/MainWindow.swift",
  "MenuBarMenu" => "CodexSwitch/Views/MenuBarMenu.swift",
  "DetailView" => "CodexSwitch/Views/DetailView.swift",
  "ConnectionStatusView" => "CodexSwitch/Views/ConnectionStatusView.swift",
  "ProviderListView" => "CodexSwitch/Views/ProviderListView.swift",
  "SettingsView" => "CodexSwitch/Views/SettingsView.swift",
}

other_files = {
  "Info.plist" => "CodexSwitch/Info.plist",
  "Entitlements" => "CodexSwitch/CodexSwitch.entitlements",
  "Assets" => "CodexSwitch/Assets.xcassets",
}

# Generate IDs
file_refs = {}
build_files = {}

swift_files.each do |name, path|
  file_refs[name] = gen_id
  build_files[name] = gen_id
end

other_files.each do |name, path|
  file_refs[name] = gen_id
end

# Assets needs a build file for the Resources phase
build_files["Assets"] = gen_id

# Groups
group_main = gen_id
group_source = gen_id
group_models = gen_id
group_viewmodels = gen_id
group_views = gen_id
group_services = gen_id

# Project and target
project_id = gen_id
target_id = gen_id
build_config_debug = gen_id
build_config_release = gen_id
target_config_debug = gen_id
target_config_release = gen_id
config_list_project = gen_id
config_list_target = gen_id
sources_phase = gen_id
resources_phase = gen_id
frameworks_phase = gen_id
product_ref = gen_id

# Generate file references
file_refs_section = ""
swift_files.each do |name, path|
  file_refs_section += "		#{file_refs[name]} /* #{name}.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"#{name}.swift\"; sourceTree = \"<group>\"; };\n"
end

file_refs_section += "		#{file_refs["Info.plist"]} /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };\n"
file_refs_section += "		#{file_refs["Entitlements"]} /* CodexSwitch.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = CodexSwitch.entitlements; sourceTree = \"<group>\"; };\n"
file_refs_section += "		#{file_refs["Assets"]} /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; };\n"

# Generate build files
build_files_section = ""
swift_files.each do |name, _|
  build_files_section += "		#{build_files[name]} /* #{name}.swift in Sources */ = {isa = PBXBuildFile; fileRef = #{file_refs[name]} /* #{name}.swift */; };\n"
end

# Assets build file for Resources phase
build_files_section += "		#{build_files["Assets"]} /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = #{file_refs["Assets"]} /* Assets.xcassets */; };\n"

$assets_build_id = build_files["Assets"]

# Generate groups
groups_section = ""

# Models group
groups_section += "		#{group_models} /* Models */ = {\n			isa = PBXGroup;\n			children = (\n				#{file_refs["CodexProvider"]} /* CodexProvider.swift */,\n			);\n			path = Models;\n			sourceTree = \"<group>\";\n		};\n"

# ViewModels group
groups_section += "		#{group_viewmodels} /* ViewModels */ = {\n			isa = PBXGroup;\n			children = (\n				#{file_refs["AppState"]} /* AppState.swift */,\n			);\n			path = ViewModels;\n			sourceTree = \"<group>\";\n		};\n"

# Views group
groups_section += "		#{group_views} /* Views */ = {\n			isa = PBXGroup;\n			children = (\n				#{file_refs["MainWindow"]} /* MainWindow.swift */,\n				#{file_refs["MenuBarMenu"]} /* MenuBarMenu.swift */,\n				#{file_refs["DetailView"]} /* DetailView.swift */,\n				#{file_refs["ConnectionStatusView"]} /* ConnectionStatusView.swift */,\n				#{file_refs["ProviderListView"]} /* ProviderListView.swift */,\n				#{file_refs["SettingsView"]} /* SettingsView.swift */,\n			);\n			path = Views;\n			sourceTree = \"<group>\";\n		};\n"

# Services group
groups_section += "		#{group_services} /* Services */ = {\n			isa = PBXGroup;\n			children = (\n				#{file_refs["ProxyServer"]} /* ProxyServer.swift */,\n				#{file_refs["CodexConfigManager"]} /* CodexConfigManager.swift */,\n				#{file_refs["ProtocolConverter"]} /* ProtocolConverter.swift */,\n				#{file_refs["StreamingConverter"]} /* StreamingConverter.swift */,\n				#{file_refs["ChatHistoryStore"]} /* ChatHistoryStore.swift */,\n				#{file_refs["PresetProviders"]} /* PresetProviders.swift */,\n			);\n			path = Services;\n			sourceTree = \"<group>\";\n		};\n"

# Source group (main)
groups_section += "		#{group_source} /* CodexSwitch */ = {\n			isa = PBXGroup;\n			children = (\n				#{file_refs["CodexSwitchApp"]} /* CodexSwitchApp.swift */,\n				#{file_refs["AppEnvironment"]} /* AppEnvironment.swift */,\n				#{group_models} /* Models */,\n				#{group_viewmodels} /* ViewModels */,\n				#{group_views} /* Views */,\n				#{group_services} /* Services */,\n				#{file_refs["Assets"]} /* Assets.xcassets */,\n				#{file_refs["Info.plist"]} /* Info.plist */,\n				#{file_refs["Entitlements"]} /* CodexSwitch.entitlements */,\n			);\n			path = CodexSwitch;\n			sourceTree = \"<group>\";\n		};\n"

# Main group
groups_section += "		#{group_main} = {\n			isa = PBXGroup;\n			children = (\n				#{group_source} /* CodexSwitch */,\n			);\n			sourceTree = \"<group>\";\n		};\n"

# Sources build phase
sources_files = swift_files.map { |name, _| "				#{build_files[name]} /* #{name}.swift in Sources */," }.join("\n")

# Build configurations
debug_settings = {
  "ALWAYS_SEARCH_USER_PATHS" => "NO",
  "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS" => "YES",
  "CLANG_ANALYZER_NONNULL" => "YES",
  "CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION" => "YES_AGGRESSIVE",
  "CLANG_CXX_LANGUAGE_STANDARD" => "gnu++20",
  "CLANG_ENABLE_MODULES" => "YES",
  "CLANG_ENABLE_OBJC_ARC" => "YES",
  "CLANG_ENABLE_OBJC_WEAK" => "YES",
  "CLANG_WARN_BLOCK_CAPTURE_AUTORELEASING" => "YES",
  "CLANG_WARN_BOOL_CONVERSION" => "YES",
  "CLANG_WARN_COMMA" => "YES",
  "CLANG_WARN_CONSTANT_CONVERSION" => "YES",
  "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS" => "YES",
  "CLANG_WARN_DIRECT_OBJC_ISA_USAGE" => "YES_ERROR",
  "CLANG_WARN_DOCUMENTATION_COMMENTS" => "YES",
  "CLANG_WARN_EMPTY_BODY" => "YES",
  "CLANG_WARN_ENUM_CONVERSION" => "YES",
  "CLANG_WARN_INFINITE_RECURSION" => "YES",
  "CLANG_WARN_INT_CONVERSION" => "YES",
  "CLANG_WARN_NON_LITERAL_NULL_CONVERSION" => "YES",
  "CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF" => "YES",
  "CLANG_WARN_OBJC_LITERAL_CONVERSION" => "YES",
  "CLANG_WARN_OBJC_ROOT_CLASS" => "YES_ERROR",
  "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER" => "YES",
  "CLANG_WARN_RANGE_LOOP_ANALYSIS" => "YES",
  "CLANG_WARN_STRICT_PROTOTYPES" => "YES",
  "CLANG_WARN_SUSPICIOUS_MOVE" => "YES",
  "CLANG_WARN_UNGUARDED_AVAILABILITY" => "YES_AGGRESSIVE",
  "CLANG_WARN_UNREACHABLE_CODE" => "YES",
  "CLANG_WARN__DUPLICATE_METHOD_MATCH" => "YES",
  "COPY_PHASE_STRIP" => "NO",
  "DEBUG_INFORMATION_FORMAT" => "dwarf",
  "ENABLE_STRICT_OBJC_MSGSEND" => "YES",
  "ENABLE_TESTABILITY" => "YES",
  "ENABLE_USER_SCRIPT_SANDBOXING" => "YES",
  "GCC_C_LANGUAGE_STANDARD" => "gnu17",
  "GCC_DYNAMIC_NO_PIC" => "NO",
  "GCC_NO_COMMON_BLOCKS" => "YES",
  "GCC_OPTIMIZATION_LEVEL" => "0",
  "GCC_PREPROCESSOR_DEFINITIONS" => ["DEBUG=1", "$(inherited)"],
  "GCC_WARN_64_TO_32_BIT_CONVERSION" => "YES",
  "GCC_WARN_ABOUT_RETURN_TYPE" => "YES_ERROR",
  "GCC_WARN_UNDECLARED_SELECTOR" => "YES",
  "GCC_WARN_UNINITIALIZED_AUTOS" => "YES_AGGRESSIVE",
  "GCC_WARN_UNUSED_FUNCTION" => "YES",
  "GCC_WARN_UNUSED_VARIABLE" => "YES",
  "MACOSX_DEPLOYMENT_TARGET" => "13.0",
  "MTL_ENABLE_DEBUG_INFO" => "INCLUDE_SOURCE",
  "MTL_FAST_MATH" => "YES",
  "ONLY_ACTIVE_ARCH" => "YES",
  "SDKROOT" => "macosx",
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS" => "DEBUG $(inherited)",
  "SWIFT_OPTIMIZATION_LEVEL" => "-Onone",
  "SWIFT_VERSION" => "5.0",
}

release_settings = debug_settings.merge({
  "DEBUG_INFORMATION_FORMAT" => "dwarf-with-dsym",
  "ENABLE_NS_ASSERTIONS" => "NO",
  "MTL_ENABLE_DEBUG_INFO" => "NO",
  "SWIFT_COMPILATION_MODE" => "wholemodule",
  "SWIFT_OPTIMIZATION_LEVEL" => "-O",
}).delete_if { |k, _| ["DEBUG", "GCC_OPTIMIZATION_LEVEL", "GCC_DYNAMIC_NO_PIC", "ENABLE_TESTABILITY", "SWIFT_ACTIVE_COMPILATION_CONDITIONS"].include?(k) }

release_settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited)"
release_settings["COPY_PHASE_STRIP"] = "NO"

target_settings = {
  "ASSETCATALOG_COMPILER_APPICON_NAME" => "AppIcon",
  "CODE_SIGN_ENTITLEMENTS" => "CodexSwitch/CodexSwitch.entitlements",
  "CODE_SIGN_STYLE" => "Manual",
  "COMBINE_HIDPI_IMAGES" => "YES",
  "CURRENT_PROJECT_VERSION" => "1",
  "DEVELOPMENT_TEAM" => "",
  "ENABLE_HARDENED_RUNTIME" => "YES",
  "GENERATE_INFOPLIST_FILE" => "NO",
  "INFOPLIST_FILE" => "CodexSwitch/Info.plist",
  "INFOPLIST_KEY_NSHumanReadableCopyright" => "",
  "LD_RUNPATH_SEARCH_PATHS" => ["$(inherited)", "@executable_path/../Frameworks"],
  "MACOSX_DEPLOYMENT_TARGET" => "13.0",
  "MARKETING_VERSION" => "1.0.0",
  "PRODUCT_BUNDLE_IDENTIFIER" => "com.codex.switch",
  "PRODUCT_NAME" => "$(TARGET_NAME)",
  "SWIFT_EMIT_LOC_STRINGS" => "YES",
  "SWIFT_VERSION" => "5.0",
}

def format_settings(settings)
  lines = []
  settings.each do |key, value|
    if value.is_a?(Array)
      arr = value.map { |v| "					\"#{v}\"," }.join("\n")
      lines += [
        "				#{key} = (",
        arr,
        "				);"
      ]
    elsif value.is_a?(String)
      lines += ["				#{key} = \"#{value}\";"]
    end
  end
  lines.join("\n")
end

debug_settings_str = format_settings(debug_settings)
release_settings_str = format_settings(release_settings)
target_settings_str = format_settings(target_settings)

# Output
pbxproj = <<~PROJ
	// !$*UTF8*$!
	{
		archiveVersion = 1;
		classes = {
		};
		objectVersion = 56;
		objects = {

	/* Begin PBXBuildFile section */
#{build_files_section}	/* End PBXBuildFile section */

	/* Begin PBXFileReference section */
#{file_refs_section}	/* End PBXFileReference section */

	/* Begin PBXFrameworksBuildPhase section */
		#{frameworks_phase} /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
	/* End PBXFrameworksBuildPhase section */

	/* Begin PBXGroup section */
#{groups_section}	/* End PBXGroup section */

	/* Begin PBXNativeTarget section */
		#{target_id} /* CodexSwitch */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = #{config_list_target} /* Build configuration list for PBXNativeTarget "CodexSwitch" */;
			buildPhases = (
				#{sources_phase} /* Sources */,
				#{frameworks_phase} /* Frameworks */,
				#{resources_phase} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = CodexSwitch;
			productName = CodexSwitch;
			productReference = #{product_ref} /* CodexSwitch.app */;
			productType = "com.apple.product-type.application";
		};
	/* End PBXNativeTarget section */

	/* Begin PBXProject section */
		#{project_id} /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {
					#{target_id} = {
						CreatedOnToolsVersion = 15.0;
					};
				};
			};
			buildConfigurationList = #{config_list_project} /* Build configuration list for PBXProject "CodexSwitch" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = #{group_main};
			productRefGroup = #{group_source} /* CodexSwitch */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				#{target_id} /* CodexSwitch */,
			);
		};
	/* End PBXProject section */

	/* Begin PBXResourcesBuildPhase section */
		#{resources_phase} /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				#{$assets_build_id} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
	/* End PBXResourcesBuildPhase section */

	/* Begin PBXSourcesBuildPhase section */
		#{sources_phase} /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
#{sources_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
	/* End PBXSourcesBuildPhase section */

	/* Begin XCBuildConfiguration section */
		#{build_config_debug} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
#{debug_settings_str}
			};
			name = Debug;
		};
		#{build_config_release} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
#{release_settings_str}
			};
			name = Release;
		};
		#{target_config_debug} /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
#{target_settings_str}
			};
			name = Debug;
		};
		#{target_config_release} /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
#{target_settings_str}
			};
			name = Release;
		};
	/* End XCBuildConfiguration section */

	/* Begin XCConfigurationList section */
		#{config_list_project} /* Build configuration list for PBXProject "CodexSwitch" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{build_config_debug} /* Debug */,
				#{build_config_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		#{config_list_target} /* Build configuration list for PBXNativeTarget "CodexSwitch" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{target_config_debug} /* Debug */,
				#{target_config_release} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
	/* End XCConfigurationList section */
		};
		rootObject = #{project_id} /* Project object */;
	}
PROJ

# Write project.pbxproj
Dir.mkdir("CodexSwitch.xcodeproj") unless Dir.exist?("CodexSwitch.xcodeproj")
File.write("CodexSwitch.xcodeproj/project.pbxproj", pbxproj)
puts "Generated CodexSwitch.xcodeproj/project.pbxproj"
