# Feijian — 局域网文件与消息传输工具 · 设计文档

> 版本：v1.0（待确认）
> 日期：2026-10-04
> 目标平台：Windows + Android（首版），iOS（后续）

---

## 1. 产品概述

### 1.1 一句话定义

一个**零配置、无服务器、纯局域网 P2P** 的即时消息与文件传输工具。安装后自动发现同网段内运行本软件的其他终端，点击即可对话、传文件、发消息。

### 1.2 参照产品

飞鸽传书（英文名 Feige，又称 IP Messenger）。我们保留其"打开就能用、无需账号、无需服务器"的核心体验，改进其陈旧的 UI 与移动端缺失。

> 注：本项目名 `Feijian` 与该竞品无关，命名上刻意避开，详见 §1.5。

### 1.3 核心特性（v1）

| 特性 | 说明 |
|---|---|
| 自动发现 | UDP 组播 + 广播双通道，零配置发现同局域网终端 |
| 终端列表 | 显示设备名称、图标、IP、在线状态，实时上下线 |
| 文字消息 | UTF-8 全语言（中文/英文/日文/阿拉伯语/emoji），送达回执 |
| 文件传输 | 任意格式单文件，分块流式传输，带进度/取消/断点续传 |
| 图片传输 | 内联缩略图预览 + 全屏查看 |
| 文件夹传输 | 递归传输目录结构，接收端自动重建 |
| 拖拽发送 | Windows 拖拽文件/文件夹到窗口直接发送 |
| 剪贴板发送 | 粘贴图片直接发送；粘贴文件路径作为文件发送 |
| 离线消息 | 对方离线时消息入队，对方上线后自动补发 |
| 历史记录 | SQLite 本地持久化，重启后可查 |
| 多语言 UI | v1 英文，i18n 框架从第一天就位，后续零代码加语言 |

### 1.4 明确不做（v1 范围外）

- ❌ 跨网段/互联网传输（无中继服务器）
- ❌ 账号体系、云端同步
- ❌ 群聊（1 对 1 对话）
- ❌ 消息加密（见 §9，协议已预留升级位）
- ❌ 屏幕共享 / 远程控制
- ❌ iOS（v1 之后）

### 1.5 命名说明

| 项 | 值 |
|---|---|
| 产品名（英） | **Feijian** |
| 代码代号 / 仓库目录 | `feijian` |
| Dart 包名 | `feijian` |
| 应用 ID | `com.feijian.lan` |
| 中文名 | 待定 |

命名**刻意避开"飞鸽 / Feige"**：那既是既有商业产品名（商标风险），也会让用户误以为是同一产品的不同版本或衍生版。

UI 展示名统一走常量 + i18n key `appName`，任何地方不得硬编码，改名只动一处。

包名、应用 ID、数据目录名（`Downloads/Feijian`）、组播服务名（`_feijian._tcp`）在整个工程内保持一致，便于用户识别与排查。

---

## 2. 技术栈决策

| 层面 | 选型 | 理由 |
|---|---|---|
| 跨平台框架 | **Flutter 3.x (Dart)** | 一套代码出 Windows/Android/iOS；`dart:io` 提供原生 Socket 能力，网络性能无损耗；UI 一致性最好 |
| 网络层 | **`dart:io` 内置**（`RawDatagramSocket` / `ServerSocket` / `Socket`） | 不引入第三方网络库。裸 Socket 完全可控，且零依赖意味着 iOS 端不会有兼容问题 |
| 状态管理 | `flutter_riverpod` | 编译期安全、易测试、无需 BuildContext |
| 本地数据库 | `drift` + `sqlite3_flutter_libs` | 类型安全 SQL、支持 schema 迁移、跨平台一致 |
| 国际化 | `flutter_localizations` + `intl` + ARB | Flutter 官方方案，工具链成熟 |
| 文件选择 | `file_picker` | Android SAF 支持完善，Windows 原生对话框 |
| 拖拽（Windows） | `desktop_drop` | Flutter 桌面拖拽事实标准 |
| 通知 | `flutter_local_notifications` | Windows + Android 统一 API |
| Android 保活 | `flutter_foreground_task` | 后台持续收发的前提（见 §7.1） |
| 系统托盘（Windows） | `tray_manager` + `window_manager` | 最小化到托盘继续收发 |

### 2.1 为什么不用 HTTP / WebSocket

裸 TCP 更轻、无框架开销，且文件传输天然是字节流。HTTP 的断点续传/Range 虽有优势，但引入 server 框架与 URL 路由层，对局域网 P2P 场景是过度设计。自定义帧格式（§4.2）已覆盖续传需求。

### 2.2 为什么用 JSON 而不是 Protobuf

v1 优先**可调试性**：抓包能看到明文 JSON，问题定位成本极低。协议头只在每次握手/消息时传输，开销可忽略（文件数据走裸 payload，不经 JSON）。若未来成为瓶颈，`hello` 帧的 `caps` 字段已预留协商空间。

---

## 3. 系统架构

### 3.1 分层结构

```
┌─────────────────────────────────────────────────────┐
│  UI 层 (Flutter Widgets)                            │
│  DevicesPage · ChatPage · SettingsPage              │
├─────────────────────────────────────────────────────┤
│  状态层 (Riverpod Providers)                        │
│  peersProvider · chatProvider · transferProvider    │
├─────────────────────────────────────────────────────┤
│  数据层 (drift / SQLite)                            │
│  Dao · Repository · 迁移                            │
├─────────────────────────────────────────────────────┤
│  核心层 (纯 Dart，无 Flutter 依赖 —— 关键)           │
│  ┌────────────┬────────────┬─────────────────────┐  │
│  │ Discovery  │ Transport  │ Transfer            │  │
│  │ UDP 组播   │ 单端口     │ 分块发送/接收        │  │
│  │ 网卡枚举   │ 连接池     │ 队列/并发/续传       │  │
│  └────────────┴────────────┴─────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

**核心层不依赖 Flutter** 是本设计的关键约束：
1. 可以写纯 Dart 单元测试，不启动模拟器即可验证协议/传输正确性
2. iOS 端只需补 UI 适配与权限声明，核心逻辑零改动
3. 未来若需移植到其他语言，边界清晰

### 3.2 运行时组件图

```
      本机 Feijian 进程
 ┌──────────────────────────────────────────┐
 │  DiscoveryService                        │
 │    ├─ RawDatagramSocket :24250 (UDP)     │
 │    │    ├─ 加入组播组 239.255.42.50       │
 │    │    └─ 发送广播 255.255.255.255       │
 │    └─ 每 5s ANNOUNCE / 收包更新 PeerTable │
 ├──────────────────────────────────────────┤
 │  FeijianServer                             │
 │    └─ ServerSocket :24250 (TCP)          │
 │         按 hello.role 分发：              │
 │           role=control → ControlConnection│
 │           role=data    → DataConnection   │
 ├──────────────────────────────────────────┤
 │  ConnectionManager                       │
 │    └─ Map<deviceId, ControlConnection>   │
 │         · 主动连接去重（§4.4）            │
 │         · 30s Ping/Pong 心跳              │
 │         · 断线指数退避重连                │
 ├──────────────────────────────────────────┤
 │  TransferManager                         │
 │    ├─ 发送队列（并发上限 3）              │
 │    └─ 接收表 Map<xferId, Receiver>        │
 └──────────────────────────────────────────┘
```

---

## 4. 协议设计

### 4.1 设备发现（UDP）

**端口**：`24250`（TCP/UDP 同号）。
> 刻意避开飞鸽传书/IP Messenger 的传统端口 `2425`，防止与已安装的同类软件冲突。端口在设置页可改。

**组播地址**：`239.255.42.50`（IPv4 管理范围 239.0.0.0/8 内，不与 mDNS/SSDP 冲突）

**双通道策略**：
- **主通道 — 组播**：标准做法，交换机/AP 支持良好
- **兜底 — 广播**：`255.255.255.255`，部分企业级 AP 屏蔽组播时仍可用
- 两者**同时发送**，接收端按 `deviceId` 去重（同一设备两个包只算一次）

**ANNOUNCE 包**（JSON，UTF-8，**单包 ≤ 1400 字节**以避免 IP 分片）：

```json
{
  "v": 1,
  "type": "announce",
  "id": "7f3a9c21-4e8b-4d2a-9f11-2c5e8a0b3d47",
  "name": "Alice-Laptop",
  "device": "windows",
  "os": "Windows 11 23H2",
  "icon": "laptop",
  "port": 24250,
  "ts": 1759564800
}
```

| 字段 | 说明 |
|---|---|
| `v` | 协议版本，不匹配时忽略并记日志 |
| `type` | `announce` / `bye` / `probe` |
| `id` | **设备唯一 ID**，UUIDv4，首次安装生成后持久化，永不改变。这是所有逻辑的主键 |
| `name` | 用户可改的显示名，默认取系统主机名 |
| `device` | `windows` / `android` / `ios`，用于选择默认图标 |
| `icon` | `desktop` / `laptop` / `phone` / `tablet`，用户可改 |
| `port` | 本机 TCP 监听端口（允许用户改端口） |
| `ts` | 发送时间戳，用于丢弃过期包 |

**时序**：

```
启动          : 发 1 个 probe（立即，加速发现） + 1 个 announce
运行期        : 每 5s 发 1 个 announce
收到 announce : 立即回 1 个**单播** announce 给对方（加速双向收敛）
                └─ 单播给发送方 IP:24250，不再广播，避免风暴
正常退出      : 发 1 个 bye
```

**上下线判定**：

| 状态 | 条件 | UI 表现 |
|---|---|---|
| Online | 15s 内收到任意包 | 绿点 + 正常显示 |
| Offline | 15s ~ 60s 无包 | 灰显，不可发送，历史仍可查看 |
| Removed | > 60s 无包 | 从列表移除（DB 中保留记录） |

**网卡枚举与过滤**（关键实现细节）：

```dart
NetworkInterface.list(type: InternetAddressType.IPv4)
```

必须过滤掉以下接口，否则广播会发到虚拟网卡上（Windows 上的高频问题）：

- 名称匹配 `vEthernet`（Hyper-V/WSL）、`VMware`、`VirtualBox`、`docker`
- 名称匹配 VPN 客户端自建的网卡：`cloudflare`（WARP）、`wireguard`、`tailscale`、`zerotier`、`anyconnect`、`globalprotect`、`forticlient` 等
- 地址为 `127.*`、`169.254.*`（链路本地，说明没拿到 DHCP）

~~接口 `isLoopback == true`~~ —— **Dart 的 `NetworkInterface` 没有这个属性**，只有 `InternetAddress.isLoopback`。回环接口靠地址过滤自然排除（它只承载 127/8），不需要单独判断。

对**每个**存活的非回环 IPv4 接口分别绑定 socket 发送，而不是依赖默认路由。设置页提供网卡勾选列表，让用户手动排除异常网卡。

**仅靠名称匹配不够**：实测在某台开发机上，Cloudflare WARP 的网卡 `172.16.0.2` 不含任何虚拟网卡特征词，且因为长得像私有网段地址而被 `primaryIpv4()` 选中，覆盖了真正的 Wi-Fi（`192.168.3.46`）。后果是设备对外通告了一个同网段设备根本连不上的地址。因此地址排序还需要按"多大概率是真 LAN"分级：

| 网段 | 排序 | 理由 |
|---|---|---|
| `192.168/16` | 0（最优） | 家用 / 小型办公 Wi-Fi 的实际默认 |
| `10/8` | 1 | 企业 LAN 常见 |
| `172.16/12` | 2 | Docker、WARP、大量 VPN 都蹲在这里，所以输给 10/8 |
| 其他（公网） | 4 | 排最后但仍可用——只有公网地址的机器不该显示"无地址" |

### 4.1.1 发送失败必须显式检测（实测结论）

`RawDatagramSocket.send()` **失败时不一定抛异常，而是返回 0**。Windows 上实测：在真实网卡上背靠背连发 4 个 UDP 报文，约 4% 的报文根本没发出去，而 `send()` 只返回 0；报文之间间隔 1ms 后丢包完全消失。

这与"必须有冗余"的设计直接相关，也是 §4.1 双通道（组播 + 广播）不能简化的原因：

- 每个报文同时走组播和广播两条通道，任一条送达即成功；
- 每 5s 重发一轮，单轮丢失只损失几秒延迟。

因此实现上有两条硬性要求：

1. **必须检查 `send()` 的返回值**。漏发在别处完全不可见——没有异常、没有日志，症状只是"设备列表一直是空的"，正是本节最想避免的静默失败。失败按"状态变化"记录（首次失败记一条，恢复后记一条），否则一块消失的网卡会每 5s 刷一条日志。
2. **`_send()` 保持同步**。`stop()` 要在同一轮里先发 `bye` 再关 socket，若发送被推迟到下一个事件循环轮次，`bye` 会写进已关闭的 socket，对端就会在 60s 内一直显示本机离线。

另外注意：UDP socket 收到 ICMP port-unreachable 后，Windows 会把错误"记住"，此后 `send()` 可能**持续**返回 0。这种情况下只有检查返回值才能发现问题。

### 4.1.2 锁死的发送 socket 必须被换掉（实测结论）

上一节最后那句"此后 `send()` 可能**持续**返回 0"不是理论风险，它是真机上的主症状。

真机实测（Windows peer + Android APK 同 Wi-Fi）：**刚连上一切正常，几分钟后两边互相搜不到；点刷新无效，点 Rescan 无效；杀掉一端进程重开，立刻又连上。**

- 最后一条是决定性的：重启能恢复，说明广播机制、端口、防火墙、网卡选择全都是好的——重启唯一改变的是**进程内的 socket 对象**。
- 前两条说明故障在发送侧且**不可自愈**：`RawDatagramSocket` 一旦锁存，后续每次 `send()` 都静默返回 0，重发（刷新）走的是同一个已死的 socket，所以重发等于没发。
- 只有检查返回值（§4.1.1）才能发现它，但发现了也没有用——**错误不会自己清除，只有关闭这个 socket 才清除**。

因此实现上：

1. **发送 socket 连续 3 次写入失败后被丢弃并重新绑定**。一轮发送对每个 socket 写两次（组播 + 广播），所以真正死掉的 socket 约两轮就达到阈值（约 `kAnnounceInterval`×2）；而一个健康的 socket 在一串突发里偶尔丢一个包只会计到 1，下一次成功写入就清零。
2. **`rescan()` 重建 socket，而不是在原 socket 上重发**。这正是"点刷新没反应"的根因：用户按刷新时 socket 大概率已经锁死，在它上面重发是空操作。现在的做法是关掉全部 socket（含应答 socket）重新绑定，再发 3 轮 probe+announce，每轮间隔 400ms——一次 UDP 在 Wi-Fi 上是一次抛硬币，而这里是用户正盯着屏幕等结果的地方，是整个协议里唯一值得连发的地方。
3. **应答走独立 socket，不复用监听 socket**。`_reply` 把单播回复发往探测方的端口，如果那个端口已经没人监听，引回的 ICMP port-unreachable 会锁死**发送它的那个 socket**。旧实现里 `_reply` 从接收 socket 发出，等于让一个已经消失的对端把本机的探测应答能力永久打死；而探测应答恰恰是收不到组播的设备（Android 未取 `MulticastLock` 时就是）唯一的信息来源。现在应答专用一个绑定到通配地址的 socket，监听路径和应答路径互不牵连。

一个实现上的坑，值得单独记：**替换 socket 的代码会在发送循环内部改 `_senders`**。`_send` 遍历 `_senders`，循环体里 `_sendTo` 失败会触发 `_replace`，而 `_replace` 在第一个 `await` 之前的语句是同步执行的——于是"从列表里删掉这个死 socket"正好发生在遍历它的过程中，抛 `ConcurrentModificationError`。这不是"少发一个包"那么轻：它是个未捕获的异步异常，从 `_send` 中间炸出去，后面所有网卡的 announce 全部没发出。所以 `_send` 遍历的是 `_senders` 的**副本**，另外 `_noteSendFailure` 会忽略已经不属于本服务的 socket（副本里可能还留着刚被关掉的）。这个 bug 由新加的回归测试捕获——把发送 socket 关掉再触发四次 announce，旧代码必现。

### 4.2 帧格式（TCP）

控制连接与数据连接共用同一套帧格式：

```
┌──────────────┬────────────────────────┬──────────────────┐
│ headerLen    │  header (JSON, UTF-8)  │  payload (raw)   │
│ uint32 BE    │  headerLen bytes       │  header.size 字节 │
│ 4 bytes      │                        │                  │
└──────────────┴────────────────────────┴──────────────────┘
```

- `headerLen` 上限 **1 MB**，超限直接断开连接（防止损坏/恶意包导致内存爆炸）。
  注意校验顺序：**先查 `headerLen` 再等 body**，否则一个恶意长度值就能在判断合法性之前先撑爆内存。
- `payload` 长度由 `header.size` 决定；无 payload 的帧省略
- 单帧 payload 上限 **512 KB**（文件分块大小 = 256 KB，留余量）

> **`size` 是帧层保留字段**，任何 payload 定义都不得占用它。原 §4.3 给 `file_offer` 的字段也叫 `size`（含义是文件总大小），与这里冲突：一个 4GB 的文件会被读成"payload 长 4GB"，超过 512KB 上限而被判定为损坏流、断开连接。已将该字段改名为 `totalSize` —— 这也是 §4.6 里文件夹场景本来就用的名字，单文件与文件夹两种 offer 因此统一。

### 4.3 帧类型

| type | 方向 | header 字段 | 说明 |
|---|---|---|---|
| `hello` | 双向 | `role`, `deviceId`, `name`, `device`, `icon`, `port`, `version`, `caps` | 连接建立后**第一帧**，`role` ∈ `control`/`data` |
| `msg` | 双向 | `msgId`, `ts`, `text`, `replyTo?` | 文字消息 |
| `msg_ack` | 双向 | `msgId`, `ts` | 送达回执 |
| `file_offer` | 发送方→接收方 | `xferId`, `name`, `totalSize`, `mime`, `isDir`, `files[]?`, `sha256?`, `mtime` | 传输请求（`totalSize`，**不是** `size` —— 见 §4.2） |
| `file_accept` | 接收方→发送方 | `xferId`, `resumeFrom` | 接受，可指定续传起点 |
| `file_reject` | 接收方→发送方 | `xferId`, `reason` | 拒绝/取消 |
| `file_data` | 发送方→接收方 | `xferId`, `relPath?`, `offset`, `size`, `eof` | 数据分块，payload 为原始字节 |
| `file_done` | 双向 | `xferId` | 单个文件传输完成 |
| `file_cancel` | 双向 | `xferId` | 中途取消 |
| `xfer_done` | 双向 | `xferId` | 整个传输任务（含文件夹）完成 |
| `ping` / `pong` | 双向 | `ts` | 心跳，30s 间隔 |
| `bye` | 双向 | — | 优雅关闭连接 |

**前向兼容规则**：收到未知 `type` → 记日志并忽略，不断开连接。收到未知字段 → 忽略。这保证新旧版本可以互通。

### 4.4 连接建立与去重

**单端口复用**：本机只监听 `24250` 一个 TCP 端口，防火墙只需放行一个端口。连接建立后第一帧 `hello` 携带 `role` 字段区分用途：
- `role=control` → 长期保留的控制连接
- `role=data` → 单次文件传输，用完即关

**同时连接问题**：A 和 B 可能同时向对方发起 TCP 连接，导致两条控制连接、消息重复。解决方案（类似 WebRTC Perfect Negotiation）：

> **比较双方 `deviceId` 的字符串大小，ID 较小的一方为"主动连接方"**。
> 若已存在一条由 ID 较大一方发起的连接，则关闭它，保留 ID 较小一方发起的连接。

规则确定性强、无协商开销、两端独立计算得出相同结论。

**实现要点**：规则必须表述成两端都能独立算出的形式，即"由 `deviceId` 较小的一方发起的那条连接胜出"。不能用"保留我发起的"或"保留更新的那条"——那样两端会各自保留同一条 socket 而关掉对方的，剩下的两条恰好都在对方的关闭列表里，结果是双方都断开。同时连接时每端各看到一条入站和一条出站，规则才有确定答案；两端都是同向连接只可能来自重复拨号，此时保留既有连接并记日志。

**去重期间发出的帧要在胜出连接上重发**：两端互相 announce 就会互相拨号，因此在去重完成之前的短暂窗口里两条 socket 都是 up 的，而第一条连接 ready 触发的离线队列 flush（§5.2）可能正好写进那条即将被关掉的 socket。接收方若不巧在同一时刻关闭它，这帧就丢了——而发送方这边已经把它标成 `sent`，队列不再管它，只剩 10s 后的 ack 超时重发能兜住，用户看到的是"对端明明在线，第一条消息却卡了一个勾十秒"。所以：**去重换连接时，把该 peer 所有未 ack 的帧在新连接上立即重发一次**，不消耗重试次数。代价是接收方可能收到一帧重复消息，而重复去重（§4.5）本来就是必须做的事——用一次可去重的重复换掉一个可见的卡顿。

#### 4.4.1 连接失败在 Windows 上要约 2 秒（实测结论）

在本机（Windows 11）实测：向一个**没人监听**的回环端口发起 `Socket.connect`，从调用到抛出 `SocketException`（errno 1225，连接被拒绝）稳定耗时 **约 2000ms**，与端口号无关，重复连接同样如此。这不是 Dart 的开销，是 Windows 报告 SYN 被拒的固有延迟。

对实现有两条硬性影响：

1. **发送路径不能等连接。** 用户点发送时若对端刚离线，等 `connect` 返回再决定"发不出去"会让界面卡两秒。正确做法是先落库、标 `pending`、立即返回，由后台连接与离线队列（§5.2）负责最终送达。
2. **重连退避要按"每次尝试本身就要两秒"来设计。** 退避间隔短于失败耗时没有意义——真正的节奏由 connect 的失败时间决定，`kReconnectBackoff` 只负责在成功之后拉长间隔。

### 4.5 消息可靠性与去重

- 每条消息有全局唯一 `msgId`（UUIDv4）
- 接收方维护最近 1000 条 `msgId` 的 LRU 集合，重复消息直接丢弃并回 `msg_ack`
- 发送方状态机：`pending` →（发出 `msg`）→ `sent` →（收到 `msg_ack`）→ `delivered`
- 10s 未收到 `msg_ack` 且连接仍在 → 重发（最多 3 次），仍失败则标 `failed`，UI 显示红色感叹号可手动重试
- **排序**：不依赖对端时钟（设备时钟可能不同步）。本地按 `created_at DESC` 排序，`created_at` 为本地接收/发送时间，且**同一会话内严格递增**（§5.2.1）。原设计写的 `(created_at DESC, msgId)` 里的 `msgId` 起不到稳定作用——它是随机 UUID，等于随机排序，已改。

### 4.6 文件传输流程

```
发送方 A                                    接收方 B
   │                                            │
   │── file_offer {xferId, name, size} ────────▶│  （控制连接）
   │                                            │  弹窗询问 / 自动接受策略
   │◀── file_accept {xferId, resumeFrom: 0} ────│
   │                                            │
   │═══ TCP 连接 (role=data) ══════════════════▶│  新开一条连接
   │── hello {role: data, deviceId} ───────────▶│
   │                                            │
   │── file_data {xferId, offset:0, size:256K} ▶│  写入 xxx.part
   │── file_data {xferId, offset:256K, ...} ───▶│
   │        ... 循环，每块 await flush() ...     │
   │── file_data {xferId, offset:N, eof:true} ─▶│
   │── file_done {xferId} ─────────────────────▶│  校验 size → rename .part → 正式名
   │◀── file_done {xferId} ─────────────────────│  回执
   │                                            │
   │  关闭 data 连接                             │
```

**为什么数据走独立连接**：
1. 大文件传输不阻塞控制连接上的文字消息
2. 多文件并行传输天然支持（每个文件一条连接，并发上限 3）
3. 取消传输 = 直接 `socket.destroy()`，无需复杂协议协商
4. 传输失败不影响控制连接，重连成本低

**接收端写入策略**：
- 写入 `<下载目录>/Feijian/<文件名>.part`，完成后 `rename` 为正式名（原子操作，避免半成品被误打开）
- 重名自动追加 ` (1)`、` (2)` 后缀
- 文件名做**路径穿越防护**：剥离 `..`、`/`、`\`、绝对路径前缀，只保留 basename（防止对端构造恶意文件名写到系统目录）

**背压控制**（防止大文件 OOM，**必须严格实现**）：

```dart
// 禁止 file.readAsBytes() —— 4GB 文件会直接 OOM
final raf = await file.open();
while (offset < size) {
  final chunk = await raf.read(chunkSize);       // 每次只读 256KB
  socket.add(frameBytes);                         // 写入 socket
  offset += chunk.length;
  if (++sinceFlush >= 8) {                        // 每 2MB flush 一次
    await socket.flush();                         // 让 Dart 内部背压生效
    sinceFlush = 0;
  }
}
```

**断点续传**：`file_accept.resumeFrom` 指定起始偏移，`file_offer` 携带 `size` + `mtime`；接收方若发现已存在的 `.part` 且 `size`/`mtime` 与 offer 一致，则可从 `.part` 长度续传，否则从 0 开始。

**文件夹传输**：
1. 发送端递归遍历目录，生成清单 `files: [{relPath, size, mtime, isDir}]`
2. `file_offer {isDir: true, fileCount, totalSize, files: [...]}` 一次性发送
3. 接收方确认后，发送端**顺序**发送各文件（每个文件一条 data 连接，`relPath` 放在帧 header 中）
4. 接收端按 `relPath` 重建目录结构；**空目录也要创建**
5. 清单超过 **256 KB**（约数千文件）时提示用户"文件夹包含过多文件"，v1 不支持，P2 再优化为单独连接传清单

---

## 5. 数据模型

### 5.1 SQLite 表结构

```sql
-- 对端设备（持久化，即使离线也保留）
CREATE TABLE peer (
  id           TEXT PRIMARY KEY,      -- 设备 UUID，来自 ANNOUNCE
  name         TEXT NOT NULL,
  device_type  TEXT NOT NULL,         -- windows/android/ios
  os           TEXT,
  icon         TEXT,                  -- desktop/laptop/phone/tablet
  avatar       BLOB,                  -- 可选自定义头像
  last_ip      TEXT,
  last_seen    INTEGER,               -- 毫秒时间戳
  is_trusted   INTEGER DEFAULT 0      -- 信任设备可自动接收文件
);

-- 会话
-- 注意：peer_id **不加** FOREIGN KEY（与最初草案不同，见下方说明）
CREATE TABLE conversation (
  id            TEXT PRIMARY KEY,
  peer_id       TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  last_msg_at   INTEGER,
  unread_count  INTEGER DEFAULT 0,
  draft         TEXT                  -- 未发送的草稿
);

-- 消息
CREATE TABLE message (
  id              TEXT PRIMARY KEY,   -- = msgId
  conversation_id TEXT NOT NULL REFERENCES conversation(id),
  peer_id         TEXT NOT NULL,
  direction       TEXT NOT NULL,      -- 'in' | 'out'
  type            TEXT NOT NULL,      -- 'text' | 'file' | 'image' | 'folder' | 'system'
  text            TEXT,
  status          TEXT NOT NULL,      -- pending/sent/delivered/failed/received
  created_at      INTEGER NOT NULL,
  delivered_at    INTEGER,
  retry_count     INTEGER DEFAULT 0
);
CREATE INDEX idx_message_conv ON message(conversation_id, created_at DESC);

-- 附件（一条消息可含多个附件 —— 文件夹传输）
CREATE TABLE attachment (
  id            TEXT PRIMARY KEY,
  message_id    TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
  file_name     TEXT NOT NULL,
  rel_path      TEXT,                 -- 文件夹传输时的相对路径
  size          INTEGER NOT NULL,
  mime          TEXT,
  local_path    TEXT,                 -- 接收后的落盘路径
  thumb_path    TEXT,                 -- 图片缩略图缓存
  sha256        TEXT,
  state         TEXT NOT NULL,        -- pending/downloading/done/failed/cancelled
  transferred   INTEGER DEFAULT 0
);

-- 传输任务（用于进度恢复与续传）
CREATE TABLE transfer (
  id             TEXT PRIMARY KEY,    -- = xferId
  message_id     TEXT REFERENCES message(id),
  attachment_id  TEXT REFERENCES attachment(id),
  peer_id        TEXT NOT NULL,
  direction      TEXT NOT NULL,       -- 'in' | 'out'
  state          TEXT NOT NULL,
  bytes_done     INTEGER DEFAULT 0,
  bytes_total    INTEGER NOT NULL,
  temp_path      TEXT,
  updated_at     INTEGER NOT NULL
);

-- 设置（简单 KV）
CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

**外键的三条规则**（`PRAGMA foreign_keys = ON` 必须显式打开，否则全部形同虚设）：

| 关系 | 处理 | 理由 |
|---|---|---|
| `attachment.message_id → message` | `ON DELETE CASCADE` | 附件脱离消息就没有意义，留着只会变成垃圾文件 |
| `transfer.message_id/attachment_id → ...` | 默认 | 传输任务可独立于消息清理 |
| `conversation.peer_id → peer` | **不建外键** | 见下 |

`conversation.peer_id` 不加外键，是对最初草案的修正。原因是 `peer` 表只是"设备广播内容的缓存"，而 `conversation`/`message` 是**用户自己的数据**。一旦建了引用，"忘记此设备"这个唯一会删除 peer 行的操作就只剩两种结局：

- 默认的 `NO ACTION`：SQLite **拒绝删除**，功能直接不可用；
- `ON DELETE CASCADE`：删设备顺手把聊天记录一起抹掉，且不可撤销。

两者都不可接受——用户整理设备列表不该付出丢历史的代价。另外 `message.peer_id` 本身就没有引用，说明"有 peer_id 但没有 peer 行"本来就是这份 schema 允许的状态，单给 conversation 加约束连一致性都换不来。

**草稿会自己建出会话行**。`conversation` 行本来只在落第一条消息时创建（§5.1 的 `ensureConversation`），但草稿完全可以先于消息存在——给一个刚发现的设备打第一个字，正是最常见的场景，此时那行还不存在。所以写草稿前先 `ensureConversation`：否则 `UPDATE ... WHERE peer_id = ?` 匹配零行，SQLite 照样报成功，用户切到别的设备再切回来，打了一半的字就没了。这时会话行的 `last_msg_at` 仍为 NULL——草稿不是消息，不该把设备列表按"最近消息"重排，也不该动未读徽标。

### 5.2 离线消息队列

对端不在线时的处理：

1. 消息正常落库，`status = 'pending'`，立即在 UI 显示（带时钟图标）
2. 队列**不放在内存里**，直接查库：`SELECT ... WHERE status='pending' ORDER BY created_at`。原设计写的 `Map<peerId, Queue<message>>` 会导致重启后队列丢失，而第 6 条本来就要求重启后恢复——查库是唯一同时满足两条的做法。
3. 触发补发的时机：
   - 收到该 peer 的 ANNOUNCE
   - 与该 peer 的 control 连接握手成功
4. 补发时按 `created_at` 升序逐条发送，**沿用原 `msgId`**（对端按 msgId 去重，避免重复显示）
5. 文件消息离线时，只补发 `file_offer`；文件仍在本地磁盘，可重新读取。若文件已被删除/移动，标记该消息 `failed` 并在气泡上显示"文件已不存在"
6. 应用重启后，从 `message WHERE status='pending'` 恢复队列

#### 5.2.1 `created_at` 在会话内必须严格递增（实测结论）

`created_at` 是**毫秒**精度，而消息 id 是随机 UUID v4。所以两条落在同一毫秒的消息**没有确定顺序**：`ORDER BY created_at, id` 里的 `id` 起不到排序作用，等于抛硬币。实测到的症状是 §5.2 那条「按顺序补发」的测试约每六次失败一次，三条消息每次以不同的顺序到达。

这不是罕见边界。补发本身就是最坏情况——整条队列在一毫秒内发完；接收端同样如此，因为入站消息打的是**接收方的**时钟（§4.5），一串连到的消息会共用同一个毫秒值。

因此**写入时**保证同一会话内 `created_at` 严格递增：新消息的时间戳若 `<=` 该会话已有的最大值，就取 `最大值 + 1`。三个推论：

- 放在写入侧而不是两条 `ORDER BY` 里，是因为 `page()` 的排序同时是 keyset 游标的比较依据（游标得由调用方携带），而单调时间戳让现有查询和游标全部保持正确，不必改 schema，也不必改游标。
- 必须和插入在**同一个事务**内，否则两个并发写入会读到同一个最大值、再次撞在一起。
- 代价是时间戳可能比墙上时钟快一点点（突发中每条 +1ms）。这是聊天记录普遍接受的取舍，且偏离量由消息条数封顶，不会无端漂移。副作用是**时钟往回跳时新消息仍排在最后**——这正是想要的：刚敲的消息不该插进历史中间。

---

## 6. UI 设计

### 6.1 响应式布局策略

| 屏幕宽度 | 布局 |
|---|---|
| ≥ 900px（Windows 桌面、Android 平板） | **双栏**：左侧设备列表（固定 280px）+ 右侧对话区 |
| < 900px（Android 手机） | **单栏**：设备列表页 → 点击进入全屏对话页（Navigator push） |

用 `LayoutBuilder` 实现，同一套 widget 代码适配两种形态。

### 6.2 页面一：Devices（终端列表）

```
┌────────────────────────────────────────────┐
│  Feijian                            ⚙  ⟳     │
├────────────────────────────────────────────┤
│ ┌────────────────────────────────────────┐ │
│ │  🖥  Alice-Laptop  (You)               │ │  ← 本机信息卡，点击改名字/头像
│ │      192.168.1.100 · Windows 11        │ │
│ └────────────────────────────────────────┘ │
│                                            │
│  ON THE NETWORK · 3                        │
│ ┌────────────────────────────────────────┐ │
│ │ 🟢 💻  Bob-PC                      📎  │ │  ← 点击进入对话
│ │       192.168.1.101 · Online           │ │     右侧 📎 直发文件
│ ├────────────────────────────────────────┤ │
│ │ 🟢 📱  Alice-Phone                 📎  │ │
│ │       192.168.1.105 · Online           │ │
│ ├────────────────────────────────────────┤ │
│ │ ⚪ 🖥  Meeting-Room-PC              —   │ │  ← 离线灰显
│ │       192.168.1.110 · Offline          │ │
│ └────────────────────────────────────────┘ │
│                                            │
│  ── 或 ──                                  │
│  + Add device by IP address                │  ← 组播被屏蔽时的兜底
└────────────────────────────────────────────┘
```

**空状态**（发现不到任何设备时，这是用户第一次使用最可能遇到的情况）：

```
        🔍  (脉动动画)

   Scanning for devices on your network...

   Make sure:
   • Other devices have Feijian running
   • You're on the same Wi-Fi / LAN
   • Your firewall allows Feijian (TCP/UDP 24250)

   [ Add device by IP ]   [ Rescan ]
```

### 6.3 页面二：Chat（对话）

```
┌────────────────────────────────────────────┐
│  ← 💻 Bob-PC                          ⋮    │
│    Online                                  │
├────────────────────────────────────────────┤
│                                            │
│                    Hello, can you send me  │  ← 自己：右对齐，主色气泡
│                    the report?             │
│                                     14:23  │
│                                            │
│  Sure! Here you go.          14:24         │  ← 对方：左对齐，浅灰气泡
│                                            │
│  ┌──────────────────────────┐  14:25       │
│  │ 🖼 [thumbnail preview]   │              │  ← 图片：内联缩略图
│  └──────────────────────────┘              │      点击全屏（可缩放）
│                                            │
│  ┌──────────────────────────┐  14:26       │
│  │ 📄 report-2026.pdf       │              │  ← 文件卡片
│  │ 4.2 MB · ✓ Completed     │              │
│  │ [Open]  [Save as...]     │              │
│  └──────────────────────────┘              │
│                                            │
│                    ┌─────────────────────┐ │
│                    │ 📁 Photos           │ │  ← 文件夹卡片
│                    │ 24 files · 156 MB   │ │
│                    │ ████████░░ 78%      │ │
│                    └─────────────────────┘ │
│                                     14:31  │
│                                            │
├────────────────────────────────────────────┤
│  ┌──────────────────────────────────────┐  │
│  │ Type a message...             📎 📁 ➤│  │
│  └──────────────────────────────────────┘  │
└────────────────────────────────────────────┘
```

**交互细节**：

| 交互 | 行为 |
|---|---|
| 拖拽文件到窗口 | 整个对话区变高亮遮罩层，松开即发送（Windows） |
| Ctrl+V 粘贴图片 | 直接作为图片消息发送 |
| Ctrl+V 粘贴文件路径 | 识别为文件，作为文件消息发送 |
| 图片气泡点击 | 全屏查看器，支持双指/滚轮缩放、左右切换同会话图片 |
| 文件卡片点击 | 已下载 → 系统默认程序打开；未下载 → 开始下载 |
| 长按/右键消息 | 复制文字 / 另存为 / 删除本地记录（M2 只有文字那两项，另存为属 M3） |
| 发送失败 | 气泡旁红色感叹号，点击重试 |
| 滚动到顶 | 分页加载更早历史（每页 50 条） |

**消息状态图标**：
- 🕐 `pending` — 等待发送（对方离线或队列中）
- ✓ `sent` — 已发出，未确认
- ✓✓ `delivered` — 对方已收到
- ⚠ `failed` — 发送失败，可重试

#### 6.3.1 消息菜单的三条语义

**复制的是整条消息，不是选中片段。** 气泡里的文字因此是 `Text` 而不是 `SelectableText`：`SelectableText` 自己会吃掉长按手势去弹系统的选择工具条，结果是菜单在桌面上能开、在手机上永远开不了——而手机是这个 app 的主场。这是个明确的取舍：在聊天气泡里划选一部分文字不是真实需求，复制整条才是，菜单做的就是这件事。

**「删除」只删本地。** 对方手里那条还在，也不会收到任何通知。所以菜单项写的是「Delete for me」而不是「Delete」——一个不告诉对方、只影响自己的操作，措辞上就不该让人以为对方那头也没了。

**「清空历史」要二次确认，单条删除不确认。** 单条删除是用户刚刚长按了那条消息、菜单就挨着它弹出来的；清空历史是点一个图标就可能抹掉几年的记录，屏幕上没有任何东西指向将要消失的内容。两者风险不同，确认与否也就不同。

清空历史保留 `conversation` 行本身，因此**草稿和这个设备都还在**：草稿是用户自己敲的、此刻正显示在输入框里的字，不是历史，静默销毁它会让输入框里的内容在重开对话后凭空消失（`MessageDao.clearIn` 的注释里写了同样的话）。`unread_count` 归零、`last_msg_at` 置 NULL——这两项是**消息的摘要**，消息没了，摘要也就不该留着，否则设备列表会一直预览一条用户刚删掉的消息。

被删掉的 `pending` 消息就是一笔取消掉的欠账（§5.2）：删除即用户取消发送，下次 flush 不会把它捞回来。

### 6.4 页面三：Settings

| 分组 | 项 |
|---|---|
| **Profile** | Display name（默认系统主机名）、Device icon、Avatar |
| **Files** | Download folder（默认 `Downloads/Feijian`）、Auto-accept policy：`Off` / `Images under __ MB` / `All from trusted devices` |
| **Network** | Listen port、组播地址、启用的网卡多选、传输限速（可选） |
| **Notifications** | 消息通知、文件接收通知、声音 |
| **System** | 开机自启（Windows）、最小化到托盘（Windows）、后台常驻（Android 前台服务） |
| **Language** | English（v1 唯一选项，下拉框已就位） |
| **About** | 版本、协议版本、开源许可 |

### 6.5 视觉风格

- **Material 3**，浅色/深色跟随系统（Windows 用 `window_manager` 读取系统主题）
- **主色**：青蓝 `#0EA5E9`（科技感，且与飞鸽传书的红黄配色形成区分）
- **字体**：系统默认（Windows `Segoe UI` / Android `Roboto`）。**不打包自定义字体** —— 系统字体对各语言（含 CJK、阿拉伯语、emoji）的覆盖最完整，打包字体反而会出现豆腐块
- **设备图标**：Windows/Android 客户端内置 4 个矢量图标（desktop/laptop/phone/tablet），用户可切换
- **头像**：默认用设备图标 + 名称首字母生成的彩色圆形；支持上传自定义图片

---

## 7. 平台适配

### 7.1 Android

**权限清单**：

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE" />
<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE" />  <!-- 组播锁必需 -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />          <!-- 13+ -->
```

**组播锁（不做就收不到任何设备）**：

```kotlin
// MainActivity.kt —— 由 Dart 侧 lib/platform/wifi_lock.dart 通过
// MethodChannel "com.feijian.lan/wifi_lock" 调用
val lock = wifi.createMulticastLock("feijian").apply {
  setReferenceCounted(false)
  acquire()
}
// onDestroy 里 release 一次
```

清单里声明 `CHANGE_WIFI_MULTICAST_STATE` 只是拿到**权限**，不等于拿到锁。没有 `acquire()` 时 Wi-Fi 固件照旧按省电策略丢弃组播帧，而 socket 层的 `joinMulticast` **仍然成功**——组也加入了、socket 也开着、任何一层都不报错，就是收不到包。这正是 §4.1.1 要防的那种静默失败。

**这个 bug 真的发生过**：+3 版 APK 只声明了权限、从未 acquire，真机表现就是"点刷新、点 Rescan 都刷不出设备"。它的隐蔽之处在于代码里那句话是对的（"必需"），错的只是没有人去做。

两个与直觉相反的实现选择：

1. **锁在进程生命周期内一直持有，而不是 DiscoveryService 起停时配对 acquire/release。** 这个 app 的全部意义就是"察觉对面那台设备出现"，一把在轮次之间放掉的锁，恰好可能在对面 announce 的那一刻是松的。而且 `rescan()` 会重建 socket、provider 被重建会换掉整个 DiscoveryService 实例——配对调用在这种生命周期里迟早会配歪。
2. **`setReferenceCounted(false)`，`onDestroy` 里 release 一次。** 默认的引用计数模式下，漏掉一次 release 就是永久泄漏（固件会一直为下一个进程过滤组播）；不计数则"acquire 多少次都只需 release 一次"，把配平这件事从正确性要求降级成无所谓。

拿不到锁时**不能抛异常**：没有 Wi-Fi 模块的设备（模拟器走以太网）拿不到，为此拒绝启动就是把一个降级的功能换成一个打不开的 app。返回 false，日志记一条，广播通道仍然工作。

**前台服务（不做就无法后台收发）**：
Android 8+ 起，App 退到后台数分钟后会被 Doze 冻结，Socket 被挂起，组播完全收不到。必须启动前台服务并常驻通知：
> 🔵 **Feijian is running** — 3 devices online
>
> *Tap to open*

通知栏常驻是 Android 生态的既定代价，不做则产品不可用。设置页提供"仅在使用时在线"开关（关闭前台服务，省电但后台收不到消息）。

**存储策略**：

| 文件类型 | 保存位置 |
|---|---|
| 图片/视频 | MediaStore → 系统相册 `Pictures/Feijian`、`Movies/Feijian` |
| 其他文件 | `Downloads/Feijian`（MediaStore Downloads，Android 10+ 无需存储权限） |
| 应用内部临时 | `getExternalFilesDir()` 下的 `.part` 文件 |

优先用 **SAF（Storage Access Framework）** 而非 `MANAGE_EXTERNAL_STORAGE` —— 后者会触发 Google Play 的敏感权限审核，且用户授权体验差。

**文件夹选择限制**：Android 的 SAF 支持目录树授权（`ACTION_OPEN_DOCUMENT_TREE`），可以实现，但用户操作路径深。v1 策略：提供"选择文件夹"入口，同时引导使用"多选文件"。

**Share Intent（P1，强烈建议尽快做）**：从相册/文件管理器"分享到 Feijian"是 Android 用户最自然的发送路径，缺失会显著影响可用性。

**网络切换**：Android 在 Wi-Fi ↔ 蜂窝间切换时接口会变。监听 `ConnectivityManager` 网络变化 → 重建 DiscoveryService 的 socket 绑定。

### 7.2 Windows

**打包与安装**：
- `flutter build windows --release` → 产物用 **Inno Setup** 制作安装包
- 安装脚本添加防火墙规则（需管理员提权，仅首次安装时）：
  ```
  netsh advfirewall firewall add rule name="Feijian" dir=in action=allow ^
    protocol=UDP localport=24250 profile=private,domain
  netsh advfirewall firewall add rule name="Feijian" dir=in action=allow ^
    protocol=TCP localport=24250 profile=private,domain
  ```
- **只对 `private,domain` 配置文件放行**，不对 `public` 放行 —— 避免在咖啡厅/机场等公共网络暴露服务

**多虚拟网卡（Windows 上最高频的坑）**：
开发机/办公机常装有 Hyper-V、WSL2、VMware、VirtualBox、Docker，会产生大量虚拟网卡。若不过滤，广播会发到虚拟网络，导致"明明在同一 Wi-Fi 却互相看不见"。必须按 §4.1 的规则过滤，并在设置页暴露网卡多选列表供用户手动纠正。

**系统托盘**：关闭主窗口 = 最小化到托盘（可配）；托盘图标右键菜单：Open / Status / Quit。

**开机自启**：写注册表 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`（设置页开关，无需管理员权限）。

**拖拽**：`desktop_drop` 包，监听 `DropTarget` 的 `onDragDone`，拿到本地路径列表后逐个判断是文件还是目录。

### 7.3 iOS（后续版本，此处仅记录设计约束）

- **必须在 `Info.plist` 声明**，否则 iOS 14+ 完全无法做局域网发现：
  ```xml
  <key>NSLocalNetworkUsageDescription</key>
  <string>Feijian needs local network access to find and connect to nearby devices.</string>
  <key>NSBonjourServices</key>
  <array><string>_feijian._tcp</string></array>
  ```
  首次运行时系统会弹"允许查找本地网络设备"，用户拒绝则功能全废
- **后台限制最严**：App 退到后台约 30s 后网络被挂起。合规的后台收发方案只有有限几种（后台音频/VoIP 均有滥用风险）。**设计上接受"iOS 后台不可靠"**，产品文案明示
- **代码影响**：核心层已与平台解耦，iOS 只需补 UI 适配 + 权限声明 + `CupertinoPageTransitionsBuilder`
- **建议同时实现 mDNS/DNS-SD 发现**（`_feijian._tcp`），iOS 对 Bonjour 支持最好，且能与其它支持 Bonjour 的工具互发现

---

## 8. 国际化（i18n）方案

用户明确要求"初代英文，未来扩展多国语言"。**关键是从第一天就做对，否则后期返工成本极高。**

### 8.1 强制规则

1. **所有用户可见字符串必须走 `AppLocalizations`**，代码里禁止出现硬编码英文
   ```dart
   // ✅ 正确
   Text(AppLocalizations.of(context)!.devicesOnNetwork(count))
   // ❌ 错误
   Text("ON THE NETWORK · $count")
   ```
2. **布局使用方向无关的写法**，为阿拉伯语/希伯来语（RTL）预留：
   - `EdgeInsetsDirectional.only(start: 16)` 而非 `EdgeInsets.only(left: 16)`
   - `AlignmentDirectional.centerStart` 而非 `Alignment.centerLeft`
   - `Row` 中优先 `MainAxisAlignment` 而非硬编码 padding
3. **时间/日期/数字用 `intl` 格式化**，不手写拼接
4. **不要在字符串里拼接句子片段**（语序因语言而异），用带参数的完整句子
   ```dart
   // ✅
   "fileReceived": "Received {fileName} ({size})"
   // ❌ "Received " + fileName + " (" + size + ")"
   ```
5. 长文本（如空状态排查提示）中包含的列表项也要拆成独立 key，便于各语言调整顺序

### 8.2 工程配置

```yaml
# l10n.yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
```

- 语言自动跟随系统，设置页可手动覆盖（`MaterialApp.locale`）
- **未来新增语言 = 新增一个 `.arb` 文件**，零代码改动
- v1 只交付 `app_en.arb`，但框架、`l10n.yaml`、`flutter_localizations` 依赖全部就位

---

## 9. 安全设计

### 9.1 v1 决策：明文传输

按需求确认，v1 采用与飞鸽传书一致的**明文传输**，换取实现简单与传输速度。必须明确记录其风险：

| 风险 | 说明 |
|---|---|
| 局域网嗅探 | 同一网络内任何人用 Wireshark 可看到全部消息与文件内容 |
| 中间人 | 无法验证对端身份，可被伪造设备名欺骗 |
| 无访问控制 | 同网段任何运行本软件的设备都可向本机发文件 |

### 9.2 v1 的缓解措施（低成本，建议实现）

- 文件接收**默认需要用户确认**（仅图片小于阈值可自动接收）
- 路径穿越防护（§4.6），防止恶意文件名写到系统目录
- 单帧 header 上限 1 MB，防止内存攻击
- 同一 `deviceId` 的并发连接数限制（如 4），防止连接耗尽
- 设置页提供 **Blocked devices** 列表

### 9.3 为未来加密预留的升级路径（v1 不做，但协议已留位）

`hello` 帧中的 `caps` 字段用于能力协商：

```json
{
  "type": "hello",
  "caps": ["plain", "tls13", "file-resume"],
  ...
}
```

未来实现加密时：
1. 双方在 `hello` 中交换 `caps`，取交集
2. 若双方都支持 `tls13`，则用 TLS 1.3 + 自签证书 + 首次连接指纹确认（TOFU，类似 SSH / Syncthing）
3. 老版本客户端自动降级为明文，保持向后兼容

**这个字段 v1 就要写进协议**（值为 `["plain"]`），否则未来加加密会造成协议版本硬断裂。

---

## 10. 项目结构

```
feijian/
├── pubspec.yaml
├── l10n.yaml
├── design.md                     # 本文档
├── lib/
│   ├── main.dart                 # 入口：初始化 DB、ProviderScope
│   ├── app.dart                  # MaterialApp + 主题 + 路由 + locale
│   │
│   ├── core/                     # ★ 纯 Dart，禁止 import flutter/*
│   │   ├── constants.dart        # 端口、超时、分块大小、协议版本
│   │   ├── models/
│   │   │   ├── peer.dart
│   │   │   ├── frame.dart
│   │   │   ├── message.dart
│   │   │   └── transfer.dart
│   │   ├── protocol/
│   │   │   ├── frame_codec.dart      # 帧编解码（headerLen + JSON + payload）
│   │   │   └── payloads.dart         # 各帧类型的 payload 定义与序列化
│   │   ├── discovery/
│   │   │   ├── discovery_service.dart
│   │   │   ├── announce.dart         # ANNOUNCE 包编解码
│   │   │   └── network_interfaces.dart  # 网卡枚举与虚拟网卡过滤
│   │   ├── transport/
│   │   │   ├── feijian_server.dart     # 单端口监听 + role 分发
│   │   │   ├── control_connection.dart
│   │   │   ├── connection_manager.dart  # 连接池 + ID 去重 + 心跳 + 重连
│   │   │   └── connection_state.dart
│   │   ├── transfer/
│   │   │   ├── transfer_manager.dart # 队列、并发上限、续传
│   │   │   ├── file_sender.dart
│   │   │   ├── file_receiver.dart
│   │   │   └── path_safety.dart      # 路径穿越防护
│   │   └── utils/
│   │       ├── id.dart               # UUID 生成
│   │       ├── logger.dart
│   │       └── human_size.dart
│   │
│   ├── data/
│   │   ├── database.dart             # drift 表定义 + 迁移
│   │   ├── database.g.dart           # 生成
│   │   ├── dao/
│   │   │   ├── peer_dao.dart
│   │   │   ├── message_dao.dart
│   │   │   └── transfer_dao.dart
│   │   └── repository/
│   │       ├── peer_repository.dart
│   │       ├── chat_repository.dart
│   │       └── settings_repository.dart
│   │
│   ├── state/                        # Riverpod providers
│   │   ├── providers.dart
│   │   ├── peers_provider.dart
│   │   ├── chat_provider.dart
│   │   ├── transfer_provider.dart
│   │   └── settings_provider.dart
│   │
│   ├── platform/                     # 平台特定适配（隔离所有 Platform.isXxx）
│   │   ├── platform_service.dart     # 抽象接口
│   │   ├── windows_platform.dart     # 托盘、防火墙、自启、拖拽
│   │   ├── android_platform.dart     # 组播锁、前台服务、MediaStore
│   │   └── download_path.dart
│   │
│   └── ui/
│       ├── pages/
│       │   ├── devices_page.dart
│       │   ├── chat_page.dart
│       │   ├── settings_page.dart
│       │   └── image_viewer_page.dart
│       ├── widgets/
│       │   ├── my_device_card.dart
│       │   ├── device_tile.dart
│       │   ├── message_bubble.dart
│       │   ├── file_card.dart
│       │   ├── folder_card.dart
│       │   ├── transfer_progress.dart
│       │   ├── drop_overlay.dart
│       │   ├── chat_input.dart
│       │   └── empty_state.dart
│       ├── theme/
│       │   ├── app_theme.dart
│       │   └── device_icons.dart
│       └── l10n/                     # 生成物
│
├── lib/l10n/
│   └── app_en.arb                    # ★ 唯一交付的语言文件
│
├── android/                          # 权限、前台服务配置
├── windows/                          # 窗口、托盘配置
├── test/
│   ├── protocol/frame_codec_test.dart
│   ├── protocol/payloads_test.dart
│   ├── discovery/announce_test.dart
│   ├── discovery/interface_filter_test.dart
│   ├── transfer/path_safety_test.dart
│   └── transfer/file_transfer_test.dart   # 本地回环端到端传输测试
└── integration_test/
    └── two_peer_e2e_test.dart        # 单机启动两个实例互测
```

---

## 11. 开发里程碑

| 阶段 | 内容 | 验收标准 | 估时 |
|---|---|---|---|
| **M0** 骨架 | Flutter 工程、目录结构、i18n 骨架、主题、三个页面空壳 | Windows + Android 均可运行，切换语言文件生效 | 0.5d |
| **M1** 设备发现 | UDP 组播/广播、网卡过滤、Peer 模型、终端列表实时上下线 | Win 与 Android 同一 Wi-Fi 下互相可见，名称/IP 正确；关掉一端 15s 内变灰、60s 内消失 | 1.5d |
| **M2** 控制连接 + 文字消息 | 单端口监听、hello 握手、连接去重、心跳重连、消息帧收发、SQLite 落库、对话页、送达回执 | 双向收发中英文/emoji 消息；重启后历史仍在；断网重连后消息不丢不重 | 1.5d |
| **M3** 文件传输 | offer/accept/data/done、进度条、取消、`.part` 临时文件、重名处理、图片缩略图与全屏查看、拖拽发送、剪贴板粘贴 | 传输 1GB 文件内存占用平稳；传图片可内联预览；拖拽文件夹可直接发送；取消后无残留 | 2d |
| **M4** 文件夹 + 离线消息 | 目录清单、递归重建、发送队列、上线补发、失败重试 | 传含子目录的文件夹结构完整；对方离线时发消息，上线后自动收到 | 1.5d |
| **M5** 打磨与打包 | 设置页全项、自动接收策略、Windows 托盘/自启/防火墙规则、Android 前台服务/通知、手动添加 IP、空状态排查提示、Inno Setup 安装包 | 非开发人员可在两台干净电脑/手机间直接安装使用 | 1.5d |
| **M6** iOS（后续） | 权限声明、UI 适配、mDNS 发现 | — | 待评估 |

**M0–M5 合计约 8.5 人天**，可交付可日常使用的 Windows + Android 版本。

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **AP 隔离**（无线路由器开启客户端隔离） | 完全发现不到对方 | 空状态给出明确排查提示；提供"手动输入 IP"直连兜底；文档说明需在路由器关闭 AP 隔离 |
| **Android 后台被冻结** | 后台收不到消息/文件 | 前台服务 + 常驻通知（必需项，非可选）；提供省电模式开关 |
| **Android 组播锁未获取** | 收不到任何组播 | `CHANGE_WIFI_MULTICAST_STATE` + 运行时 acquire（§7.1，已实现）；同时发广播作为冗余通道 |
| **Windows 多虚拟网卡** | 广播发到虚拟网络，互相看不见 | 网卡名/地址段过滤 + 设置页手动勾选；单机双实例自测可提前暴露 |
| **防火墙拦截入站** | 能发现但连不上 | 安装器预置规则（仅 private/domain）；连接失败时明确提示"请检查 Windows 防火墙" |
| **大文件 OOM** | 应用崩溃 | 强制分块 + `flush()` 背压；代码审查禁止 `readAsBytes()` 出现在传输路径 |
| **双方同时发起连接** | 重复连接、消息重复 | 按 `deviceId` 大小决定主动方；`msgId` LRU 去重 |
| **时钟不同步** | 消息排序错乱 | 排序用本地时间戳，不信任对端 `ts`（`ts` 仅用于丢弃过期 ANNOUNCE） |
| **同名设备** | 用户分不清 | 列表显示 IP 作副标题；`deviceId` 才是主键，名称仅展示 |
| **UDP 包丢失** | 设备列表闪烁 | 5s 周期广播，15s 阈值抗丢包；收到包立即单播回应加速收敛 |
| **iOS 后台挂起** | 后台收不到 | 设计上接受，产品文案明示；核心层已解耦，不影响前期开发 |

---

## 13. 待确认事项

以下问题不阻塞 M0/M1 开工，可在开发过程中决定：

1. **中文名** —— 英文名 `Feijian` 已定，中文名待定（候选：飞笺 / 飞简 / 飞剑，需查商标）
2. **默认端口 24250** 是否合适，还是跟随传统使用 2425
3. **Android Share Intent**（分享到 Feijian）是否提前到 M3 实现 —— 建议提前，是移动端核心体验
4. **传输限速功能** 是否需要 —— v1 可不做，局域网带宽通常充足
5. **消息已读回执** —— v1 只做送达回执（`delivered`），不做已读（`read`）

---

## 附录 A：协议速查

```
UDP 24250  — 设备发现（组播 239.255.42.50 + 广播 255.255.255.255，JSON，≤1400B）
TCP 24250  — 单端口复用（首帧 hello.role 区分 control / data）

帧格式：  [uint32 headerLen][JSON header][payload *header.size]

消息流：  msg → msg_ack
文件流：  file_offer → file_accept → [新 data 连接] → file_data* → file_done → xfer_done
心跳：    ping/pong 每 30s
生命周期：announce 每 5s / bye 退出 / 15s 离线 / 60s 移除
连接去重：deviceId 字符串较小的一方为主动连接方
路径安全：接收文件名为纯 basename，剥离 ../ 与绝对路径前缀
```

## 附录 B：关键常量

```dart
// lib/core/constants.dart
const kProtocolVersion   = 1;
const kDiscoveryPort     = 24250;
const kMulticastGroup    = '239.255.42.50';
const kBroadcastAddress  = '255.255.255.255';

const kAnnounceInterval  = Duration(seconds: 5);
const kPeerOfflineAfter  = Duration(seconds: 15);
const kPeerRemoveAfter   = Duration(seconds: 60);
const kHeartbeatInterval = Duration(seconds: 30);
const kReconnectBackoff  = [1, 2, 5, 10, 30];  // 秒，指数退避

const kChunkSize         = 256 * 1024;   // 256 KB
const kMaxFrameHeader    = 1024 * 1024;  // 1 MB
const kMaxPayload         = 512 * 1024;  // 512 KB
const kMaxConcurrentXfer = 3;

const kMsgAckTimeout     = Duration(seconds: 10);
const kMsgMaxRetries     = 3;
```
