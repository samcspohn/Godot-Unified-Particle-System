# Makefile for GDExtension ships_core
# Uses scons to build for different targets

.PHONY: all e d r clean help

# Default target
all: e

# Build for editor (with debug symbols and editor tools)
e:
	scons platform=linux target=editor optimize=speed

# Build debug version (with debug symbols, no editor tools)
d:
	scons platform=linux target=template_debug optimize=speed

# Build release version (optimized, no debug symbols)
r:
	scons platform=linux target=template_release optimize=speed

# Build all targets
all-targets: editor debug release

# Windows builds
editor-windows:
	scons platform=windows target=editor

debug-windows:
	scons platform=windows target=template_debug

release-windows:
	scons platform=windows target=template_release

# macOS builds
editor-macos:
	scons platform=macos target=editor

debug-macos:
	scons platform=macos target=template_debug

release-macos:
	scons platform=macos target=template_release

# Clean build artifacts
clean:
	scons --clean
	rm -rf .sconsign.dblite
	rm -rf .scons_cache

# Help target
help:
	@echo "Available targets:"
	@echo "  editor          - Build for Godot editor (Linux)"
	@echo "  debug           - Build debug template (Linux)"
	@echo "  release         - Build release template (Linux)"
	@echo "  all-targets     - Build editor, debug, and release (Linux)"
	@echo "  editor-windows  - Build for Godot editor (Windows)"
	@echo "  debug-windows   - Build debug template (Windows)"
	@echo "  release-windows - Build release template (Windows)"
	@echo "  editor-macos    - Build for Godot editor (macOS)"
	@echo "  debug-macos     - Build debug template (macOS)"
	@echo "  release-macos   - Build release template (macOS)"
	@echo "  clean           - Remove build artifacts"
	@echo "  help            - Show this help message"
