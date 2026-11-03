VERSION ?= 2.2.5
REV     ?= 1

.PHONY: help fetch deb install smoke clean

help:
	@echo "make fetch VERSION=2.2.5    # 取上游包到 cache/ 并校验 sha256"
	@echo "make deb   VERSION=2.2.5    # 打自己的 deb 到 dist/"
	@echo "make install                # 装最新 dist/*.deb（自动清理旧 diversion）"
	@echo "make smoke                  # tmux 里跑 TUI 冒烟"
	@echo "make clean                  # 清 build/ dist/"

fetch:
	bash scripts/fetch.sh $(VERSION)

deb: fetch
	bash scripts/build-deb.sh $(VERSION)

install:
	bash scripts/install.sh

smoke:
	bash scripts/smoke.sh

clean:
	rm -rf build dist
