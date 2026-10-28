# Tools

几个常用 Shell 工具脚本。

## list_xiaomi_devices.sh

通过 SSH 使用 Home Assistant 已有的小米授权查询 **小米 Home（`xiaomi_home`）集成**的全部已注册设备。按 **小米账号 → 家庭** 分组，显示 **序号、设备名称、房间、设备类型、MAC、IP**。默认输出带统计和边框的对齐表格，终端自动着色；各家庭内按 IPv4 数值升序排列，没有 IP 的设备放在该组末尾，缺失字段为空。支持 `--format tsv` 导出。

### 使用

你的服务器支持 SSH 免密，可以直接运行：

```bash
./list_xiaomi_devices.sh --host 10.68.40.254 --user root
```

密码为可选项。不带参数运行时，依次询问地址、用户名和密码；密码隐藏输入，直接回车使用 SSH 密钥/agent。通过命令行指定地址和用户名时，省略密码或传入空字符串仍使用免密认证，不额外询问密码。这里的用户名和密码是 **SSH 登录凭据**，地址是 SSH 主机地址，不是 HA 网页 URL。

```bash
# 依次输入服务器地址、用户名、密码；密码可直接回车留空
./list_xiaomi_devices.sh

# 隐藏输入可选密码，直接回车使用免密认证
./list_xiaomi_devices.sh --host 10.68.40.254 --user root --ask-password

# 命令行指定密码（可能被 shell 历史或进程参数记录）
./list_xiaomi_devices.sh --host 10.68.40.254 --user root --password 'SSH密码'

# 自定义 SSH 端口、密钥和远端 HA 配置目录
./list_xiaomi_devices.sh --host 10.68.40.254 --user root \
  --port 2222 --identity ~/.ssh/id_ed25519 --config-dir /homeassistant

# 导出 TSV；可用表格软件导入
./list_xiaomi_devices.sh --host 10.68.40.254 --user root --format tsv > xiaomi_devices.tsv

# 禁用终端颜色
./list_xiaomi_devices.sh --host 10.68.40.254 --user root --no-color

# 网络不可用时只查缓存（缓存中的 IP/MAC 可能缺失）
./list_xiaomi_devices.sh --host 10.68.40.254 --user root --cached-only
```

默认表格根据终端宽度对齐中文字段，过长内容以 `…` 截断；TSV 导出保留完整字段。表格至少需要 80 列宽度，建议使用较宽终端查看名称和房间。设置 `NO_COLOR` 也可禁用颜色，重定向时不输出颜色控制码。

分组标题示例：

```text
账号：遥控器  [ID: 84368705 · 地区: cn]
  家庭：68  [ID: 478001843371]  ·  81 台
  序号  设备名称       房间        设备类型     MAC 地址           IP 地址
```

TSV 每行包含以下十列，以便多个账号或同名家庭导出后仍能区分：

```text
账号  账号ID  地区  家庭  家庭ID  名称  房间  设备类型  MAC  IP
```

共享设备在关联的各账号分组中分别列出，统计显示“设备记录”数量；每个家庭组内序号从 1 开始。

实际查询统计：**81 台设备，46 台有 IP、81 台有 MAC，35 台蓝牙/BLE Mesh 的 IP 留空**。

### 依赖与兼容性

- 本机：Bash 3.2+、OpenSSH 客户端、jq 1.5+；支持 macOS 和主流 Linux。macOS 可用 `brew install jq`，Debian/Ubuntu 可用 `sudo apt-get install jq openssh-client`，Fedora 可用 `sudo dnf install jq openssh-clients`。
- 仅使用非空密码时额外安装 `sshpass`：macOS 可用 `brew install sshpass`（[Homebrew 安装说明](https://formulae.brew.sh/formula/sshpass)），Debian/Ubuntu 可用 `sudo apt-get install sshpass`。
- 远端 HA 的 SSH 环境：`sh`、`jq`、`curl`、`head`、`wc`、`tail`、`od`、`tr`、`sha256sum`（GNU 或 BusyBox），以及可选的 `ip`。SSH 用户必须能读取 HA 的 `.storage` 目录。`--cached-only` 不需要 curl。
- HA 服务器需要能连接小米云端，且小米 Home 集成已有有效授权。无需另外输入小米账号密码；授权只在 HA 服务器内使用，不传回本机、不写入额外文件。
- 首次连接先执行 `ssh 用户名@服务器地址` 确认服务器指纹；脚本不会关闭主机身份校验。SSH 配置文件中的密钥、跳板和默认端口继续生效。
- HA Container 使用 `--config-dir` 指向 SSH 所在主机可见的配置卷目录；脚本不自动进入 Docker 容器。

### 数据含义与限制

- 名称优先采用 HA 自定义名称，范围以 HA 注册表为准，包含禁用设备，不包含仅存在于缓存中的旧设备。
- 账号由 HA 小米 Home 配置条目关联，按账号 ID 和地区区分，显示昵称（无昵称时用集成标题）；家庭按米家家庭 ID 区分，同名账号或同名家庭不会合并。已移除账号的残留缓存忽略。
- 房间来自小米 Home 缓存中的米家房间名称，不读取 HA 自行设置的区域，也不从设备名称猜测；可能随集成缓存更新而变化。子设备缺少家庭/房间时继承父设备的位置。
- 设备类型是产品类别，如门锁、空气净化器、温湿度计；从云端 `spec_type` 或缓存 `urn` 获取。常见类别映射为中文，未收录的类别保留原始名称，缺失时留空。
- 默认直接读取小米接口返回的 `localip` 和 `mac`，兼容 `local_ip` 字段。云端 IP 是最近记录的地址，可能过期；仅输出有效 IPv4，不主动扫描网络。
- 蓝牙和 BLE Mesh 没有独立 IP，其 IP 列始终留空，MAC 正常显示。云端有时给蓝牙设备附带上报出口 IP，脚本会过滤它。
- 云端没有返回某台设备时回退其缓存。MAC 优先取云端（缓存模式取缓存），再取注册表或已有邻居表；不会将 Wi-Fi 接入点 BSSID 当作设备 MAC。
- 每个账号独立查询、关联和显示自己的 IP/MAC，不混用其他账号的数据；同一账号内发生字段冲突时留空。没有缓存的已注册设备仍保留，无法确定归属的显示在“未识别账号”或“未分配家庭”组。
- 2026-10-08 已在 `10.68.40.254` 实跑：46 台 Wi-Fi 设备全部获得 IP/MAC，另有 33 台蓝牙和 2 台 BLE Mesh 全部获得 MAC。之前缓存全空是因为该集成未保存 MAC，且将接口 `localip` 错读为 `local_ip`。
- 若云端查询失败，脚本会报错，避免把失败误当成空数据。401/授权过期时请在 HA 中重新登录小米 Home；网络故障可显式使用 `--cached-only`。
- 自动探测 `/homeassistant`、`/config` 等目录；找不到时用 `--config-dir` 指定。缓存校验失败可能是 HA 正在更新文件，稍后重试。
- 需要可读的 `.storage/core.device_registry` 和 `.storage/core.config_entries` 来确定设备与账号的关联。
- 返回码 `0` 表示查询成功（包括零设备或部分字段为空）；`1` 表示参数、依赖、SSH、云端或数据解析失败。任一账号云端查询失败时整次查询报错，不输出部分结果。TSV 中的制表符或换行按 jq 的规则转义，表格中的控制字符替换为空格。

## 依赖

```bash
sudo apt-get update
sudo apt-get install curl jq git
```

## url_speed_test.sh

测试一个 URL 多次请求的耗时和速度。

```bash
./url_speed_test.sh <URL> <次数>
```

示例：

```bash
./url_speed_test.sh "https://example.com" 5
```

会输出每次请求的 HTTP 状态、DNS/TCP/TLS/TTFB/总耗时、下载/上传速度，以及成功请求的平均值。

## git-pull.sh

只下载远程 Git 仓库里的某个子目录到本地。

```bash
./git-pull.sh <git地址> <分支名> <项目子目录> [本地目录]
```

示例：

```bash
./git-pull.sh https://github.com/user/repo.git main scripts/tools ./tools
```

说明：

- `[本地目录]` 可省略，默认当前目录。
- `<项目子目录>` 必须是仓库内相对路径，不能是绝对路径，也不能包含 `..`。

## sync_unifi_names.sh

把 RouterOS DHCP 静态租约的 `comment` 同步到 UniFi Cloud Key 客户端名称。

规则：

- 只读取 RouterOS 中 `dynamic=false` 且有 `comment` 的 DHCP lease。
- 只更新 UniFi 已存在/已记录过的客户端，不创建新客户端。
- 不修改 RouterOS，不同步 IP，不保存密码。

### RouterOS 前提

RouterOS 需支持 REST API，通常要求 RouterOS v7，并启用 `www` 或 `www-ssl` 服务，例如：

```routeros
/ip service enable www-ssl
```

### 交互运行

```bash
./sync_unifi_names.sh
```

脚本会提示输入 RouterOS / UniFi 地址、账号、密码和 site，保存非密码配置，预览同步计划，最后询问是否执行。

默认配置文件：

```text
./unifi_routeros_sync.conf
```

配置示例：

```text
RouterOSIP 192.168.88.1
RouterOSPort 443
RouterOSScheme https
RouterOSUser admin
RouterOSPassword 路由器密码
CloudKeyIP 192.168.88.2
CloudKeyPort 443
UniFiUser admin
UniFiPassword CloudKey密码
UniFiSite default
UniFiVerifySSL false
```

密码字段是可选的：

- 写了 `RouterOSPassword` 和 `UniFiPassword` 后，可只用 `--config` 静默运行。
- 不写密码时，交互模式会现场输入；静默模式可用命令行参数传入。
- 配置文件建议设置为仅自己可读：`chmod 600 unifi_routeros_sync.conf`。

### 静默运行 / 定时任务

方式一：密码写在配置文件里。

```bash
./sync_unifi_names.sh --config /opt/routeros-unifi/unifi_routeros_sync.conf
```

方式二：密码不写入配置文件，运行时通过参数传入。

```bash
./sync_unifi_names.sh \
  --config /opt/routeros-unifi/unifi_routeros_sync.conf \
  --routeros-password 'RouterOS密码' \
  --unifi-password 'UniFi密码'
```

### 返回码

- `0`：同步完成，没有客户端更新失败。
- `1`：依赖缺失、配置错误、登录失败或读取 API 失败。
- `2`：部分 UniFi 客户端更新失败。
