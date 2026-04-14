BINARY = bin/permission-popup
SOURCE = src/PermissionPopup.swift
INSTALL_DIR = $(HOME)/.claude/hooks/permission-popup

.PHONY: build install uninstall clean test

build: $(BINARY)

$(BINARY): $(SOURCE)
	@mkdir -p bin
	swiftc -O -swift-version 5 -o $(BINARY) $(SOURCE)
	@echo "Built $(BINARY)"

install: build
	@mkdir -p $(INSTALL_DIR)/bin
	cp $(BINARY) $(INSTALL_DIR)/bin/
	cp permission-hook.sh $(INSTALL_DIR)/
	chmod +x $(INSTALL_DIR)/permission-hook.sh
	@echo ""
	@echo "Installed to $(INSTALL_DIR)"
	@echo ""
	@echo "Add this to ~/.claude/settings.json (or project .claude/settings.json):"
	@echo ""
	@echo '  "hooks": {'
	@echo '    "PermissionRequest": ['
	@echo '      {'
	@echo '        "matcher": "",'
	@echo '        "hooks": ['
	@echo '          {'
	@echo '            "type": "command",'
	@echo '            "command": "$(INSTALL_DIR)/permission-hook.sh",'
	@echo '            "timeout": 600'
	@echo '          }'
	@echo '        ]'
	@echo '      }'
	@echo '    ]'
	@echo '  }'
	@echo ""

uninstall:
	rm -rf $(INSTALL_DIR)
	@echo "Removed $(INSTALL_DIR)"
	@echo "Remember to remove the hook from ~/.claude/settings.json"

clean:
	rm -rf bin

test: build
	@echo '{"tool_name":"Bash","tool_input":{"command":"npm test"},"cwd":"/Users/test/my-project","session_id":"test-123"}' | ./$(BINARY)
