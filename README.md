# PhotoVault Pro 🔒

> 隐私照片保险箱 - Face ID 锁定 + 隐私相册 + 伪装模式

[![Platform](https://img.shields.io/badge/platform-iOS%2017.0+-blue.svg)](https://developer.apple.com/ios)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

## 📱 应用简介

PhotoVault Pro 是一款注重隐私的照片保护应用，使用 Face ID 生物识别技术锁定您的私密照片，确保只有您能访问。

**定价**：$2.99（一次性购买，无订阅）

## ✨ 核心功能

### 🔐 Face ID 安全锁定
- 使用 Apple Face ID 进行生物识别认证
- 支持备用 PIN 码
- 多次失败自动锁定

### 📷 隐私相册
- 加密存储私密照片
- 与系统相册完全隔离
- 支持批量导入/导出

### 🎭 伪装模式
- 伪装计算器界面
- 紧急情况下快速切换
- 保护隐私不被发现

### 🔒 本地加密
- 所有照片使用 AES-256 加密
- 密钥存储在 Secure Enclave
- 无云端同步，100% 本地存储

## 🛠️ 技术栈

| 技术 | 说明 |
|------|------|
| SwiftUI | 声明式 UI 框架 |
| LocalAuthentication | Face ID 认证 |
| CryptoKit | AES-256 加密 |
| Keychain | 安全密钥存储 |
| Photos | 相册访问 |

## 📦 项目结构

```
PhotoVaultPro/
├── PhotoVaultProApp.swift    # App 入口
├── Security/
│   ├── FaceIDAuthenticationManager.swift
│   ├── KeychainManager.swift
│   └── VaultEncryptionManager.swift
├── Features/
│   ├── VaultManager.swift
│   └── DecoyModeManager.swift
├── Utils/
│   └── SecurityUtils.swift
└── Assets.xcassets/
```

## 🚀 构建指南

### 环境要求
- macOS 14.0+
- Xcode 15.0+
- iOS 17.0+ SDK

### 构建步骤

```bash
# 1. 克隆仓库
git clone https://github.com/claws-x/photo-vault.git
cd photo-vault

# 2. 打开 Xcode 工程
open PhotoVaultPro.xcodeproj

# 3. 选择目标设备
# 选择 iPhone 17 Simulator 或真机

# 4. 构建并运行
# Xcode: Product → Build (⌘B)
# 或命令行:
xcodebuild -project PhotoVaultPro.xcodeproj \
  -scheme PhotoVaultPro \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  build
```

### 真机测试

1. 在 Xcode 中选择您的开发团队
2. 连接 iPhone
3. 点击 Run (⌘R)

## 📸 截图

> 截图待添加

| 主界面 | Face ID 锁定 | 伪装模式 |
|--------|-------------|----------|
| ![主界面](screenshots/home.png) | ![锁定](screenshots/lock.png) | ![伪装](screenshots/decoy.png) |

## 📋 隐私说明

- **无数据收集**：本应用不收集任何用户数据
- **无云端同步**：所有数据本地存储
- **无第三方 SDK**：无广告、无分析追踪
- **开源透明**：代码完全开源，可审计

## 📄 许可证

MIT License - 详见 [LICENSE](LICENSE)

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

## 📬 联系方式

- GitHub: [@claws-x](https://github.com/claws-x)
- 问题反馈：[Issues](https://github.com/claws-x/photo-vault/issues)

---

**PhotoVault Pro** - 您的隐私，由您掌控 🔒
