# 技术架构

本仓库收集独立 Bash 命令行工具，没有常驻服务或统一构建过程。

## 现有工具

- `git-pull.sh`：从 Git 仓库下载指定目录。
- `url_speed_test.sh`：通过 curl 多次测量 URL 请求耗时和速度。
- `sync_unifi_names.sh`：读取 RouterOS DHCP 静态租约，向 UniFi 同步客户端名称。
- `list_xiaomi_devices.sh`：通过 SSH 只读查询 Home Assistant 中 `xiaomi_home` 集成的设备。

## 小米 Home 设备查询

运行端兼容 Bash 3.2+，依赖 OpenSSH 和 jq 1.5+；密码认证可选依赖 sshpass。
远端为 Linux/POSIX shell，依赖 jq、curl 和常见 GNU/BusyBox 工具，`ip` 为可选依赖。
脚本通过标准输入发送嵌入的 POSIX shell，远端不写文件、不扫描网络、不调用 HA 控制接口。默认使用 HA 中小米 Home 已有授权，只读查询小米设备列表；`--cached-only` 禁用云端查询。

数据流程：

1. 无参数启动时依次询问地址、SSH 用户名和密码，密码隐藏输入且可回车留空。通过参数指定地址和用户名时，仅 `--ask-password` 主动询问密码；省略密码或密码为空时设置 `BatchMode=yes`，沿用 SSH 密钥/agent。非空密码通过文件描述符交给 sshpass。主机指纹遵循 OpenSSH 配置。
2. 探测 HA 配置路径或使用 `--config-dir`。注册表 `.storage/core.device_registry` 是设备范围的唯一依据，匹配 `xiaomi_home` 标识，包含禁用设备。兼容新版单值 `config_entry_id`/`primary_config_entry` 和旧版 `config_entries` 数组。读取 `.storage/core.config_entries` 中 `xiaomi_home` 条目的 ID、UID、地区、昵称、标题，仅将这些投影字段传回本机；两份注册表均为必需。
3. 读取 `.storage/xiaomi_home/miot_devices/<uid>_<region>.dict`。该文件为 JSON 加 32 字节 SHA-256 尾部摘要，验证后解析。校验失败中止，避免默默忽略设备信息。
4. 按 UID 与地区归并同账号配置条目，匹配 `<uid>_<region>.dict`，忽略不属于现有集成账号的残留缓存。递归展开 `sub_devices`，缺失家庭/房间时继承父设备的位置。用地区和 DID 生成标识（如 `cn_blt_3_xxx`、`cn_123_s2`），与该账号配置条目关联的注册设备匹配。仅请求对应账号的已注册 DID，每批最多 150 个。小米 DID 为 ASCII，转换使用小写和下划线规范化。
5. 校验对应 `.storage/xiaomi_home/miot_config/<uid>_<region>.dict`，取 `auth_info.access_token`。远端 curl 通过标准输入配置读取授权，避免令牌出现在进程参数中；禁用 curlrc、不跟随重定向。调用 `https://[地区.]ha.api.io.mi.com/app/v2/home/device_list_page`，中国区无地区前缀。API 请求字段包括 `dids`、`limit`、`get_split_device`、`get_third_device`；按 `has_more` 和 `next_start_did` 分页，检测重复游标。
6. 云端原始 IP 字段为 `localip`，兼容 `local_ip`，MAC 字段为 `mac`。已验证的集成版本错误读取 `local_ip` 且未保存 MAC，所以仅查缓存不足。每批缓存与云端数据带 `account_key`；远端只传回设备必要字段、家庭/房间、类别 URN 及邻居记录，不传授权或设备 token，也不读取 HA auth。
7. 本机按 `account_key + identifier` 建立缓存和云端索引，不跨账号合并。同一注册设备属于多个账号时逐账号输出。名称优先级为 HA 自定义名称、注册表名称、匹配数据中的名称、注册表 ID。某设备有本账号云端记录时优先使用它，未返回时回退本账号缓存。MAC 再回退注册表和已有邻居表；同一账号内字段冲突时留空。IP 仅接受有效 IPv4，`0.0.0.0` 视为缺失。`pid=6`（BLE）、`pid=16`（BLE Mesh）强制 IP 留空：原始响应有时包含上报出口 IP，不代表设备独立 IP。BSSID 不作为设备 MAC。
8. 家庭名称、ID、房间取关联缓存。分组键为账号 UID+地区、家庭 ID；无家庭 ID 时回退家庭名，均缺失时归入未分配组。无可识别账号的注册设备保留在独立未知组，不借用其他账号的数据。每个账号/家庭内按注册设备 ID 去重，按 IPv4 四段数值升序、名称次序排列，缺失 IP 放该组末尾。
9. 设备类型优先取云端 `spec_type`，回退缓存 `urn`，从 `urn:miot-spec-v2:device:<类别>:...` 提取类别。常见类别中文映射内置于 jq 的 `category` 函数，未知类别原样输出，缺失留空，不根据型号或名称猜测。
10. 默认逐账号、逐家庭打印带序号、统计、Unicode 边框的表格，列为名称、房间、设备类型、MAC、IP；各家庭序号独立从 1 开始。TTY 自动着色，`--no-color`/`NO_COLOR` 禁色。按显示列宽对齐常见中文和全角字符，根据终端宽度截断长字段，最小表格宽度约 80 列；复杂 emoji 的宽度可能因终端不同而有差异。`--format tsv` 导出十列：账号、账号ID、地区、家庭、家庭ID、名称、房间、设备类型、MAC、IP，统计写到标准错误。统计按设备记录计数，共享设备可能计入多个账号。

远端输出先写入本机权限受限的临时目录，整个采集和解析成功后才输出表格，退出时清理。
自动探测多个路径时采用第一个可读注册表；多实例或容器卷映射应显式指定路径。
邻居表只反映当前缓存，无法证明 IP 仍归属于原设备；HA 插件容器通常看不到宿主机 LAN 邻居。
缓存读取期间被 HA 更新可能触发校验失败，重跑即可。缺失设备缓存允许降级到注册表并提示，损坏缓存则报错。云端模式下授权缺失、请求失败或分页异常直接报错，不静默吞掉失败；用户可显式选择 `--cached-only`。脚本不刷新或写回小米授权，授权过期应在 HA 中重新登录。
云端 IP 是小米最近记录的地址，脚本不保证设备当前在线或 DHCP 地址未变。

## 验证

`bash -n list_xiaomi_devices.sh` 检查语法。
`python3 -B -m unittest discover -s tests -v` 使用模拟 SSH 执行真实远端采集片段，模拟 curl 响应，验证排序、范围、空值、子设备、密码传递、错误退出、路径引用、云端字段、蓝牙 IP 过滤、分页分批、区域端点、授权错误及中文表格对齐。另覆盖新版/旧版配置关联、多账号共享设备、同名家庭分组、残留账号缓存排除、房间继承和类别回退。Python 仅用于测试，不是脚本运行依赖。
真实服务器验证和未完成的平台验证记录在 TODO.md。

格式依据：[官方缓存实现](https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/miot_storage.py)、[官方设备字段](https://github.com/XiaoMi/ha_xiaomi_home/blob/main/custom_components/xiaomi_home/miot/miot_cloud.py)。
