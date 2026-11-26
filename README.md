<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="FansCtrl 图标">
</p>

<h1 align="center">FansCtrl</h1>

<p align="center">按场景调节 Mac 风扇：图书馆里保持安静，高负载时提前散热。</p>

FansCtrl 是一个 macOS 风扇控制工具，支持 Apple Silicon 与 Intel Mac，提供**主窗口**（概览、温度/转速曲线、档位、设置）和**菜单栏面板**两种入口。界面使用原生 SwiftUI 组件与 Liquid Glass（macOS 26+），macOS 15 上自动退回原生 Material 材质。

- 系统要求：macOS 15 或更高
- 已实机验证：MacBook Pro M5（Mac17,2）可手动接管风扇，全速档实测 6574 RPM
- Intel 机型按 SMC 规范适配并有单测覆盖，尚未实机验证

## 📐 档位

| 档位 | 策略 | 适用场景 |
| --- | --- | --- |
| 系统默认 | 完全不干预 | 想要 Apple 原厂行为 |
| 图书馆 | **封顶**：平时交给系统；系统想转得比约 12% 转速更快时，接管并压在封顶值 | 图书馆、自习室、会议 |
| 安静 | 封顶 30% | 宿舍、办公室 |
| 均衡 | 60°C 以上按曲线主动调速，比系统更早散热 | 日常 |
| 性能 | 50°C 起积极提速，减少降频 | 渲染、编译、游戏 |
| 全速 | 满速 | 临时快速降温 |
| 智能 | 根据平滑后的 CPU 负载、供电、系统热压力在 图书馆/安静/均衡/性能 之间切换，升档快（8s）、降档慢（45s） | 不想手动切换 |

### 🔇 强力压制

风扇突然变吵（比如在图书馆开始编译）时使用：**瞬间**把风扇压到本机最低转速（不会停转），持续 60 秒后自动恢复，给你时间关闭高负载软件。

- 开启前会提示：开启强力压制会瞬间降低噪音 60 秒，请立刻关闭高负载软件
- 压制期间温度持续达到 103°C（Intel 95°C）会提前结束并交还系统；紧急满速保护始终优先
- 结束后进入冷却期（实际用时的 2 倍，最多 120 秒），防止连续压制让芯片长时间高温
- 睡眠前自动结束

```bash
fanctl suppress        # 开启
fanctl suppress off    # 提前结束
```

智能档的“静音优先”开关：只在图书馆/安静两档之间切换，适合需要长时间保持安静的场合。

**为什么封顶而不是自定义低速曲线？** 在 M5 MacBook Pro 上实测，系统在 CPU 90°C 时只跑约 2500 RPM，比任何“静音曲线”都安静。封顶策略保证图书馆/安静档**永远不会比系统默认更吵**。

> 取舍：持续重负载时封顶会让芯片更热，可能比系统默认更早轻微降频。一旦系统热压力达到 `serious`（即将明显降频）或温度超过安全阀，封顶会自动放开，所以不会出现长时间严重降频。

## 🛡️ 安全机制

- **只有守护进程写 SMC**：本地 socket 只接受 `status / setProfile / setQuietFirst` 三种命令，不暴露任意 SMC 读写；每个连接用 `getpeereid` 校验，只允许 root 和当前登录在屏幕前的用户。
- **转速永远夹在 [最小, 最大]** 之间；写入类型与尺寸不匹配时直接拒绝。
- **写入回读校验**：切手动模式后回读确认，固件不接受就报错；系统连续 3 次把风扇抢回自动，判定本机不支持并停止接管。
- **紧急满速**：温度 ≥108°C（Intel 99°C）或系统热压力 `critical` → 满速，降到 100°C（Intel 90°C）才恢复。
- **静音档安全阀**：≥103°C（Intel 95°C）或热压力 `serious` → 放开封顶交还系统，回差 6°C。
- **传感器异常**（读不到可信温度）→ 立即交还系统。
- **睡眠前、进程退出（SIGTERM/SIGINT/SIGHUP）、卸载时**都会恢复系统自动控制；崩溃后 launchd 会重启守护进程，启动第一件事也是恢复自动。
- 无风扇机型（MacBook Air）自动识别为“不支持”，不做任何写入。

## ⚡ 资源占用

- 守护进程 RSS 约 8 MB，CPU 时间几乎为零（实测运行数十秒累计 0.02–0.04s）。
- “系统默认”档不跑定时器，状态按需读取；其他档每 2 秒采样一次，温度 key 的元信息有缓存，每次只做一次 IOKit 调用。
- App 只在主窗口或菜单栏面板可见时轮询，全部收起后不再唤醒。

## 📦 安装

从 Releases 下载 `FansCtrl-x.y.z.dmg`，把 FansCtrl 拖进「应用程序」后打开。首次打开会提示安装后台服务，点击后弹出系统管理员授权。

App 使用 ad-hoc 签名（未经 Apple 公证），首次打开若被 Gatekeeper 拦截，在「系统设置 → 隐私与安全性」中点「仍要打开」。

也可以手动安装后台服务：

```bash
sudo build/FansCtrl.app/Contents/Resources/install.sh
```

安装内容：`/Library/PrivilegedHelperTools/com.fansctrl.daemon`、`/Library/LaunchDaemons/com.fansctrl.daemon.plist`、`/usr/local/bin/fanctl`。卸载：

```bash
sudo build/FansCtrl.app/Contents/Resources/uninstall.sh
```

关闭主窗口后 FansCtrl 会留在菜单栏（Dock 图标随之隐藏）；风扇控制由后台服务负责，与 App 是否打开无关。

## 🧰 命令行

```bash
fanctl status            # 当前状态
fanctl set library       # system | library | quiet | balanced | performance | max | smart
fanctl quiet-first on    # 智能档静音优先
fanctl watch             # 每 2 秒刷新
fanctl probe             # 只读检测本机风扇/传感器，无需守护进程
```

验证本机固件是否接受手动转速（先 `fanctl set system` 或卸载服务，避免两边同时写 SMC）：

```bash
sudo fanctl selftest
```

## 🔧 从源码构建

需要 Xcode 26+（Liquid Glass API 来自 macOS 26 SDK）。

```bash
swift test
```

```bash
./scripts/build-app.sh
```

```bash
./scripts/build-dmg.sh
```

产物在 `build/`。图标由 `scripts/make-icon.swift` 用 CoreGraphics 绘制（未使用 SF Symbols，其许可不允许用于 App 图标），生成结果已提交在 `Support/AppIcon.icns`，修改后重新生成：

```bash
swift scripts/make-icon.swift build/icon && iconutil -c icns build/icon/AppIcon.iconset -o Support/AppIcon.icns
```

不写 SMC、不需要 root 的调试方式（socket 路径需短于 104 字节）：

```bash
.build/debug/fanctld --dry-run --socket .build/dev.sock --config .build/dev-config.json
```

```bash
FANSCTRL_SOCKET=.build/dev.sock .build/debug/fanctl status
```

dry-run 状态里的“下发”列是守护进程计划写入的转速，“SMC目标”是系统当前的真实目标。

### 结构

```
Sources/CSMC        AppleSMC 用户态客户端（C，保证 80 字节结构布局）
Sources/FanCore     SMC 编解码、机型探测、档位策略、控制器、智能选档、IPC 协议
Sources/fanctld     root 守护进程：控制循环、socket 服务、睡眠/信号处理
Sources/fanctl      命令行工具
Sources/FansCtrlApp 主窗口 + 菜单栏面板（SwiftUI、Swift Charts、Liquid Glass）
Support/            Info.plist、App 图标、安装/卸载脚本
scripts/            构建 App / DMG、生成图标
```

### 机型适配

- Apple Silicon：模式 key `F0md`（或 `F0Md`），温度取 `Tp*/Te*`（CPU）与 `Tg*`（GPU）中的最大有效值；若存在 `Ftst` 解锁 key 会先写 1、恢复时清零。
- Intel：新款用 `F0Md`，老款用 `FS! ` 位掩码；温度取 `TC0P/TC0D/TCxC` 与 `TG0P` 等；转速为 `fpe2` 定点数。
- 转速统一按“最小到最大转速的比例”配置，同一套档位适配不同风扇。

## ⚠️ 免责声明

FansCtrl 通过 SMC 直接控制风扇。虽然内置了多层保护（转速限幅、过热放开、紧急满速、异常时交还系统），修改散热行为仍有风险，请自行评估后使用。

## 📄 许可证

[MIT](LICENSE)
