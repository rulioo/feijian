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

### 4.2 帧格式（TCP）

控制连接与数据连接共用同一套帧格式：

```
┌──────────────┬────────────────────────┬──────────────────┐
│ headerLen    │  header (JSON, UTF-8)  │  payload (raw)   │
│ uint32 BE    │  headerLen bytes       │  header.size 字节 │
│ 4 bytes      │                        │                  │
└──────────────┴────────────────────────┴──────────────────┘
```

- `headerLen` 上限 **1 MB**，超限直接断开连接（防止损坏/恶意包导致内存爆炸）
- `payload` 长度由 `header.size` 决定；无 payload 的帧省略
- 单帧 payload 上限 **512 KB**（文件分块大小 = 256 KB，留余量）

### 4.3 帧类型

| type | 方向 | header 字段 | 说明 |
|---|---|---|---|
| `hello` | 双向 | `role`, `deviceId`, `name`, `device`, `icon`, `port`, `version`, `caps` | 连接建立后**第一帧**，`role` ∈ `control`/`data` |
| `msg` | 双向 | `msgId`, `ts`, `text`, `replyTo?` | 文字消息 |
| `msg_ack` | 双向 | `msgId`, `ts` | 送达回执 |
| `file_offer` | 发送方→接收方 | `xferId`, `name`, `size`, `mime`, `isDir`, `files[]?`, `sha256?`, `mtime` | 传输请求 |
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

### 4.5 消息可靠性与去重

- 每条消息有全局唯一 `msgId`（UUIDv4）
- 接收方维护最近 1000 条 `msgId` 的 LRU 集合，重复消息直接丢弃并回 `msg_ack`
- 发送方状态机：`pending` →（发出 `msg`）→ `sent` →（收到 `msg_ack`）→ `delivered`
- 10s 未收到 `msg_ack` 且连接仍在 → 重发（最多 3 次），仍失败则标 `failed`，UI 显示红色感叹号可手动重试
- **排序**：不依赖对端时钟（设备时钟可能不同步）。本地按 `(created_at DESC, msgId)` 稳定排序，`created_at` 为本地接收/发送时间

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
CREATE TABLE conversation (
  id            TEXT PRIMARY KEY,
  peer_id       TEXT NOT NULL REFERENCES peer(id),
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

### 5.2 离线消息队列

对端不在线时的处理：

1. 消息正常落库，`status = 'pending'`，立即在 UI 显示（带时钟图标）
2. 进入内存发送队列 `Map<peerId, Queue<message>>`
3. 触发补发的时机：
   - 收到该 peer 的 ANNOUNCE
   - 与该 peer 的 control 连接握手成功
4. 补发时按 `created_at` 升序逐条发送，**沿用原 `msgId`**（对端按 msgId 去重，避免重复显示）
5. 文件消息离线时，只补发 `file_offer`；文件仍在本地磁盘，可重新读取。若文件已被删除/移动，标记该消息 `failed` 并在气泡上显示"文件已不存在"
6. 应用重启后，从 `message WHERE status='pending'` 恢复队列

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
| 长按/右键消息 | 复制文字 / 另存为 / 删除本地记录 |
| 发送失败 | 气泡旁红色感叹号，点击重试 |
| 滚动到顶 | 分页加载更早历史（每页 50 条） |

**消息状态图标**：
- 🕐 `pending` — 等待发送（对方离线或队列中）
- ✓ `sent` — 已发出，未确认
- ✓✓ `delivered` — 对方已收到
- ⚠ `failed` — 发送失败，可重试

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

```dart
// Android 的 Wi-Fi 芯片默认过滤组播包以省电，必须显式获取 MulticastLock
val wifi = context.getSystemService(WIFI_SERVICE) as WifiManager
multicastLock = wifi.createMulticastLock("feijian").apply { setReferenceCounted(true) }
multicastLock.acquire()   // DiscoveryService 启动时
multicastLock.release()   // DiscoveryService 停止时
```

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
| **Android 组播锁未获取** | 收不到任何组播 | `CHANGE_WIFI_MULTICAST_STATE` + 运行时 acquire；同时发广播作为冗余通道 |
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
