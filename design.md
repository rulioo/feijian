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

### 4.1.3 刷新必须同时修接收路径（真机结论）

真机实测（Android APK + Windows PC 同 Wi-Fi）：**长时间离线之后再回来，两端互相看不见；点刷新、点 Rescan 都没用；杀掉 app 进程重开就立刻恢复。**

最后一条是决定性的，而且和 §4.1.2 那条一模一样——重启能恢复，说明协议、端口、防火墙、网卡选择全都是好的。区别在于这次重启改变的不是**发送** socket，而是**接收**那一个。

原因：**组播成员关系属于它所在的那张网卡，网卡一 down，内核就把它丢掉了。** 这件事没有任何人通知你：socket 还开着，当初的 `joinMulticast` 也确实成功过，唯一的症状就是 announce 不再到达。而 `_rebindAll()` 当时只重建发送 socket 和应答 socket，**故意没动监听 socket**，理由是"监听 socket 从不发送，所以不会锁死，重建它只是为了重新加入组播，没有收益"。

那个理由的两半都错了：

1. 需要修的不是"锁死"，是**收不到**——这是两个方向上的故障，而刷新只修了其中一个。
2. 重新加入组播不是"没有收益"，它**就是**收益本身：它正是长时间离线之后唯一能救回来的东西。

于是"重开 app 能好"和"按 Rescan 不能好"就成了同一件事的两面：`start()` 会 join，而别的任何路径都不会 join 第二次。

**结论：`rescan()` 必须重建监听 socket 并重新 join。** 实现上有两条要求：

1. **先关旧的，再绑新的。** 两次绑定都带 `reuseAddress`，所以新 socket 不会绑定失败——它会静默分走一半的流量，而分给谁由内核决定。让监听缺席几毫秒是代价小得多的错误：announce 每 5s 一轮，刷新本身要发 3 轮，而发送侧全程都在工作。
2. **绑定失败时不能把旧的先关掉再报错。** 顺序必须是"关→绑"，绑失败就记一条**醒目**的日志（服务进入降级态：彻底没有监听），因为这时唯一的出路是用户再按一次 Rescan，而屏幕上没有任何东西提示他。

顺带发现的一个 Dart 陷阱，值得单独记：**对已关闭的 `RawDatagramSocket` 调用 `joinMulticast()` 不会抛异常，会让整个 VM 段错误崩溃**（`_NativeSocket.nativeJoinMulticast`，Dart 3.6.2 / Windows x64 实测）。`start()` 里 socket 绑定和 join 之间隔着一个 `await`（枚举网卡），`stop()` 可以在这个窗口里把 socket 关掉。所以 `_joinGroup` 首先检查自己拿到的 receiver 是否仍是当前那一个，不是就直接返回。

### 4.1.4 手动添加 IP（AP 隔离下的唯一退路）

§4.1.2 的症状（"互相搜不到，点刷新没反应，点 Rescan 没反应"）有两个互不相干的成因，处置方式完全不同：

| 成因 | 刷新能否救 | 出路 |
|---|---|---|
| 发送 socket 被 ICMP 锁死（§4.1.2） | 能——`rescan()` 重建发送 socket | 修 socket 生命周期 |
| 接收侧组播成员关系随网卡 down 丢失（§4.1.3） | 能——`rescan()` 重建监听 socket 并重新 join | 刷新必须修**两个**方向 |
| Android 没拿组播锁（§7.1） | **不能**——和 socket 无关 | 修组播锁（一次性） |
| AP 隔离：路由器丢弃组播**和**广播 | **不能** | 手动添加 IP |

这四条的**症状完全一样、成因互不相干**，这是排查时最容易走弯路的地方：用户可见表现都是"刷新和 Rescan 都没反应"。区分方法只有一个——看 discovery 实际选了哪些网卡、发出了什么、收到了什么，也就是启动那条 `listening on ... / sending via ...` 日志和 `tool/discovery_probe.dart`。

有一条经验值得单独写下来，因为它在 §4.1.2 和 §4.1.3 里各出现了一次：**"重启 app 能恢复，点刷新不能恢复"永远指向同一类结论**——启动路径做的某件事，刷新路径没做。查出那件事是什么，刷新就修好了。

AP 隔离下，两端都在正常广播，只是包根本到不了对面。更关键的是 `probe → 单播应答` 这条兜底路径也一起断了：对方收不到我们的 probe，就永远不会回那一个单播应答。所以这不是"多发几轮就行"的问题，**网络上不存在任何一条能自动走通的路**，用户唯一能做的是把地址直接告诉程序。这就是本节的由来。

**入口**：设备页空状态里的按钮，以及设备列表下方的"Add device by IP"。输入校验只判断格式合法（`InternetAddress` 能否解析），**连通性由拨号本身回答**——一个格式正确的地址和"那上面有东西在听"是两个问题。拨号期间显示不可取消的进度框：被拒绝的端口毫秒级返回，但被 **过滤** 的端口（本节存在的理由）要等满握手超时，没有转圈就和"按钮没反应"无法区分。

**拨号走的是普通控制协议**（`connectToAddress`），下游没有任何特殊分支：拿到 `hello` 后 peer 以和 announce 驱动完全相同的方式注册进 `ConnectionManager`，消息、ack 重发、断线重连全部照旧。唯一的差别是 peer 的 id 和地址从哪来。

因此它**不能复用 `requireConnection`**：那个 API 以 `peerId` 为入参，而这里的 `deviceId` 是拨号的**结果**而不是输入——在连上之前，本机根本不知道对面是谁。

失败分两种，因为用户的下一步动作不同：

| 结果 | 含义 | 文案指向 |
|---|---|---|
| `unreachable` | 没人监听、连上但不说话、握手期间挂断 | 去核对另一台设备上的地址 |
| `thisDevice` | 那个地址就是本机 | 去重看设备列表 |

**手动添加的 peer 豁免老化规则**——这是本节最重要的设计决定。上下线判定（§4.1 的 15s/60s 表）全部以 `lastSeen` 为准，而一个从不发 announce 的 peer，其 `lastSeen` **永远不会前进**。若不豁免，用户手输的地址会在 60 秒后被表清掉，看起来像"添加失败"或"自动消失了"。所以 `PeerTable` 单独维护一个 `_manual` 集合，成员不受 `applyTimeouts` 影响。由此产生四条必须一起理解的行为：

1. **会话期内持续可见，只有用户能移除**。入口在对话页 `⋮ → Remove device`（`forgetPeer`）。因为它不会被自动删，就必须有一个明确的手动出口。
2. **在线状态改由连接决定，而不是 announce**。`peerConnected` / `peerLost` 驱动 `setOnline`，所以掉线只会把它**灰显**，不会删除。这是与普通 peer 有意的差异：普通 peer 掉线删掉没关系，它下一轮 announce 就会回来；手动添加的 peer 没有任何东西能让它回来，删掉就等于用户白输一次。
3. **一旦它真的开始 announce，豁免立即失效**。`touch()` 会把它从 `_manual` 里摘掉，此后走普通规则。此时用户当初的理由（"我搜不到它"）已经不成立了。
4. **`bye` 不能删它**。`remove()` 对手动 id 返回 false——对端正常退出会发 `bye`，而"关机了"不等于"用户不想要这条记录了"。

**没有 OS 字符串**：`hello` 帧本身不带 `os`（§4.3），又没有 announce 可以取，所以它保持 `null`，设备列表只显示地址。从 `deviceType`（`windows`/`android`）反推一个版本号是把猜测说成事实，不做。

它和普通 peer 的**相同**之处也值得写明：设备记录走同一条 `recordAnnounce` 落库路径（由 discovery 的 `changes` 事件触发），所以手动添加的设备在**重启 App 之后仍然在列表里**，而不只是活在本次会话的内存里。

### 4.1.5 回前台时重扫（进程生命周期）

用户的提议是：从对话页返回设备列表时扫一次，省掉一次手动点 Rescan。**要省掉手动操作这个方向是对的，但触发点选错了**，理由有两条，第二条是决定性的：

1. **对话页打开期间发现从未停止。** `discoveryServiceProvider` 是普通 `Provider` 而不是 `autoDispose`，设备列表被压在 push 上来的路由下面、仍然挂在树上 watch 着 `peersProvider`，announce 每 5 秒照收。所以返回时那个列表本来就是实时的，健康路径上这次扫描是纯开销。
2. **真正会让状态陈旧的，是"离开过"这件事。** Android 上 Doze 冻结进程并挂起 socket，回来时手机可能已经换了 Wi-Fi；而多播成员关系属于加入时的那张网卡（§4.1.3），服务手里那批网卡还是 `start()` 当时枚举的。这两个都不会因为用户按了返回键而发生。

所以触发点定在 `AppLifecycleState`，并且**包在整个 App 外面**而不是某个页面里——"离开过"是进程的属性，不是栈顶那个页面的属性。在此之前这个项目**完全没有生命周期处理**（没有 `WidgetsBindingObserver`，也没有读 `AppLifecycleState`），所以这是补上一块空白，不是加一个补丁。

判定规则，每条都有对应测试：

| 事件 | 重扫 | 理由 |
|---|---|---|
| `paused` / `hidden` → `resumed` | 是 | 真的不在前台了：可能被冻结，也可能已换网络 |
| 冷启动那次 `resumed` | 否 | 没有"离开过"，而 discovery 刚刚 `start()` 过 |
| `inactive` → `resumed` | 否 | 失去窗口焦点、拉下通知栏也是 `inactive`，它们不会把网络拿走 |
| 离开不足 1 秒 | 否 | 重建要关掉监听 socket，有几毫秒是聋的；一个瞬时的 bounce 不值得付这个代价 |

`hidden` 和 `paused` 都算离开，是因为顺序按平台不同：Android 走 `inactive → hidden → paused`，而最小化的桌面窗口停在 `hidden`，永远到不了 `paused`。

**阈值从 2 秒改成 1 秒**，因为 2 秒太长：切到另一个 app 再切回来大约就是这个时长，于是"名单看着不对时最可能做的那个动作"恰好是唯一保证不生效的动作。代价是不对称的——多一次重建是几毫秒没人看得见，少一次是用户得手动刷新。

**真机取证（2026-10-05）**：+5 的 APK **根本不含这段代码**。用户报"点返回、激活 app 都没有触发"，我拆包核对：`libapp.so` 里 `DiscoveryService`、`ChatPage`、`DevicesPage`、`settingsProvider` 这些类名都在，**`DiscoveryLifecycle` 出现 0 次**；同一份包里 `rejoined the group` 有 3 处（三个 ABI 各一次），说明 §4.1.3 的接收路径修复在。结论：**+5 有"修复"没有"触发"**，用户报的现象完全由此解释——这也正好对上他说的"手工点一下可以"。教训：**APK 的构建时间和 commit 时间不可比**，这个项目的 APK 是从带未提交改动的工作区里构建的，只有读二进制才能确定包里有什么。

**这块测试只覆盖触发，不覆盖修复**：`rescan()` 对 socket 做什么由 §4.1.3 那组驱动真实数据报的测试负责。反过来也一样——把守卫删掉（改成只要 `resumed` 就重扫），这里会有 3 个测试失败。"冷启动不重扫""失焦不重扫""瞄一眼不重扫"这三条正是守卫存在的理由，没有它们，删掉守卫没有任何东西会报警。

### 4.1.6 心跳里加一次 probe，上线时多发几轮（真机结论）

用户报：**PC 端的 exe 不能及时发现刚上线的手机，必须手动点一次刷新才看得到**。这是他第三次报"发现"这一类问题，但和前两次不是同一个病：§4.1.2 和 §4.1.3 修的都是"包发出去了、对面收不到"，这次是**包根本没被回答**。

有一个观察把病因指得很准：**手动点 Rescan 立刻就有效**。Rescan 做的事是重建 socket，然后发 probe——而 probe 是这个协议里**唯一一个可靠地引出单播回答的包**：谁听见了都得单播回一个 announce。也就是说，单播方向一直是好的，坏的是"我们不去问"。

而名单里加一条 peer **只有一条路**：收到别人的 announce（`table.touch` 只在 `_handleDatagram` 的 announce 分支里被调用）。我们自己的 announce 走多播和广播（§4.1.1），对面听不见就是听不见，喊得再勤也没用——**坏的方向是朝着我们的那个**。probe 是唯一能反向把信息要回来的包。

所以两处改动，修的是两件不同的事：

**一、心跳每 6 轮问一次（`kProbeEveryRounds = 6`，30 秒）。** 解决"对面一直在线、我们却看不见"，比如它的多播成员关系在内核里掉了、或者 AP 不转发广播。30 秒一次是刻意的慢：每个 probe 在局域网上是"每个 peer 一个包"的成本，不是免费的。

**二、设备刚起来时发 3 轮、间隔 400ms（`kStartBurstRounds` / `kStartBurstGap`）。** 解决"手机刚上线、那一个 announce 丢了"。Windows 在真实网卡上背靠背发 UDP 大约丢 4%，而且只以"写入 0 字节"的形式报告；Wi-Fi AP 还可能整包吃掉一个广播。设备加入网络只有那么一个瞬间能自我介绍，而那正好是它的主人在盯着屏幕看的瞬间。第一轮仍然是同步的（`start()` 返回前就上了线），后两轮是定时器。

**怎么写这条测试，比改动本身更值得记。** 断言**包数**是错的工具：这台机器上 3 轮和 1 轮收到的多播副本都落在个位数区间，一个计数断言会在**正确**的代码上随机失败。改成测 **probe 的时间跨度**（`_Wire.probeSpan`）：3 轮相差 102-108ms（25 次实测），1 轮恒定 0ms。它只要求第一轮和最后一轮各活下来一个包，丢任何一个中间包都不影响——这正是 burst 存在的性质本身（"几毫秒内同时出去的三个包，就是一个 Wi-Fi 打嗝能一起带走的三个包"）。

还有一条测试代码里的坑：`_Wire` 必须在**每张 IPv4 网卡上** join 多播组。不 join 的话，往一个本机没有成员的多播组发送会引来 ICMP port-unreachable，反过来把发送 socket 锁死（§4.1.1），现象是"除了第一轮，后面几轮一个都收不到"——一个看起来像被测代码有 bug 的测试环境 bug。

守卫都做过删除验证：删掉 burst 调用 → 跨度变 0ms；把间隔改成 0 → 跨度 4-5ms；删掉周期性 probe → 心跳那条约 15 秒后超时。

### 4.1.7 看门狗：全都没声音时自己重建（真机结论）

§4.1.2、§4.1.3、§4.1.6 修的都是"某个方向不通"，而它们的修复动作**都由某件事触发**：收到一个数据报、来了一个生命周期事件、用户按了一下 Rescan。这一节是第三种坏法，也是唯一一种**什么都不会发生**的坏法：内核把多播成员关系掉了、监听 socket 悄悄不再投递、网卡在底下被重置——都没有错误码，也都不是"喊得更大声"能修的，因为坏的方向是朝着我们自己的。机器就停在那儿，显示着一份它已经听不见的名单。

所以：**如果这台机器听得见的每一个 peer 都沉默了 `kSilentPeerRebindAfter`（20 秒），就重建一次 socket**——和用户手按 Rescan 做的是同一件事，只是不用手按。

几个刻意的选择：

**"全都沉默"而不是"某个沉默"。** 只要还有一个 peer 在说话，就说明网络投递是好的，沉默的那些是真的走了；按那个条件重建，等于每关一台笔记本就聋几毫秒。

**20 秒 = 4 个心跳，且刻意定在 `kPeerOfflineAfter`（15 秒）之后。** 到那个时候名单已经肉眼可见地变灰了，于是"修好"这件事发生在用户还盯着症状看的时候，而不是他已经放弃之后。

**手动添加的 peer 两个方向都不算数**：它们是用户点开时走 TCP 拨过去的，本来就不该 announce，沉默说明不了网络的好坏。

**一次沉默只修一次**（`_silenceRepaired`），因为"全都沉默"在**网络完全正常**的情况下也成立——一个真的离开的 peer 在 `kPeerRemoveAfter` 之内还留在表里。所以规则是：一次沉默一次重建，直到重新听见什么为止，而不是每秒一次。

那个"重新听见"的复位点（`_silenceRepaired = false`）位置是**承重的**：它必须在自身 id 检查**之后**。自己的广播会回到自己的监听 socket 上，如果那也算"有人来了"，看门狗自己发出去的 probe 就会把它自己设下的闸清掉，于是每秒重建一次，永远。

守卫全部做过删除验证：删掉 `_applyTimeouts` 里的调用 → 测试超时；把"每个 peer 各自判断"改成忽略时间差 → "有人还在说话时不修"那条失败；删掉一次一修的规则 → "一次沉默只修一次"那条失败；把复位点挪到自身检查之前 → 同一条失败。

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
| `hello` | 双向 | `role`, `deviceId`, `name`, `device`, `icon`, `port`, `version`, `caps`, `xferId?` | 连接建立后**第一帧**，`role` ∈ `control`/`data`；`xferId` 见 §4.4.2 |
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

#### 4.4.2 data 连接的归属与路由（M3 实现约定）

`role=data` 的连接是**一次传输的私有 socket**，不属于连接池。这一层已经实现（`ConnectionManager.dataConnections` / `connectData`），下面几条是实现时定下来的。

| 决定 | 结论 | 理由 |
|---|---|---|
| `hello` 增加 `xferId?` | **可选**，控制连接上完全不发送 | `file_data` 带 `xferId`，但接收方在 data socket 上看到的第一帧是 `hello`。并发上限 `kMaxConcurrentXfers = 3`，没有这个字段就只能先缓冲一个来路不明的 socket、等第一个 `file_data` 来猜归属；发送方开了连接却不发数据时，这个 socket 永远没人认领 |
| 应答帧回显 `xferId` | 接收方用 `selfHello.answering(request)`，**role 和 xferId 都取自对方的请求** | 只回 role 不回 xferId，发送方就无法确认"我请求的那条 data 连接被接受了"——回显什么都不能说明，等于该字段白加。这是实现时真实踩到的：offering 侧拿到 `peerHello.xferId == null`，测试当场失败 |
| 不携带 `xferId` 的 data 连接 | **立即关闭**并记日志 | 没有传输可以认领它。放着不管等于替一个不存在的传输长期持有一个 socket 和一条心跳 |
| 无人监听 `dataConnections` 时 | **立即关闭**并记日志 | data 连接是不请自来的，没人认领就永远没人关。会话层在构造时就订阅，不是等用户点开某个会话才订阅 |
| data 连接断开 | **不上报 `peerLost`、不触发重连** | 一次正常完成的传输结束时 socket 就是会断的。当成掉线会去冲刷离线队列、把在线设备变灰 |
| 帧的归属 | 连接**握手完成、role 确定之后**才 `listen(frames)` | `ControlConnection.frames` 是单订阅流：谁先 attach 谁就拥有这条 socket 的全部帧。data 连接的帧归传输，控制连接的帧归连接池。握手前不会丢帧——`ControlConnection` 会丢弃 ready 之前的非 hello 帧，而单订阅 controller 在有 listener 之前会缓冲 |
| 停止时要关 data 连接 | `stop()` 单独遍历 `_dataSockets` | 它既不在任何 `_Peer` 槽位里，也不在 server 的 accept 清单里（主动拨出的那条尤其不是），不显式记住就没有第二个人会关它 |

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

#### 4.6.1 字节搬运层的实现约定（M3）

把文件读出去、把文件写进来这一层（`lib/core/transfer/`）已经完成。下面几条是实现时才定下来的，写在这里以免以后重新争论。

| 决定 | 结论 | 理由 |
|---|---|---|
| 接收端"传完了"的判据 | **字节数齐全**，`eof` 只作记录 | 空文件没有任何数据块，也就永远不会有 `eof`。把它当判据，等于所有 0 字节文件都永远传不完 —— 这是实现时踩到的真实 bug，即 §4.6 流程图里 `file_data eof` 与 `file_done` 两个信号对单文件是冗余的 |
| 背压阈值的单位 | **字节**（`kFileFlushBytes = 2 MB`），不按块数 | 块大小是可注入的（测试用 4 KB）。按块数算，阈值会随块大小漂移；按字节算，"在途数据 ≤ 2 MB"这条不变量与块大小无关 |
| `flush()` | 必须 `await` | 不 await 的 flush 根本不是背压：循环会照常冲在前面，缓冲区照常长大 |
| 循环结束 | 尾块后**补一次** flush | 否则最后不足 2 MB 的部分留在缓冲区里，进度条停在 99% |
| 断点续传 | **延后**，`file_accept` 一律回 `resumeFrom: 0` | 见下 |
| `FrameSink` 接口 | 只为让发送循环可测 | 真实的 socket 无论发送方怎么做都会立即接受写入，对端看不出有没有 flush —— 节奏是这一层唯一要保证的东西，而它需要一个可数的接收端 |

**为什么续传要延后，而不是顺手做掉**：判断"能不能从这个 `.part` 接着写"的依据必须是 `transfer` 表里那次未完成传输的 `bytes_total` / `temp_path`，不能是"下载目录里有个同名 `.part`"。后者会把两次内容不同的同名传输接在一起，产物是一个大小正确、内容错乱、双方都报告成功的文件 —— 和 §4.6.1 上面那条"字节数齐全"一样，是必须由发起方而不是文件名来决定的事。等会话层建好了 `transfer` 行，续传就是它的三行代码。

**路径穿越防护在 `SafeName.fileName()`**：只保留最后一个路径分量，剥离控制字符、Windows 非法字符集、Windows 保留设备名（`CON`/`NUL`/`COM1`…，按 stem 判断所以 `CON.txt` 也中）、首尾空白与结尾的点。长度按 **UTF-8 字节**截断而不是字符数，并且保留扩展名 —— 一个 255 字符的中文名是 765 字节，按字符数放行会在文件都已经传完之后才被文件系统拒绝。

**这块的测试与被破坏时的表现**（每组都实际验证过删掉守卫会有测试失败）：`safe_name_test.dart` 22 条（其中一组枚举恶意输入，断言输出永不为空、永不为 `.`/`..`、永不含分隔符与冒号）；`incoming_file_test.dart` 26 条用真实临时目录，因为要验的是文件系统最后剩下什么；`outgoing_file_test.dart` 23 条用一个记账用的假 sink，删掉周期性 flush 会有 2 条失败、把 `await flush()` 改成不 await 会有 1 条失败；`transfer_receiver_test.dart` 27 条，删掉 offset 校验 / xferId 校验 / 越界校验分别有 3 / 2 / 2 条失败。

---

---

#### 4.6.2 文件夹在会话层的实现约定（M4）

§5.1.1 管的是文件夹在库里长什么样，这里管的是**一次文件夹传输在两端各自怎么走**。§4.6 的规则落到 `TransferService` 上时又定下来这些。

| 决定 | 结论 | 理由 |
|---|---|---|
| 接收端什么时候建 receiver | **收到第一个说出文件名的帧时** | 一条 `role: data` 连接到达时，帧里还没有 `relPath` —— 那是这条连接上第一个 `file_data` 才有的（§4.6 规则 3）。所以 `_onDataConnection` 的准入条件是"这个 offer 已被接受"（`decided`），不是"已经有 receiver"；按后者写会把文件夹的每条连接都拒掉 |
| 谁来建 receiver | 两个入口都要，但**只能建一次** | 能启动一个文件的只有两件事：它在数据连接上的第一个 `file_data`，和发送方为**零字节文件**在控制连接上发的 `file_done`。两者都可能在对方还没公布 receiver 时到达 |
| 回执里的 `relPath` | 每个文件的 `file_done` 都必须带 | 一次文件夹的所有文件共用一个 `xferId`（§4.6 规则 3），回执不点名，第二个文件的回执就会被读成第一个的答案 |
| `xfer_done` 的语义 | **陈述，不是信号** | 两端各数各的文件，谁都不靠这一帧知道自己完事了。所以 `_onTransferFrame` 里这一支是**空操作** |
| 一个文件失败之后 | **文件夹继续** | 一个文件发不出去不等于整个文件夹发不出去，后面那些可能正是用户要的。任务最后以 `failed` 结束，而已经落地的文件留在磁盘上（§5.1.1） |
| `file_cancel` 不带 `relPath` | 整个任务作废 | 这就是"取消"在一个文件夹上的意思 |
| 取消恰好落在"文件正在改名入位"这个窗口 | 这个文件**保留**，后面的不再取 | 见下 |
| 同名文件夹 | **合并**，不给自己编号 | 见下 |

**一次文件夹的交错：两个连接，同一个文件。** 接收端为一个文件建 receiver 要跨好几个 await（先建目录，再开 `.part`），而 receiver 是在这之后才记到 `entry` 上的。在这段窗口里，"有没有文件在收"这个判断两个入口都会读到"没有" —— 于是同一个文件被建了两份 receiver，两份都拿着同一个 `.part`。第一份改名入位时第二份还开着，Windows 直接给 `errno = 32`。症状是**一个磁盘错误**：

```
could not finish the file: PathAccessException: Cannot rename file to
  '...\holiday\notes.txt', path = '...\holiday\notes.txt.part'
  (OS Error: 另一个程序正在使用此文件，进程无法访问。, errno = 32)
```

真正的原因是两个连接（`file_data` 走数据连接、`file_done` 走控制连接）在抢同一个文件的所有权。修法是让**建 receiver 变成一次认领**：`_folderFileOf` 在第一个 await 之前就把 `entry.starting` 置上，第二个来的人 await 它的 future，拿到同一个 receiver 而不是再造一个。调用方各自跑在一条串行链上是不够的 —— 它们跑在**两条**流上。

**同一个文件的两个入口是这个里程碑唯一的真并发**，其余的地方靠的是两条不变量：数据帧串行（`_Incoming` 的队列，理由见类注释），以及"一个文件夹同时只有一个文件在途"。

**发送端开文件在开 socket 之前，接收端扔 socket 在收下一份之前。** 两条互为镜像，都是为了同一件事：**不要让"自己这边出问题"在对端看起来像"对端死了"**。

- 发送端先 `OutgoingFile.open` 再校验大小，最后才 `connectData`。反过来的话，一个自己发不出去的文件会留下一条**一帧未发就关闭**的数据连接 —— 那正是"发送方中途死掉"的样子，接收端只能据此判整个任务失败（它没有别的办法分辨）。顺序对了，这种情况在链上只留下一条点名该文件的 `file_cancel`，文件夹照常往下走。
- 接收端 `_Incoming.detach` 先清字段再 await 关闭。发送方在收到回执的**那一刻**就去开下一个文件的连接，而这时上一条还记在 `entry.data` 里的话，新连接会被当成"一次传输的第二条连接"而拒收。和 `_releaseOutgoingFile` 是同一个道理的两次出现。

**取消落在文件夹上的两个窗口。** 单个文件只有一个窗口，文件夹多一个：

- 文件正在改名入位时收到取消。这时候字节已经全到，丢不丢这个文件不是"半个东西"的问题 —— 取消的是排在后面的文件。所以 `_stopIncoming` 在这个窗口里只置 `entry.stopping`，由 `_finishFolderFile` 在落地之后处理：给对端发一条不带 `relPath` 的 `file_cancel`（它正准备开下一个文件的连接），结束任务，**已落地的文件原样留着**。判据用 `finished`（每个文件一次，见下）而不是"有没有文件在途"。
- 没有文件在途时收到取消。这就是单个文件那条普通路径，落地过的文件同样不动 —— `_releaseIncoming(cancelFile: true)` 只碰 `entry.receiver`（在途的那个 `.part`）。

**`file_cancel` 不为失败的附件写行。** 收到一个文件的 `file_cancel` 只做两件事：把这个 `relPath` 从 `expected` 里拿掉、置 `anyFailed`。附件行**故意不动** —— 任务收尾时 `TransferRepository.end` 的 `endPendingAttachments` 会一次性把所有没有结论的行写掉，而且它写得完整（`done` 永不覆盖）。这里再写一次就是同一条规则住在两个地方，外加一个中途读起来像卡住的行。

**同名文件夹合并，重名文件才编号。** `IncomingFile` 本来就会给撞名的文件让路（` (1)`、` (2)`），这就够了：第二次收到 `photos`，要的是"两张照片都在 photos 里"，而不是磁盘上多出一个 `photos (1)` 目录去冒充用户说的那个文件夹。

**一个顺带修掉的旧 bug。** `_maybeFinishIncoming` 先置 `entry.finished = true` 再调 `_failIncoming`，而后者当时的守卫里含 `finished` —— 于是安装失败（改名失败、磁盘满）**被自己静默吞掉**：行永远停在 `transferring`，还占着并发名额。守卫的职责是"别把同一件事收尾两次"，那就只该看 `cancelled`。这是实现文件夹时踩出来的，影响的是单文件路径。

**这块的测试与被破坏时的表现**（每组都实际验证过删掉守卫会有测试失败）：`transfer_service_test.dart` 的文件夹两组 9 条（`a folder crossing` 7 条、`stopping a folder` 2 条，另加一个真实的目录树对比辅助 `treeIn`），加上 `folder_manifest_test.dart` / `folder_layout_test.dart` 各自那一组。逐个实跑删掉的守卫：认领等待（`entry.starting`）、空文件夹的收尾、`_maybeFinishIncoming` 的文件夹分支、`entry.stopping` 分支、`anyFailed` 的置位 —— 分别是 6 / 1 / 5 / 1 / 1 条失败。发送端"先开文件后开 socket"的顺序由"一个文件中途变大"那条测试钉住：顺序反了，接收端会把整个任务判失败，后面本来能到的文件也就到不了。



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
  message_id     TEXT REFERENCES message(id) ON DELETE SET NULL,
  attachment_id  TEXT REFERENCES attachment(id) ON DELETE SET NULL,
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
| `transfer.message_id/attachment_id → ...` | `ON DELETE SET NULL` | 传输任务可独立于消息清理（见下） |
| `conversation.peer_id → peer` | **不建外键** | 见下 |

**`transfer` 的外键写的是 `SET NULL`，不是「默认」。** 这一格最初只写了「默认」，理由栏写的是「传输任务可独立于消息清理」——但这两句话说的不是一件事。裸 `REFERENCES` 的默认动作是 `NO ACTION`，而 `foreign_keys = ON` 时它的含义不是「别管这张子表」，是**拒绝这次删除**。于是每一条图片/文件消息（也就是每一条有 transfer 在后面的消息）都删不掉，含这类消息的会话也清不掉；UI 那边又在没等结果的情况下弹了「已删除」，用户看到的是提示成功、消息还在。真正对应那句话的是 `SET NULL`：transfer 行留下，只是松开指针，正是「独立于消息清理」。

这是 schema v2（`database.dart` 的 `schemaVersion = 2`）。外键动作是表定义的一部分，SQLite 没有 `ALTER` 能改它，只能重建表再拷行——drift 的 `m.alterTable(TableMigration(transfers))` 做的就是这个。`onCreate` 建出来的是当前版本，`onUpgrade` 只管老文件，所以升级路径平时没有任何测试走到；`migration_test.dart` 于是用手写 SQLite 造一个真的 v1 文件再打开它，验的是「行还在、`user_version` 到了 2、那条以前会被拒绝的删除现在能过」。

`conversation.peer_id` 不加外键，是对最初草案的修正。原因是 `peer` 表只是"设备广播内容的缓存"，而 `conversation`/`message` 是**用户自己的数据**。一旦建了引用，"忘记此设备"这个唯一会删除 peer 行的操作就只剩两种结局：

- 默认的 `NO ACTION`：SQLite **拒绝删除**，功能直接不可用；
- `ON DELETE CASCADE`：删设备顺手把聊天记录一起抹掉，且不可撤销。

两者都不可接受——用户整理设备列表不该付出丢历史的代价。另外 `message.peer_id` 本身就没有引用，说明"有 peer_id 但没有 peer 行"本来就是这份 schema 允许的状态，单给 conversation 加约束连一致性都换不来。

**草稿会自己建出会话行**。`conversation` 行本来只在落第一条消息时创建（§5.1 的 `ensureConversation`），但草稿完全可以先于消息存在——给一个刚发现的设备打第一个字，正是最常见的场景，此时那行还不存在。所以写草稿前先 `ensureConversation`：否则 `UPDATE ... WHERE peer_id = ?` 匹配零行，SQLite 照样报成功，用户切到别的设备再切回来，打了一半的字就没了。这时会话行的 `last_msg_at` 仍为 NULL——草稿不是消息，不该把设备列表按"最近消息"重排，也不该动未读徽标。

#### 5.1.1 文件夹在库里的形状（M4）

§4.6 的文件夹是"一条消息配多个文件"，落到 §5.1 的表上就是三样东西：

| 行 | 数量 | 内容 |
|---|---|---|
| `message` | 1 | `type = 'folder'`，`text` 是**文件夹自己的名字** |
| `attachment` | 每个**文件**一行 | `rel_path` 是它在文件夹里的位置，`file_name` 是最后一段 |
| `transfer` | 1 | 整个任务的 `xferId`，`attachment_id` 为 **NULL** |

几条定下来的理由：

- **文件夹名放在 `message.text`**：单个文件的名字在它自己的 attachment 上；文件夹没有"自己"的 attachment 可以承载名字（那些 attachment 都是里面的文件），而接收端需要它——那是下载目录下要创建的目录名。
- **目录不生成 attachment**：目录没有字节。空目录靠清单里的 `isDir` 条目重建（§4.6 规则 4），给它一行 attachment 等于给一个不是文件的东西画文件卡片。于是"只有空目录的文件夹"是一种合法消息：有任务，零附件。
- **`transfer.attachment_id` 为 NULL**：§4.6 规则 3 让文件夹里每个文件共用同一个 `xferId`，没有一个 attachment 代表得了这次尝试。这个 NULL 同时是两种结束的区分依据——`file_done` 结束一个文件，`xfer_done` 结束整个任务。
- **失败不覆盖已经落地的文件**：传到第七个才失败的文件夹，前六个文件已经在磁盘上、用户能打开；把这些行改成 `failed`，就是一张盖住它们的卡片。所以收尾只作用于「还没落地的」那些行，`done` 永不被改写。
- **附件读出来是列表而不是单值**：原来按 messageId 建 `Map<String, Attachment>`，一个九文件的文件夹只会留下查询最后返回的那一行——在 UI 上表现为"文件夹只显示了其中一个文件"。整条读路径（DAO → repository → `ChatState` → 页面）因此都改成了列表。
- **任务单独按消息读**：文件夹的实时进度没有 attachment 可以挂（`_live` 按 attachmentId 索引），所以另有一张按消息 id 索引的任务表；重试写新行而不是改写旧行，读的时候取 `updated_at` 最新的那次。

**这块的测试与被破坏时的表现**（16 个变异逐个实跑）：`manifest_entry_test.dart` 10 条，`transfer_repository_test.dart` 的文件夹两组 23 条。删掉目录过滤（`if (!entry.isDir)`）、不给 `message.text` 写文件夹名、让任务的 `attachment_id` 不为 NULL、收尾时覆盖 `done`、把 `transferred` 写死成 0、`localPath` 不做分隔符转换、`putIfAbsent` 改成赋值、去掉 `attachment_id IS NULL` 过滤、`updated_at` 改升序、`name` 直接返回整个 `relPath`、去掉空分量过滤、反斜杠不再算分隔符——每一个都有测试失败。

有两处空值守卫（`insertAttachments` 的空批次、`attachmentsForMessages` 的空 id 列表）**没有任何测试能钉住**：实跑删掉后全部通过（drift 把空批次的 batch 和 `isIn([])` 都处理成了它们本该有的样子），按项目标准删掉了，空文件夹那条路径现在走的是真实查询。排序是唯一的例外——`ORDER BY rel_path` 删掉同样不报错（发送端本来就走一遍有序的清单，写入顺序恰好等于路径顺序），但它的承诺是真的（卡片不会在刷新后重新排列），于是补了一条"写入顺序 ≠ 路径顺序"的测试把它钉住。

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

#### 5.2.2 离线队列的实现约定（M4）

规则 3、5、6 落在两个对象上，因为队列本来就是两张表：**文本队列**是 `message` 的行，归 `LanService`；**文件队列**是 `transfer` 的行，归 `TransferService`。补发一句话都是"查库、按序、沿用原 id"，但补发的**单位**不同——消息补发一条文本帧，文件补发一个 `file_offer`（文件夹是"一份清单 + 每个文件各开一条数据连接"）。

**`pending` 在文件传输上必须只表示"从没上过线"。** 这是这一节所有规则的地基，也是 M3 到 M4 改动最大的地方。

| 决定 | 结论 | 理由 |
|---|---|---|
| 什么时候告别欠 | `markOffered` 写在 `sendTransfer` 成功**之后、等回执之前** | 只有"从没上过线"才需要补发（规则 5），而"正在等回执"不是。写入放在等回执前，是为了让下一毫秒被杀的进程不会回来以为"没人被问过" |
| 没人可问时 | `_runSend` / `_runSendFolder` **直接 return**，行留在 `pending` | M3 在这里抛 `TransferException`，于是"对方离开两秒"就变成用户要重新挑一次文件。返回而不是抛，是把这次尝试变回一笔欠账 |
| 启动清扫扫谁 | `unfinished()` 只扫 `offered` / `transferring`，**`pending` 不再算** | 被杀掉的进程留下的"半途"确实只能是这两个状态之一（`markOffered` 是进入 `offered` 的唯一入口）。把 `pending` 也算进去，会在启动时把一整条离线队列判失败——正是规则 6 要救的东西 |
| 删除/改动过的文件 | `failed`，不再是欠账 | 见下 |

**残留窗口，明说。** `sendTransfer` 成功、`markOffered` 落库之前进程被杀：行停在 `pending`，而对端可能真的收到了那份 offer。下次补发会沿用同一个 `xferId` 重发，对端按 xferId 认领（`_claim`）拒掉重复，发送方在旧的 socket 上等不到回执、超时判失败。代价因此是**一次超时**，不是两条消息。要彻底消掉它得让"上线"和"记一笔"变成一次原子操作，而它们一个在 socket 上、一个在库里。

**补发的顺序读消息的 `created_at`，不读 transfer 的 `updated_at`。** `owedOutgoing` 在 `transfer` 与 `message` 之间 join，按 `message.created_at` 升序。同一个文件夹的多个文件共用一条消息（§5.1.1 规则 3），它们的 `updated_at` 会落在同一毫秒——§5.2.1 正是为了消掉这种并列才让 `created_at` 在会话内严格递增。

**文件夹的补发从行上重建，不重新走目录。** 每个文件的路径来自它自己的附件行的 `local_path`，文件夹名来自消息体（§5.1.1）。代价是明说的两条：**空目录没有行**，补发时带不出去；**本次选完之后新加进目录的文件**不会被补发——因为规则 5 要补的是"用户当初做的那次 offer"，而卡片列的正是这些附件行，两者必须一致。删除的东西：`FolderManifest.fileOf`（没有 lib 调用方也没有测试）和 `_Outgoing.directory`（文件夹的文件改成从各自的附件行读）。

**文件不见了或变了，就写掉，不再欠着。** 三种情况走同一个 `_abandon`：行里没有路径、文件读不出来（`FileSystemException`）、大小和当初 offer 的不一样。`_abandon` 只写行、发事件，**不发 `file_cancel`**——对端从没听说过这个 `xferId`，发一帧关于它的取消是荒谬的。"文件已不存在"这句话由已有的重试路径说（`retryAttachment` → `RejectReason.notFound` → `l10n.fileMissing`），气泡上的 ✗ 因此按下去会**说话**，而不是再失败一次。

**一次补发不超过 `kMaxConcurrentXfers`，剩下的等名额。** 第 4 个 offer 会被对端用 `busy` 拒掉，而 `busy` 是一个**结局**——无视上限的补发会亲手弄死它要救的那些传输。空出的名额由 `_releaseOutgoing` 补上，且**只在以 `done` 结束时**再触发一次：失败的东西有自己的结局要显示，而"刚回来就又被欠下"的那次不能自己触发自己，否则一个自称在线、拒绝每次写入的 socket 会在这里空转。

**两次补发的重叠靠一次同步认领挡住。** 触发补发的事件有两个——连接建立、传输完成——它们互相独立，可以在同一个窗口里都读到同一批欠账行。同一个 `xferId` 上建两个 `_Outgoing` 会把同一份 offer 发两遍：对端拒掉第二份（id 已经被它认领），而发送方正在等**第二份**的回执，于是把一次进展顺利的传输判失败。所以 `_offerOwed` 在第一个 await 之前 `_claim`，`_abandon` 在写掉行的时候 `_release`。

**规则 3a（新 ANNOUNCE 补发文本）挂在已有的 `changed` 分支里。** `LanService._absorbAnnounces` 本来就在"这台设备的公告变了"时写一次库；补发放在同一个分支内，而不是并排再写一个 `if (changed)`：让一条公告值得写库的理由，正是让它值得顺手清一次队列的理由，而一台每几秒重复自己的设备不构成新闻——每次重复都查一次队列就是网络上每台设备的开销。

**这块的测试与被破坏时的表现**（16 处逐个实跑删掉，数字是报出的失败数）：

| 删掉的东西 | 失败数 |
|---|---|
| `_runSend` / `_runSendFolder` 的"没人可问就欠着"分支 | 32 / 34 |
| `_runSend` / `_runSendFolder` 的 `markOffered` | 23 / 18 |
| `_releaseOutgoing` 里以 `done` 为条件的那次补发钩子 | 17 |
| `_offerOwed` 的并发上限 | 65 |
| `_reofferFile` 的三条放弃（无路径 / 读不到 / 大小变了） | 19 / 21 / 20 |
| 新 ANNOUNCE 时的文本补发 | 14 |
| `owedOutgoing` 的 `created_at` 升序 | 96 |
| `_offerOwed` 的两个 `isConnected` 预检 | 0 |
| `_offerOwed` 的重叠认领 `_claim` | 0 |
| `_abandon` 的 `_release` | 0 |
| `_reoffer` 的"没有消息"放弃 | 0 |

后四项**没有测试钉住**，留着是有意的，理由各不相同，记在这里免得下次被当成死代码删掉：

- **两个 `isConnected` 预检**是预过滤器不是守卫：删掉之后行为不变——没连接时建出来的 `_Outgoing` 会立刻从 `_runSend` 回到欠账状态，行还是对的。它们只省一次查库和几次 stat。代码注释里也是这么写的。
- **`_claim`** 保护的是上面那段重叠：要让它失败得让两次触发落进同一个只有一次 await 宽的窗口，测试最多做到"很可能"，做不到"一定"，所以上限那条测试里加了一句"每个 `xferId` 只被 offer 一次"当弱断言，而不是假装它被钉死了。
- **`_abandon` 的 `_release`** 漏掉看不出来：id 不会被复用（重试是同一个气泡上的**新** `xferId`）。留着是因为 `_known` 的含义是"现在属于我的 id"，而一个已经写掉的传输不属于任何人。
- **`_reoffer` 的"没有消息"放弃**：`beginOutgoing` 一定建消息，所以这条分支现在到不了，它存在的意义是让 `Transfer.messageId` 为 null 这件事有个**结局**而不是悬着。

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
| 拖拽文件到窗口 | 整个对话区变高亮遮罩层，松开即发送（Windows）。拖进来的是目录就按文件夹发（§4.6），与 📁 按钮同一条路径 |
| Ctrl+V 粘贴图片 | 直接作为图片消息发送 |
| Ctrl+V 粘贴文件路径 | 识别为文件，作为文件消息发送 |
| 图片气泡点击 | 全屏查看器，支持双指/滚轮缩放、左右切换同会话图片 |
| 文件卡片点击 | 已下载 → 系统默认程序打开；未下载 → 开始下载 |
| 文件夹卡片 | 计数而不是列名字（`24 files · 156 MB`）；进度条是**整个任务**的百分比。已落地的文件逐行列出（最多 5 行，其余折成 `…and N more`），每行有自己的 Open / Save as |
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

#### 6.3.2 对话页 ⋮ 菜单

| 项 | 行为 |
|---|---|
| Device info | 显示 `deviceId` / 地址 / 类型 / 系统 / 在线状态。这一页是排查现场：对方报告"连不上"时，两边对照 `deviceId` 与前缀是否同网段 |
| Clear history | 清空本机会话（§6.3.1），二次确认 |
| Remove device | 把设备从列表移除，并断开与它的连接。**只对手动添加的设备出现**（§4.1.4），分隔线以下，红色 |

「Remove device」只出现在手动添加的设备上，是因为普通设备的去留由网络决定，给它一个手动删除的入口只会让人困惑（删了下一秒就回来）。而手动添加的设备豁免了老化规则，删不掉就等于永远删不掉。

移除后**对话页不关闭**。会话里那条记录还在（历史上限见 §6.3.1 的说明），关掉页面看起来像"对话被删了"，而实际删掉的只是设备条目。

#### 6.3.3 文件夹卡片读的是两份数据（M4）

文件卡片只读一个 `attachment`，因为一个 attachment 就是那件事的全部。文件夹不是：它的**名字和文件清单**在 `attachment` 行上（§5.1.1：一个文件一行，消息上只有文件夹自己的名字），而**它走到哪一步了**只有 `transfer` 行知道——§4.6 给整个文件夹一个 `xferId`，任务是这个 `xferId` 的行。所以 `FolderCard` 收两份：`files` 和 `task`。

`task` 可空且必须可空。它按页读，卡片画出来的那一帧里任务行可能还没回来；一个要求非空的卡片会在这一瞬间什么都不画。

| 卡片上的东西 | 来自 | 为什么 |
|---|---|---|
| 名字 | `message.text` | §5.1.1：文件夹自己的名字不在任何 attachment 上 |
| `24 files · 156 MB` | `files` | 计数是附件的条数；大小是**文件**的和，目录不占字节 |
| 进度条百分比 | `task.progress` | 任务的分数，不是某个文件的。否则除当前那一个之外每个文件都让条停在 0，看起来像卡住 |
| 逐行 Open / Save as | `files` 里 `isOpenable` 的那些 | 已落地的才可点。没到的文件列出来只是些点不动的名字 |
| 红字 `N files did not arrive` | `files` 里 `failed` 的条数 | 任务失败会保留已经落地的文件（§5.1.1），所以「有多少没到」和「剩下的都在这儿」要同时说 |

**最多列 5 行。** 一个文件夹可能有一千个文件，气泡还是气泡；被截断的是列表而不是文件——它们在磁盘上，上面的计数和 Open 都还在。

**Accept / Decline 是对整件事的一次回答。** §9.2 没有部分接受，所以卡片的两个按钮走的是任务的 `xferId`，不是任何一个 attachment 的 id：文件夹的 transfer 行 `attachment_id` 是 NULL（§4.6 规则 3），`acceptAttachment` 那条按 attachment 找 `xferId` 的路径**找不到它**。Cancel 同理，停的是任务——正在写的那个文件连同 `.part` 一起丢掉，后面的文件发个 `file_cancel` 告诉对方别发了（§4.6），已经落地的留下。

**失败的文件夹没有 retry。** §5.2 的重试要重新读一遍源文件，而文件夹的源不在卡片手上的任何一行里（§4.6 规定文件夹的文件留在发送端磁盘上，清单只在线上走一趟）。所以发送端气泡上是那个红叉，点了没有反应——`MessageBubble.onRetry` 因此是可空的：做不成的按钮不如没有按钮，一个按下去只有沉默的图标比一个普通图标更糟。想重发就再拖一次，或者再点一次 📁。

**改动记录（变异测试）**。逐条摘掉护栏后跑 `test/ui/chat_page_test.dart` 与 `test/ui/message_bubble_test.dart`，13 条全部被测试抓到，没有活下来的：

| 摘掉的护栏 | 被几个测试抓到 |
|---|---|
| `message.type == MessageType.folder`（当成普通文件消息） | 29 |
| 给卡片传 `task` | 21 |
| Cancel 走 `cancelTask(task.id)`（改成走某一个文件的 `cancelAttachment`） | 8 |
| Accept 走 `accept(task.id)`（改成 `acceptAttachment`） | 10 |
| Decline 走 `decline(task.id)`（改成 `declineAttachment`） | 9 |
| 文件夹的 `openable`（改成恒为 false） | 16 |
| 卡片标题下不再重复画一遍名字（`&& !folder`） | 16 |
| 进度条只在 `transferring` 时画 | 16 |
| 只列 `isOpenable` 的文件 | 15 |
| 列表上限 5 行 | 13 |
| 红字里数 `failed` 的文件 | 12 |
| 未应答时才给 Accept / Decline | 18 |
| `notFound` 用文件夹自己的那句话（改成文件的失败文案） | 17 |

**测不到的一处**：`FileChooser.pickFolder` 里「Android 上拿到 `/` 就当用户取消了」这条护栏在本机测不了——`Platform.isAndroid` 在 Windows 上是 false，而 `lib/platform/` 是平台接缝，按惯例没有单测。这条靠真机复验。

### 6.4 页面三：Settings

| 分组 | 项 |
|---|---|
| **Profile** | Display name（默认系统主机名）、Device icon、Avatar |
| **Files** | Download folder（默认 `Downloads/Feijian`）、Confirm before receiving（**默认关**，见下） |
| **Network** | Listen port、组播地址、启用的网卡多选、传输限速（可选） |
| **Notifications** | Message notifications（**默认开**，控制新消息提示音，见 §6.6） |
| **System** | 开机自启（Windows）、最小化到托盘（Windows）、后台常驻（Android 前台服务） |
| **Language** | English（v1 唯一选项，下拉框已就位） |
| **About** | 版本、协议版本、开源许可 |

**接收确认（`confirmBeforeReceiving`，默认 `false`）**

关（默认）＝收到图片和文件直接接收，不弹任何确认；开＝每个文件都要用户点 Accept 才接收。

开关的**名字就是极性**，这是刻意的。同一个设置也能写成「Receive without asking」，默认开——那样产品行为完全一样，但默认值藏在双重否定里。早期草稿正是后一种：一个三选一的 `AutoAcceptPolicy`，默认值 `askEveryTime`，与本条要求正好相反。

之所以是**一个开关而不是三选一**：`Images under __ MB` 需要一条尺寸配置、`All from trusted devices` 需要设备信任标记，而 v1 里没有任何地方会写入这两个值。摆出三个选项、其中两个是空壳，比不摆更糟。真正实现它们时再引入选择器，那时 `confirmBeforeReceiving` 会变成其中一个分支。

默认关还有一个理由：这是局域网内的可信工具，用户按下发送就是想让它到，中间多一次点击是纯粹的摩擦。想收紧的人自己打开开关。

### 6.5 视觉风格

- **Material 3**，浅色/深色跟随系统（Windows 用 `window_manager` 读取系统主题）
- **主色**：青蓝 `#0EA5E9`（科技感，且与飞鸽传书的红黄配色形成区分）
- **字体**：系统默认（Windows `Segoe UI` / Android `Roboto`）。**不打包自定义字体** —— 系统字体对各语言（含 CJK、阿拉伯语、emoji）的覆盖最完整，打包字体反而会出现豆腐块
- **设备图标**：Windows/Android 客户端内置 4 个矢量图标（desktop/laptop/phone/tablet），用户可切换
- **头像**：默认用设备图标 + 名称首字母生成的彩色圆形；支持上传自定义图片
- **未读角标**：**红色**（`colorScheme.error`），不是主题主色。主色 `#0EA5E9` 是这个 App 到处都在用的强调色，一个数字画在上面读起来像装饰；红色是这个界面里唯一表示「有东西在等你」的颜色，而且它本来就是这个主题为这件事保留的语义色——深色模式下会自动切成更亮的那一档，不会在深底上留一块暗红

### 6.6 新消息提醒（声音）

收到消息时响一声，Windows 和 Android 都要。由 **Settings → Notifications → Message notifications** 控制，默认开。

**响两次的来源，一个出口。** 消息可以经由两条路径到达：

| 来源 | 流 | 说明 |
|---|---|---|
| 文字消息 | `LanService.messagesArrived` | §4.3 的 `message` 帧，落库后广播 |
| 文件/文件夹 | `TransferService.offers` | 消息行由传输引擎自己写（§5.1），不经过 `LanService` |

文件不是次一等的消息：§5.1 里它本来就是一个消息加一个背后的 transfer，对话页也把它们画在一起。只听文字的提示音，恰恰会在用户最可能不在场的那次到达上保持沉默。

两条流可以共用一个消费者，是因为这个消费者**只消费不产生**——它不写库、不广播、不触发任何会再发消息的东西。这跟 §6.2 未读角标当初那个坑（读消息 → 标记已读 → 广播 → 刷新 → 再标记已读）不是一回事：那里两个总线互为因果，这里只有一个终点。

`messagesArrived` 是**另一条流**而不是 `messagesChanged` 上的标志位，因为后者问的是「这个 peer 的历史变了没有」，它在我们自己发的消息被 ack、被重排、被写库时同样会触发。挂在它上面的提示音会在每次自己的消息被确认时响一声。

**重复帧不响。** §4.2 的重试意味着同一个 `msgId` 可能到达多次；对端重拨不是对端有新话说。`messagesArrived` 只在 `isNew` 时发出。

**节流 2 秒（`kChimeCooldown`）。** §5.2 让消息在投递前一直算「欠着」，所以一台离开一小时的设备在重连的瞬间会把积压全部交出来，三十条消息落在同一秒里。三十声不是三十倍提醒，是一声噪音加一个被用户关掉的开关。2 秒短到「前后脚打的两条消息」仍然听得出是两条，长到能吃掉一次积压。这是去抖，不是摘要——不做「3 条新消息」那种汇总，那需要一套 UI，而对话页已经把它显示了。

**用系统提示音，不带自己的音频资源。** Windows 走 Flutter 自带的 `SystemSound.play(SystemSoundType.alert)`；Android **不能**走这条——框架文档明说 `alert` 在移动端被忽略（「Desktop platforms are the only platforms that support a system alert sound」），调用正常返回、什么都不响，这是功能缺失最难被发现的一种形态——所以 Android 走 `MainActivity.kt` 里的 `RingtoneManager`。用系统音而不是打包一个 mp3：提示音就是这个设备对「有东西来了」的既定表达，而且它天然受通知音量、静音开关和勿扰模式管辖。一个局域网小工具没有重要到可以绕过这些。

**已知边界**：进程不在前台且已被系统挂起时不会响（Android 没有前台服务，`backgroundService` 设置项尚未接线）。这是 v1 的取舍，不假装成别的。

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

**尚未实现**。目前对"被冻结过"这件事的唯一处置是回前台时重扫一次（§4.1.5），它能让用户回来时看到正确的列表，但冻结期间收到的消息仍然要等对端重连补发（§5.2）——前台服务要解决的问题比这个更大，是"后台也能收"。此段保留为待办。
> 🔵 **Feijian is running** — 3 devices online
>
> *Tap to open*

通知栏常驻是 Android 生态的既定代价，不做则产品不可用。设置页提供"仅在使用时在线"开关（关闭前台服务，省电但后台收不到消息）。

**存储策略**：

| 文件类型 | 保存位置 |
|---|---|
| 所有文件（正式副本） | App 文档目录下的 `Feijian/` —— 这才是 `attachment.localPath` |
| 图片 | **额外**发布一份到系统相册 `Pictures/Feijian`（MediaStore，Android 10+ 无需权限）—— 已实现 |
| 视频 | `Movies/Feijian` —— **未实现**（v1 不发视频） |
| 其他文件 | `Downloads/Feijian`（MediaStore Downloads）—— **未实现**，见下方 TODO |
| 应用内部临时 | `getExternalFilesDir()` 下的 `.part` 文件 |

**图片为什么存两份**：`attachment.localPath` 必须是真实文件系统路径，五处按路径使用它——打开文件（`existsSync` 守卫 + `OpenFilex.open`）、另存为（`File.copy`）、缩略图（`Image.file`）、大图查看（`FileImage`）、续传时取文件长度（`File.length`）。把它换成 `content://` 会一次性全部失效。所以私有那份仍是 App 的正式副本，相册里是**额外**拷贝。代价是图片占用翻倍；换来的是两者互不牵连——用户在相册里删掉那张图，聊天里对应的消息仍然打得开（见 `lib/platform/gallery_saver.dart`）。

**"该进相册"不能复用 `Attachment.isImage`**：那条规则回答的是"Flutter 能不能解码"（`{png, jpg, jpeg, gif, webp, bmp}`），而 iPhone 发来的 `.heic` 在它眼里是 false。聊天里给它一张文件卡片是对的，相册不收录它就错了——那是用户最可能刚发来的照片。所以另有一条 `isGalleryImage`，取"相机拍出来的照片"这个集合（上面六种加 `heic`/`heif`/`avif`），`svg` 与 `tiff` 排除。两条规则并排写在 `lib/core/models/transfer.dart`。

**文件夹不发布**：一个文件夹到达时整个目录树保留在 `Feijian/` 下，把里面每张图摊平进同一个相册既压掉了结构，又可能一次灌进几百条——不是"把我收到的照片放进相册"要的东西。要放开就是从 `_finishFolderFile` 里调同一个发布函数，那里的 `row` 已经带着名字和 mime。

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

- 文件接收**默认不确认，直接接收**（Settings 里的 `Confirm before receiving` 可以打开；§6.4 说明了为什么默认是这一边）
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
| **M2** 控制连接 + 文字消息 | 单端口监听、hello 握手、连接去重、心跳重连、消息帧收发、SQLite 落库、对话页、送达回执、**手动添加 IP（§4.1.4，提前自 M5 实现）** | 双向收发中英文/emoji 消息；重启后历史仍在；断网重连后消息不丢不重；AP 隔离下可用 IP 直连并收发 | 1.5d |
| **M3** 文件传输 | offer/accept/data/done、进度条、取消、`.part` 临时文件、重名处理、图片缩略图与全屏查看、拖拽发送、剪贴板粘贴 | 传输 1GB 文件内存占用平稳；传图片可内联预览；拖拽文件夹可直接发送；取消后无残留 | 2d |
| **M4** 文件夹 + 离线消息 | 目录清单、递归重建、发送队列、上线补发、失败重试 | 传含子目录的文件夹结构完整；对方离线时发消息，上线后自动收到 | 1.5d |
| **M5** 打磨与打包 | 设置页全项、Windows 托盘/自启/防火墙规则、**Android 前台服务**、新消息提示音（§6.6，已实现）与 Android 通知栏、空状态排查提示、Inno Setup 安装包 | 非开发人员可在两台干净电脑/手机间直接安装使用 | 1.5d |
| **M6** iOS（后续） | 权限声明、UI 适配、mDNS 发现 | — | 待评估 |

**M0–M5 合计约 8.5 人天**，可交付可日常使用的 Windows + Android 版本。

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| **AP 隔离**（无线路由器开启客户端隔离） | 完全发现不到对方 | 空状态给出明确排查提示；提供"手动输入 IP"直连兜底（§4.1.4，已实现）；文档说明需在路由器关闭 AP 隔离 |
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
