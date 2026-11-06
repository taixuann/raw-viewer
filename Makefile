.PHONY: build test install-local

build:
	cargo build --workspace

test:
	cargo test --workspace

install-local:
	cargo build --release -p raw-viewer-cli
	@if [ "$$(uname -s 2>/dev/null)" = "Darwin" ] || [ "$$(uname -s 2>/dev/null)" = "Linux" ]; then \
		mkdir -p "$$HOME/.local/bin"; \
		cp target/release/raw-viewer "$$HOME/.local/bin/raw-viewer"; \
		chmod +x "$$HOME/.local/bin/raw-viewer"; \
		echo "Installed raw-viewer to $$HOME/.local/bin/raw-viewer"; \
	else \
		powershell -Command "New-Item -ItemType Directory -Force -Path \"$$env:LOCALAPPDATA\raw-viewer\bin\"; Copy-Item \"target\release\raw-viewer.exe\" -Destination \"$$env:LOCALAPPDATA\raw-viewer\bin\raw-viewer.exe\""; \
		echo "Installed raw-viewer to %LOCALAPPDATA%\raw-viewer\bin\raw-viewer.exe"; \
	fi
