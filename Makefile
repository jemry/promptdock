APP      := build/PromptDock.app
SIGN_ID  ?= PromptDock Dev
INSTALL  := $(HOME)/Applications/PromptDock.app
ICON     := build/AppIcon.icns
# 版本号取最近的 git tag（v0.1.0 → 0.1.0），没有 tag 时为 0.1.0；构建号为提交数
VERSION  ?= $(or $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'),0.1.0)
BUILD    ?= $(or $(shell git rev-list --count HEAD 2>/dev/null),1)
# 额外的 swift build 参数；make dmg 用它编译通用二进制
SWIFT_FLAGS ?=
DMG      := build/PromptDock-$(VERSION).dmg

.PHONY: build test lint hooks app sign install dmg clean

build:
	swift build -c release $(SWIFT_FLAGS)

test:
	swift test

# 泄露检查：密钥、个人信息黑名单、禁止提交的文件类型
lint:
	scripts/check-leaks.sh

# 启用提交前泄露检查（每个 clone 执行一次）
hooks:
	git config core.hooksPath .githooks

# 应用图标由脚本绘制生成，仓库里不存图片
$(ICON): scripts/make-icon.swift
	mkdir -p build
	swift scripts/make-icon.swift $(ICON)

app: build $(ICON)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build -c release $(SWIFT_FLAGS) --show-bin-path)/PromptDock" $(APP)/Contents/MacOS/
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(BUILD)" $(APP)/Contents/Info.plist
	cp Resources/prompts.example.yaml $(APP)/Contents/Resources/
	cp $(ICON) $(APP)/Contents/Resources/
	plutil -lint $(APP)/Contents/Info.plist

sign: app
	codesign --force --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict $(APP)

install: sign
	@pkill -x PromptDock || true
	mkdir -p $(HOME)/Applications
	rm -rf $(INSTALL)
	cp -R $(APP) $(INSTALL)
	@sleep 1
	open $(INSTALL)

# 发布用安装包：通用二进制（Apple 芯片 + Intel）、临时签名（未经 Apple 公证，见 README「下载安装」）
# 不能用 PromptDock Dev：CI runner 和下载用户的机器上都没有这张自签名证书
dmg:
	$(MAKE) sign SWIFT_FLAGS="--arch arm64 --arch x86_64" SIGN_ID=-
	lipo -archs $(APP)/Contents/MacOS/PromptDock
	rm -rf build/dmg $(DMG)
	mkdir -p build/dmg
	cp -R $(APP) build/dmg/
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname "PromptDock $(VERSION)" -srcfolder build/dmg -ov -format UDZO $(DMG)
	rm -rf build/dmg
	@echo "已生成 $(DMG)"

clean:
	rm -rf .build build
