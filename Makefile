VERSION ?= 2.3.0
REV     ?= 4   # 下一个待发布修订号（3 已发布，避免误覆盖）

.PHONY: help fetch deb install smoke smoke-service smoke-pty smoke-static smoke-release source-deb verify-abi check-16kb check-tool-updates publish-tool-cache clean runtime-bundle

help:
	@echo "── 二进制重打包线（拿上游 bionic 二进制）──"
	@echo "make fetch VERSION=2.2.5    # 取上游包进 cache/ 并校验 sha256"
	@echo "make deb   VERSION=2.2.5    # 打成自己的 deb，放到 dist/"
	@echo "make install                # 装最新的 dist/*.deb（自动清理旧 diversion）"
	@echo ""
	@echo "── 源码编译线（不依赖任何第三方打包产物）──"
	@echo "make source-deb VERSION=2.3.0 REV=4   # 需要 NDK_ROOT / zig 0.17 / bun / rust"
	@echo "make runtime-bundle                   # 制作独立运行时 bundle (tar.zst + manifest)"
	@echo ""
	@echo "── 冒烟与校验 ──"
	@echo "make smoke                  # TUI + 2.3.0 后台服务冒烟（本机已装的包）"
	@echo "make smoke-service          # 只测 2.3.0 后台服务启动（隔离 XDG）"
	@echo "make smoke-pty              # 只测 opencode-pty 持久 PTY daemon"
	@echo "make smoke-static           # 解包 dist/*.deb 做静态体检（不需要设备）"
	@echo "make smoke-release TAG=v2.3.0+termux3   # 从 release 拉 deb 装到设备再冒烟"
	@echo "make verify-abi             # 只跑 FFI 符号/依赖校验"
	@echo "make check-16kb             # 校验最新 dist/*.deb 的 16 KB 页对齐"
	@echo "make check-tool-updates     # 对比 termux-tools.lock 与 Termux 仓库"
	@echo "make publish-tool-cache     # 把当前 lock 的 deb 上传到 toolchain-cache"
	@echo ""
	@echo "make clean                  # 清 build/ dist/"

fetch:
	bash scripts/fetch.sh $(VERSION)

deb: fetch
	bash scripts/build-deb.sh $(VERSION)

install:
	bash scripts/install.sh

source-deb:
	bash scripts/build-source-deb.sh $(VERSION) $(REV)

runtime-bundle:
	# 版本/修订号从 deb 文件名推断，避免 VERSION/REV 默认值把 bundle 标错版本
	bash scripts/build-runtime-bundle.sh "$$(ls -1t dist/opencode_*_aarch64.deb 2>/dev/null | head -1)"

smoke:
	bash scripts/smoke.sh
	bash scripts/smoke-service.sh
	bash scripts/smoke-pty.sh

smoke-service:
	bash scripts/smoke-service.sh

smoke-pty:
	bash scripts/smoke-pty.sh

smoke-static:
	bash scripts/smoke-static.sh $$(ls -1t dist/*.deb 2>/dev/null | head -1)

smoke-release:
	bash scripts/smoke-release.sh $(TAG)

verify-abi:
	bash scripts/verify-abi.sh \
	  $$(ls -1 dist/*/lib*/opentui/@opentui/core-android-arm64/libopentui.so 2>/dev/null | head -1) \
	  $$(ls -1 dist/*/lib*/opencode/librust_pty.so 2>/dev/null | head -1) \
	  "$$(find build -type d -path '*/node_modules/@opentui/core' | head -1)" \
	  "$$(find build -type d -path '*/node_modules/bun-pty' | head -1)"

check-16kb:
	@set -e; \
	deb="$$(ls -1t dist/*.deb 2>/dev/null | head -1)"; \
	[ -n "$$deb" ] || { echo "ERROR: dist/ 下没有 deb" >&2; exit 1; }; \
	tmp="$$(mktemp -d)"; \
	trap 'rm -rf "$$tmp"' EXIT; \
	echo "==> $$deb"; \
	dpkg-deb -x "$$deb" "$$tmp"; \
	python3 scripts/check-16kb-pages.py \
	  "$$tmp/data/data/com.termux/files/usr/bin/opencode.real" \
	  "$$tmp"/data/data/com.termux/files/usr/lib/opencode/*.so

check-tool-updates:
	bash scripts/check-tool-updates.sh

publish-tool-cache:
	bash scripts/publish-tool-cache.sh

clean:
	rm -rf build dist
