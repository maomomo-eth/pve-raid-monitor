# PVE8 + LSI 2208 阵列每日监控

这个程序面向 PVE8/Debian，默认检查 `/c0` 控制器，并按以下拓扑校验：

- 8 个物理盘；
- 4 个 SAS 盘、4 个 SATA 盘；
- 2 个 RAID10 虚拟盘；
- 控制器、CacheVault/BBU、ROC 温度、Enclosure、后台重建和 StorCLI 错误计数；
- 通过 MegaRAID 透传执行 `smartctl` 健康检查。

## 安装

在 PVE 主机上以 root 执行。先确认已经安装 `storcli` 和 `smartmontools`：

```bash
apt update
apt install -y smartmontools
```

`storcli` 通常是厂商提供的独立 `.deb` 或二进制文件，本程序会自动寻找 `storcli64` 或 `storcli`。

将本目录中的文件复制到系统位置：

```bash
install -D -m 0750 pve-raid-monitor.sh /usr/local/sbin/pve-raid-monitor
install -D -m 0640 pve-raid-monitor.conf.example /etc/pve-raid-monitor.conf
install -D -m 0644 pve-raid-monitor.service /etc/systemd/system/pve-raid-monitor.service
install -D -m 0644 pve-raid-monitor.timer /etc/systemd/system/pve-raid-monitor.timer
```

建议先确认系统虚拟盘设备名称：

```bash
lsblk -o NAME,TYPE,SIZE,MODEL
```

如果 `SMART_BASE_DEVICE=auto` 探测不到设备，把 `/etc/pve-raid-monitor.conf` 中的值改成阵列虚拟盘对应设备，通常是：

```bash
SMART_BASE_DEVICE=/dev/sda
```

可以先手动验证 MegaRAID SMART 透传。下面的 `0` 是 MegaRAID 透传编号，不是必然对应 StorCLI 的 `252:0` 槽位：

```bash
smartctl -i -d megaraid,0 /dev/sda
smartctl -a -d sat+megaraid,0 /dev/sda
```

如果 SATA 盘不支持 `sat+megaraid`，程序会自动回退到 `megaraid,N`；SAS 盘通常直接使用 `megaraid,N`。

然后手动运行一次：

```bash
/usr/local/sbin/pve-raid-monitor
```

## 启用每日检查

```bash
systemctl daemon-reload
systemctl enable --now pve-raid-monitor.timer
systemctl start pve-raid-monitor.service
```

查看定时器和最近报告：

```bash
systemctl status pve-raid-monitor.timer
systemctl status pve-raid-monitor.service
journalctl -u pve-raid-monitor.service -n 100 --no-pager
ls -lt /var/log/pve-raid-monitor/
```

默认每天 03:15 执行，并随机延后最多 5 分钟；服务器关机错过后，`Persistent=true` 会在下次开机补执行。

## 告警判定

以下情况会返回退出码 2，并在 systemd 日志中标记为严重异常：

- 控制器不是 `Optimal/OK`；
- CacheVault 为 `Dgd`、`Failed`、`Missing` 或 `Needs Attention`；
- 虚拟盘不是预期的 RAID10/`Optl`；
- 物理盘不是 `Onln`；
- 物理盘数量或 SAS/SATA 数量不符；
- StorCLI 的媒体错误、其他错误、预测失败或 SMART 告警计数非零；
- smartctl 明确报告 SMART `FAILED/BAD`；
- 控制器存在不可纠正内存错误或要求重启。

当前你贴出的状态中，RAID10 虚拟盘和 8 个物理盘都是正常状态，但 `Controller Status = Needs Attention`、`Cachevault_Info = Dgd (Needs Attention)` 会被程序明确报为严重异常，需要优先检查/更换 CVPM02 电池/CacheVault 模块或确认其连接、寿命和固件状态。

建议先执行以下只读命令查看 CacheVault 和历史事件：

```bash
storcli /c0/cv show all
storcli /c0/bbu show all
storcli /c0 show events
```

## 注意

程序只读检查，不会执行 `force online`、`rebuild`、`clear foreign`、`initialize` 或其他可能改变阵列状态的命令。`smartctl` 的物理盘编号 `0-7` 是 MegaRAID 透传编号，不一定等于 StorCLI 的 `252:0-252:7` 槽位；报告中应同时核对型号、序列号和槽位后再处理故障盘。
