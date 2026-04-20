// Copyright 2026 The ODML Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "runtime/util/litert_util.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <CoreFoundation/CoreFoundation.h>
#include "litert/c/litert_any.h"  // from @litert
#include "litert/c/litert_environment.h"  // from @litert
#include "litert/c/litert_environment_options.h"  // from @litert
#include "runtime/core/metal_handles_ios.h"
#endif  // TARGET_OS_IPHONE
#endif  // __APPLE__

#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "absl/base/no_destructor.h"  // from @com_google_absl
#include "absl/log/absl_log.h"  // from @com_google_absl
#include "absl/status/statusor.h"  // from @com_google_absl
#include "litert/cc/litert_environment.h"  // from @litert
#include "litert/cc/litert_environment_options.h"  // from @litert
#include "litert/cc/litert_macros.h"  // from @litert
#include "runtime/components/model_resources.h"
#include "runtime/engine/engine_settings.h"
#include "runtime/executor/executor_settings_base.h"
#include "runtime/executor/magic_number_configs_helper.h"
#include "runtime/util/logging.h"

namespace litert::lm {

absl::StatusOr<Environment&> GetEnvironment(EngineSettings& engine_settings,
                                            ModelResources* model_resources) {
  // Helper must be available until LlmLiteRtCompiledModelExecutor::Create() is
  // called. Since env is used multiple times, it should also be static.
  static absl::NoDestructor<MagicNumberConfigsHelper> helper;

  const auto& main_executor_settings =
      engine_settings.GetMainExecutorSettings();
  Backend backend = main_executor_settings.GetBackend();

  static absl::NoDestructor<
      std::unordered_map<Backend, absl::StatusOr<Environment>>>
      kEnvironments;

  auto it = kEnvironments->find(backend);
  if (it == kEnvironments->end()) {
    auto env_res = [&]() -> absl::StatusOr<Environment> {
      std::vector<EnvironmentOptions::Option> env_options;

      if (model_resources != nullptr &&
          (backend == Backend::CPU || backend == Backend::GPU)) {
        if (!main_executor_settings.GetAdvancedSettings() ||
            main_executor_settings.GetAdvancedSettings()
                ->configure_magic_numbers) {
          env_options = helper->GetLiteRtEnvOptions(*model_resources,
                                                    main_executor_settings);
        }
      }

#if defined(__APPLE__) && TARGET_OS_IPHONE
      // On iOS, point the LiteRT runtime library directory at the app
      // bundle's Frameworks/ directory so dlopen-based accelerator
      // loading (e.g. libLiteRtMetalAccelerator.dylib) can find them.
      {
        CFBundleRef bundle = CFBundleGetMainBundle();
        if (bundle) {
          CFURLRef bundle_url = CFBundleCopyBundleURL(bundle);
          if (bundle_url) {
            char path[PATH_MAX];
            if (CFURLGetFileSystemRepresentation(
                    bundle_url, true, reinterpret_cast<UInt8*>(path),
                    PATH_MAX)) {
              static const absl::NoDestructor<std::string> kFrameworksPath(
                  std::string(path) + "/Frameworks");
              ABSL_LOG(INFO) << "Setting runtime library dir: "
                             << *kFrameworksPath;
              env_options.push_back(::litert::EnvironmentOptions::Option{
                  ::litert::EnvironmentOptions::Tag::kRuntimeLibraryDir,
                  absl::string_view(*kFrameworksPath)});
            }
            CFRelease(bundle_url);
          }
        }
      }
#endif  // __APPLE__ && TARGET_OS_IPHONE

#if !defined(LITERT_DISABLE_NPU)
      if (!main_executor_settings.GetLitertDispatchLibDir().empty()) {
        // If the dispatch library directory is provided, use it.
        env_options.push_back(::litert::EnvironmentOptions::Option{
            ::litert::EnvironmentOptions::Tag::kDispatchLibraryDir,
            main_executor_settings.GetLitertDispatchLibDir()});
        ABSL_LOG(INFO) << "Setting dispatch library path from "
                          "main_executor_settings: "
                       << main_executor_settings.GetLitertDispatchLibDir();
      } else {
#if defined(__ANDROID__) || defined(__EMSCRIPTEN__)
        // Otherwise, use the directory of the model file.
        std::string model_path(
            main_executor_settings.GetModelAssets().GetPath().value_or(""));
        std::filesystem::path path(model_path);
        // Note: Existence check for path was here, but it's better to check
        // before calling this function if needed.
        std::string dispatch_library_path = path.parent_path().string();
        // In WASM, the parent path is often just "/" which is usually not
        // what we want for dispatch libraries.
#ifdef __EMSCRIPTEN__
        bool should_set_path =
            !dispatch_library_path.empty() && dispatch_library_path != "/";
#else
        bool should_set_path = !dispatch_library_path.empty();
#endif
        if (should_set_path) {
          ABSL_LOG(INFO) << "Setting dispatch library path: "
                         << dispatch_library_path;
          env_options.push_back(::litert::EnvironmentOptions::Option{
              ::litert::EnvironmentOptions::Tag::kDispatchLibraryDir,
              absl::string_view(dispatch_library_path)});
        } else {
          ABSL_LOG(INFO) << "No dispatch library path provided.";
        }
#endif  // defined(__ANDROID__) || defined(__EMSCRIPTEN__)
      }
#endif  // defined(LITERT_DISABLE_NPU)

      if (auto severity = GetMinLogSeverity()) {
        env_options.push_back(::litert::EnvironmentOptions::Option{
            ::litert::EnvironmentOptions::Tag::kMinLoggerSeverity,
            static_cast<int64_t>(ToLiteRtLogSeverityInt8(*severity))});
      }

      LITERT_ASSIGN_OR_RETURN(
          auto env, Environment::Create(EnvironmentOptions(env_options)));
#if defined(__APPLE__) && TARGET_OS_IPHONE
      // Workaround for LiteRT #6745: the prebuilt Metal accelerator
      // creates MTLDevice/MTLCommandQueue without ARC during
      // Environment::Create, causing premature release. Overwrite with
      // ARC-retained handles so subsequent operations (weight upload,
      // inference) use stable objects. No backend guard — the GPU
      // accelerator auto-registers even when backend isn't explicitly
      // GPU.
      {
        void* metal_device = LiteRtLmGetMetalDevice();
        void* metal_queue = LiteRtLmGetMetalCommandQueue();
        if (metal_device && metal_queue) {
          LiteRtEnvOption metal_opts[2];
          metal_opts[0] = {
              kLiteRtEnvOptionTagMetalDevice,
              {kLiteRtAnyTypeVoidPtr, {.ptr_value = metal_device}}};
          metal_opts[1] = {
              kLiteRtEnvOptionTagMetalCommandQueue,
              {kLiteRtAnyTypeVoidPtr, {.ptr_value = metal_queue}}};
          LiteRtAddEnvironmentOptions(env.Get(), 2, metal_opts,
                                      /*overwrite=*/true);
          ABSL_LOG(INFO) << "Injected ARC-retained Metal handles";
        } else {
          ABSL_LOG(WARNING) << "Metal handles NULL: device=" << metal_device
                            << " queue=" << metal_queue;
        }
      }
#endif  // __APPLE__ && TARGET_OS_IPHONE
      return std::move(env);
    }();
    it = kEnvironments->emplace(backend, std::move(env_res)).first;
  }

  if (!it->second.ok()) {
    return it->second.status();
  }
  return *it->second;
}

}  // namespace litert::lm
