BINARY = bin/permission-popup
SOURCE = src/PermissionPopup.swift
CLAUDE_INSTALL_DIR = $(HOME)/.claude/hooks/permission-popup
CODEX_INSTALL_DIR = $(HOME)/.codex/hooks/permission-popup

.PHONY: build install install-claude install-codex uninstall uninstall-claude uninstall-codex clean test test-codex test-question

build: $(BINARY)

$(BINARY): $(SOURCE)
	@mkdir -p bin
	swiftc -O -swift-version 5 -o $(BINARY) $(SOURCE)
	@echo "Built $(BINARY)"

install: install-claude

install-claude: build
	@mkdir -p $(CLAUDE_INSTALL_DIR)/bin
	cp $(BINARY) $(CLAUDE_INSTALL_DIR)/bin/
	cp permission-hook.sh $(CLAUDE_INSTALL_DIR)/
	chmod +x $(CLAUDE_INSTALL_DIR)/permission-hook.sh
	@echo ""
	@echo "Installed Claude Code hook to $(CLAUDE_INSTALL_DIR)"
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
	@echo '            "command": "$(CLAUDE_INSTALL_DIR)/permission-hook.sh",'
	@echo '            "timeout": 600'
	@echo '          }'
	@echo '        ]'
	@echo '      }'
	@echo '    ]'
	@echo '  }'
	@echo ""

install-codex: build
	@mkdir -p $(CODEX_INSTALL_DIR)/bin
	cp $(BINARY) $(CODEX_INSTALL_DIR)/bin/
	cp codex-permission-hook.sh $(CODEX_INSTALL_DIR)/
	chmod +x $(CODEX_INSTALL_DIR)/codex-permission-hook.sh
	@echo ""
	@echo "Installed Codex hook to $(CODEX_INSTALL_DIR)"
	@echo ""
	@echo "Add this to ~/.codex/config.toml:"
	@echo ""
	@echo '[features]'
	@echo 'hooks = true'
	@echo ''
	@echo '[[hooks.PermissionRequest]]'
	@echo 'matcher = ""'
	@echo ''
	@echo '[[hooks.PermissionRequest.hooks]]'
	@echo 'type = "command"'
	@echo 'command = "$(CODEX_INSTALL_DIR)/codex-permission-hook.sh"'
	@echo 'timeout = 600'
	@echo 'statusMessage = "Waiting for permission popup"'
	@echo ""

uninstall: uninstall-claude

uninstall-claude:
	rm -rf $(CLAUDE_INSTALL_DIR)
	@echo "Removed $(CLAUDE_INSTALL_DIR)"
	@echo "Remember to remove the hook from ~/.claude/settings.json"

uninstall-codex:
	rm -rf $(CODEX_INSTALL_DIR)
	@echo "Removed $(CODEX_INSTALL_DIR)"
	@echo "Remember to remove the hook from ~/.codex/config.toml"

clean:
	rm -rf bin

test: build
	@echo '{"tool_name":"Bash","tool_input":{"command":"npm test"},"cwd":"/Users/test/my-project","session_id":"test-123"}' | ./$(BINARY)

test-codex: build
	@echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"npm test","description":"Need to run tests outside the sandbox"},"cwd":"/Users/test/my-project","session_id":"test-123","turn_id":"turn-123","model":"gpt-5.5"}' | PERMISSION_POPUP_CLIENT=codex ./$(BINARY)

test-question: build
	@echo '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database should we use for the new service?","header":"Database","multiSelect":false,"options":[{"label":"Postgres","description":"Relational, strong consistency, great tooling. Best default for most apps."},{"label":"MongoDB","description":"Document store, flexible schema, good for rapidly changing data shapes."},{"label":"SQLite","description":"Embedded, zero-config, ideal for local or low-concurrency workloads."}]},{"question":"Which features should the first release include?","header":"Features","multiSelect":true,"options":[{"label":"Auth","description":"Email/password and OAuth login."},{"label":"Billing","description":"Stripe-based subscriptions."},{"label":"Notifications","description":"Email and in-app notifications."}]}]},"cwd":"/Users/test/my-project","session_id":"test-123"}' | PERMISSION_POPUP_CLIENT=claude ./$(BINARY)
