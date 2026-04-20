# Makefile for GDExtension Godot-Unified-Particle-System
# Uses scons to build for different targets

.PHONY: all e d r clean help all-targets
.PHONY: editor-windows debug-windows release-windows
.PHONY: editor-linux debug-linux release-linux
.PHONY: editor-macos debug-macos release-macos

# --- OS Detection ---
ifeq ($(OS),Windows_NT)
    PLATFORM := windows
    RM_RF     := cmd /C "if exist .sconsign.dblite del /F /Q .sconsign.dblite" & cmd /C "if exist .scons_cache rmdir /S /Q .scons_cache"
else
    UNAME_S := $(shell uname -s)
    ifeq ($(UNAME_S),Darwin)
        PLATFORM := macos
    else
        PLATFORM := linux
    endif
    RM_RF := rm -rf .sconsign.dblite .scons_cache
endif

# Default target
all: e

# Build for editor (with debug symbols and editor tools) - auto-detects OS
e:
	scons platform=$(PLATFORM) target=editor optimize=speed

# Build debug version (with debug symbols, no editor tools) - auto-detects OS
d:
	scons platform=$(PLATFORM) target=template_debug optimize=speed

# Build release version (optimized, no debug symbols) - auto-detects OS
r:
	scons platform=$(PLATFORM) target=template_release optimize=speed

# Build all targets for detected OS
all-targets: e d r

# --- Linux builds ---
editor-linux:
	scons platform=linux target=editor optimize=speed

debug-linux:
	scons platform=linux target=template_debug optimize=speed

release-linux:
	scons platform=linux target=template_release optimize=speed

# --- Windows builds ---
editor-windows:
	scons platform=windows target=editor optimize=speed

debug-windows:
	scons platform=windows target=template_debug optimize=speed

release-windows:
	scons platform=windows target=template_release optimize=speed

# --- macOS builds ---
editor-macos:
	scons platform=macos target=editor optimize=speed

debug-macos:
	scons platform=macos target=template_debug optimize=speed

release-macos:
	scons platform=macos target=template_release optimize=speed

# Clean build artifacts (cross-platform)
clean:
	scons --clean
	$(RM_RF)

# Help target
help:
	@echo "Detected platform: $(PLATFORM)"
	@echo ""
	@echo "Short targets (auto-detect OS: $(PLATFORM)):"
	@echo "  e               - Build for Godot editor"
	@echo "  d               - Build debug template"
	@echo "  r               - Build release template"
	@echo "  all-targets     - Build editor, debug, and release"
	@echo ""
	@echo "Linux targets:"
	@echo "  editor-linux    - Build for Godot editor (Linux)"
	@echo "  debug-linux     - Build debug template (Linux)"
	@echo "  release-linux   - Build release template (Linux)"
	@echo ""
	@echo "Windows targets:"
	@echo "  editor-windows  - Build for Godot editor (Windows)"
	@echo "  debug-windows   - Build debug template (Windows)"
	@echo "  release-windows - Build release template (Windows)"
	@echo ""
	@echo "macOS targets:"
	@echo "  editor-macos    - Build for Godot editor (macOS)"
	@echo "  debug-macos     - Build debug template (macOS)"
	@echo "  release-macos   - Build release template (macOS)"
	@echo ""
	@echo "  clean           - Remove build artifacts"
	@echo "  help            - Show this help message"
