VERSION ?= 2.2.5
REV     ?= 1

.PHONY: help fetch deb install smoke smoke-static smoke-release source-deb verify-abi clean

help:
	@echo "── 二进制重打包线（拿上游 bionic 二进制）──"
	@echo "make fetch VERSION=2.2.5    # 取上游包进 cache/ 并校验 sha256"
	@echo "make deb   VERSION=2.2.5    # 打成自己的 deb，放到 dist/"
	@echo "make install                # 装最新的 dist/*.deb（自动清理旧 diversion）"
	@echo ""
	@echo "── 源码编译线（不依赖任何第三方打包产物）──"
	@echo "make source-deb VERSION=2.2.5 REV=1   # 需要 NDK_ROOT / zig 0.17 / bun / rust"
	@echo ""
	@echo "── 冒烟与校验 ──"
	@echo "make smoke                  # 在 tmux 真 tty 里起 TUI 冒烟（本机已装的包）"
	@echo "make smoke-static           # 解包 dist/*.deb 做静态体检（不需要设备）"
	@echo "make smoke-release TAG=v2.2.5+termux2   # 从 release 拉 deb 装到设备再冒烟"
	@echo "make verify-abi             # 只跑 FFI 符号/依赖校验"
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

smoke:
	bash scripts/smoke.sh

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

clean:
	rm -rf build dist
