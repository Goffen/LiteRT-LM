#!/usr/bin/env python3
"""Patch gpu_registry.cc for iOS: @rpath fallback, build marker, error logging."""

import pathlib
import sys

p = pathlib.Path("litert/runtime/accelerators/gpu_registry.cc")
if not p.exists():
    print(f"ERROR: {p} not found", file=sys.stderr)
    sys.exit(1)

t = p.read_text()

# 1. Add TargetConditionals.h include after the main header include
old_include = '#include "litert/runtime/accelerators/gpu_registry.h"\n'
new_include = (
    old_include
    + """
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
"""
)
t = t.replace(old_include, new_include, 1)

# 2. Add @rpath fallback and build marker before the for loop
old_for = "  for (auto plugin_path : kGpuAcceleratorLibs) {"
new_for = """#if TARGET_OS_IPHONE
  // On iOS, dlopen with bare filenames fails. Use @rpath/ prefix resolved
  // via the app binary's LC_RPATH entries (@executable_path/Frameworks).
  if (runtime_lib_path.empty()) {
    runtime_lib_path = "@rpath";
  }
  LITERT_LOG(LITERT_INFO, "[build:4] runtime_lib_path=%s",
             runtime_lib_path.c_str());
#endif
  for (auto plugin_path : kGpuAcceleratorLibs) {"""
t = t.replace(old_for, new_for, 1)

# 3. Add error logging after AcceleratorDef registration attempt
old_try2 = """\
    // Try to load a GPU accelerator using `LiteRtRegisterGpuAccelerator`
    // symbol."""
new_try2 = """\
    LITERT_LOG(LITERT_WARNING,
               "AcceleratorDef load failed for %s: %s",
               full_plugin_path.c_str(),
               registration.Error().Message().c_str());
    // Try to load a GPU accelerator using `LiteRtRegisterGpuAccelerator`
    // symbol."""
t = t.replace(old_try2, new_try2, 1)

# 4. Add error logging after FunctionPointer registration attempt
old_end = """\
    }
  }

  LITERT_LOG(LITERT_WARNING,
             "GPU accelerator could not be loaded and registered.");"""
new_end = """\
    }
    LITERT_LOG(LITERT_WARNING,
               "FunctionPointer load failed for %s: %s",
               full_plugin_path.c_str(),
               registration.Error().Message().c_str());
  }

  LITERT_LOG(LITERT_WARNING,
             "GPU accelerator could not be loaded and registered.");"""
t = t.replace(old_end, new_end, 1)

p.write_text(t)
print("gpu_registry.cc patched successfully")
