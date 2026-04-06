#!/usr/bin/env python
import os
import sys

env = SConscript("godot-cpp/SConstruct")

# Add source files
env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

# Determine library name components
library_name = "libunified_particle_system"
target_path = "bin/"

# Platform-specific extension
if env["platform"] == "macos":
    library_suffix = ".dylib"
elif env["platform"] == "windows":
    library_suffix = ".dll"
else:
    library_suffix = ".so"

# Target type suffix
if env["target"] in ["template_debug", "editor"]:
    target_suffix = "template_debug"
else:
    target_suffix = "template_release"

# Architecture
arch = env.get("arch", "")
if arch:
    arch_part = ".{}".format(arch)
else:
    arch_part = ""

# Final library filename: libunified_particle_system.linux.template_debug.x86_64.so
library_file = "{}.{}.{}{}{}".format(
    library_name,
    env["platform"],
    target_suffix,
    arch_part,
    library_suffix,
)

library = env.SharedLibrary(
    target=os.path.join(target_path, library_file),
    source=sources,
)

Default(library)
