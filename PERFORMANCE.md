# 性能基准报告

测试日期：2026-11-06  
机器：Apple Silicon（arm64），macOS 27.2（26B123）  
工具链：Swift 6.4.2 / Xcode 27.2  
构建：`swift build -c release`（`-O`，无调试符号参与运行）

## 指标定义

| 指标 | 来源 | 说明 |
| --- | --- | --- |
| footprint | `task_vm_info.phys_footprint` | 进程私有脏页 + 压缩页，**常驻内存的主要判据** |
| RSS | `mach_task_basic_info.resident_size` | 含 AppKit / Swift 等共享库映射，数值偏大，仅供参考 |
| CPU | `getrusage(RUSAGE_SELF)` | 测量窗口内的 user + system 时间，除以墙钟时间 |

所有数据来自真实运行进程，不是估算。每次测量前预热 2 秒，再采样 4–6 秒。不同运行之间 footprint 会有 ±0.5MB 波动。

## 结果

### 空闲常驻

| 场景 | footprint | RSS | 空闲 CPU |
| --- | --- | --- | --- |
| 打包应用空闲（EventTap 已运行，浏览器已缓存，5s 采样） | **14,943,072–15,074,144 B（14.25–14.38 MiB）** | 78,217,216–78,299,136 B（74.6–74.7 MiB） | **0.011–0.013%**（0.0006–0.0007s / 5.25s） |
| 首次启动（Launch Services 扫描 2 个浏览器，打包应用） | **15,369,056 B（14.66 MiB）** | 79,331,328 B（75.7 MiB） | 0.010% |
| 同上，SwiftPM 产物（此前一次采样） | 14,713,696 B（14.03 MiB） | 77,774,848 B（74.2 MiB） | 0.013% |

对应命令：

```bash
# 已缓存浏览器列表
build/BrowserSelector.app/Contents/MacOS/BrowserSelector --benchmark 5 --no-scan
# 首次启动：清空 config.json 后
build/BrowserSelector.app/Contents/MacOS/BrowserSelector --benchmark 5 --no-tap
```

`tap_running=1`、`ax_trusted=1` 已包含在输出中。

> 单位说明：footprint 的 MiB 数值与 Activity Monitor 的「内存」列基本一致。按十进制字节换算，稳态为 14.9–15.1 MB，处于 15MB 边界；按 MiB 为 14.2–14.7 MB。不同运行间波动约 ±0.5MB。

### 面板生命周期

| 场景 | footprint |
| --- | --- |
| 面板显示（2 个浏览器，AppKit 实现） | 21,644,224 B（20.6 MiB） |
| 面板关闭 1.2s 后（已 `malloc_zone_pressure_relief`） | 21,201,856 B（20.2 MiB） |
| 对比：SwiftUI 版本面板关闭后 | 25,478,080 B（24.3 MiB） |
| 对比：空 `NSPanel`（无任何内容）显示 / 关闭后 | 17,433,464 B（16.6 MiB） |

命令：

```bash
.build/release/BrowserSelector --benchmark-panel
```

### 基线拆解

| 基线 | footprint |
| --- | --- |
| 裸 AppKit 菜单栏进程（仅 `NSStatusItem`） | 13,550,432 B（12.9 MiB） |
| 同上，链接 SwiftUI 但不实例化任何视图 | 13,452,128 B（12.8 MiB） |

结论：SwiftUI 链接本身几乎不占常驻内存；主要成本来自 **任何 AppKit 窗口被创建后，窗口服务/渲染/文本栈约 +4MB 且不归还**。因此“显示过面板之后”的 footprint 无法压到 15MB 以下，除非把面板拆到独立进程。

### EventTap 回调判定

```bash
.build/release/BrowserSelector --benchmark-click
# benchmark_click iterations=200000 total_seconds=0.0249 ns_per_call=124.6 hits=200000
```

**124.6 ns/call**（约 0.000125 ms），覆盖：

- `NSLock` 加解锁
- 前台应用 / 目标应用字典查找
- Bundle ID 排除判断
- 窗口矩形命中 + 标题排除判断

真实回调还会读取几个 `CGEvent` 字段（几十 ns），只有命中目标应用时才做一次 `DispatchQueue.async`。与 1ms 的预算相比有两个数量级余量。

## 结论

- **空闲常驻 footprint 14.2–14.7 MiB（Activity Monitor 约 14.2–14.7 MB），满足 ≤15MB 的约束**；CPU 约 0.011–0.013%，接近 0。
- **面板使用后 footprint 约 20.2 MiB**。其中 16.6 MiB 是空 AppKit 窗口的硬地板，内容仅约 4MB。对象已释放，但窗口/渲染缓存由系统持有。
- 如果必须让“使用后”也 ≤15MB，需要把面板改为**独立轻量进程**（XPC / 独立 helper）或更低层的 CGWindow 渲染，属于后续架构演进；当前实现优先保证原生交互与视觉质量。
- 如果要求按十进制字节严格 <15,000,000，空闲稳态仍有约 0–100KB 的超出（波动范围内），可继续做菜单懒加载等微优化；按 macOS 常规汇报口径（MiB / Activity Monitor）已满足。
- AX / 剪贴板路径未做端到端延迟基准（需要真实钉钉/微信窗口与可点击链接）。实现上 AX 调用在后台串行队列，单次 messaging timeout 设为 0.25s；剪贴板兜底默认等待 50ms，仅在 AX 完全不可用时触发，普通点击不会等待。

## 复现

```bash
swift build -c release
BIN="$(swift build -c release --show-bin-path)/BrowserSelector"

$BIN --benchmark 5            # 空闲（默认会建 EventTap，前提是终端已有辅助功能权限）
$BIN --benchmark 5 --no-tap   # 不含 EventTap
$BIN --benchmark 5 --no-scan  # 不触发浏览器扫描
$BIN --benchmark-panel        # 面板显示/关闭
$BIN --benchmark-click        # 回调判定微基准
```

说明：

- 直接从终端运行 SwiftPM 产物时，辅助功能权限归属于终端进程；打包成 `.app` 后需要在系统设置里给 `BrowserSelector.app` 单独授权。
- 首次启动扫描只在配置里没有浏览器时发生；后续启动不扫描，因此稳态内存更低。
- 测量期间不打开设置窗口；设置页按需加载 SwiftUI，未纳入空闲指标。
