# PVE8 + LSI 2208 阵列每日监控

这个程序面向 PVE8/Debian，默认检查 `/c0` 控制器，并按以下拓扑校验：

- 8 个物理盘；
- 4 个 SAS 盘、4 个 SATA 盘；
- 2 个 RAID10 虚拟盘；
- 控制器、CacheVault/BBU、ROC 温度、Enclosure、后台重建和 StorCLI 错误计数；
- 通过 MegaRAID 透传执行 `smartctl` 健康检查。

## 一键安装

PVE 主机已安装厂商提供的 `storcli`/`storcli64` 后，可以直接执行：

```bash
curl -fsSL https://raw.githubusercontent.com/maomomo-eth/pve-raid-monitor/main/install.sh | bash
```

安装器会补齐 Debian/PVE 官方源中的 `smartmontools`、`python3`，保留已有的 `/etc/pve-raid-monitor.conf`，安装 systemd 服务并启用每日定时器。`storcli` 属于阵列卡厂商工具，安装器不会从不明来源下载；如果找不到它，会停止安装并提示先安装。再次运行相同命令即可升级，包括邮件组件，已有的邮箱配置会保留。

如果不希望安装器自动调用 `apt-get`：

```bash
curl -fsSL https://raw.githubusercontent.com/maomomo-eth/pve-raid-monitor/main/install.sh | bash -s -- --no-apt
```

首次检查发现阵列异常不会撤销安装；安装器会保留服务和定时器，并提示查看报告。

如果出现 `Job for pve-raid-monitor.service failed`，表示首次检查服务返回了失败状态，不代表安装文件失败，也不能仅凭这句话判断硬盘损坏。安装器会读取监控进程的实际退出状态，并显示最近服务日志；具体警告和严重问题也会写入服务日志。

排查时执行：

```bash
systemctl show pve-raid-monitor.service -p Result -p ExecMainCode -p ExecMainStatus
journalctl -u pve-raid-monitor.service -n 100 --no-pager
```

当 `Result=exit-code` 且 `ExecMainCode=1`（进程正常退出）时，`ExecMainStatus=1` 表示警告，`ExecMainStatus=2` 表示严重问题或检查命令失败。超时、被信号终止或服务无法启动需要结合 `Result` 和日志单独排查。`systemctl start` 自身的退出码不能用来区分监控程序的警告和严重异常。

## 安装

在 PVE 主机上以 root 执行。先确认已经安装 `storcli` 和 `smartmontools`：

```bash
apt update
apt install -y smartmontools python3
```

`storcli` 通常是厂商提供的独立 `.deb` 或二进制文件，本程序会自动寻找 `storcli64` 或 `storcli`。

将本目录中的文件复制到系统位置：

```bash
install -D -m 0750 pve-raid-monitor.sh /usr/local/sbin/pve-raid-monitor
install -D -m 0644 mail_report.py /usr/local/lib/pve-raid-monitor/mail_report.py
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

程序会根据 StorCLI 的接口类型自动选择：SAS 盘使用 `megaraid,N`，SATA 盘使用 `sat+megaraid,N`；SATA 透传失败时再回退到 `megaraid,N`。

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

## 邮件告警与日志附件

编辑 `/etc/pve-raid-monitor.conf`，填写自己的收件地址：

```bash
ALERT_EMAIL='admin@example.com'
```

有严重问题或警告时，邮件包含：

- 🔴 / ⚠️ 等级图标、主机名、检查时间和严重/警告数量；
- 分开展示的异常清单；
- 阵列卡、ROC 温度、CacheVault、虚拟盘和物理盘数量概览；
- 每块盘的 DID、槽位、SAS/SATA 接口、阵列状态、SMART 结果及透传方式；
- 📎 本次完整的 `report-YYYYMMDD-HHMMSS.log` 附件，包含检查结论与原始命令输出。

邮件同时提供 HTML 彩色排版和纯文本版本，中文、emoji、附件名按 MIME 编码。不支持 HTML 的客户端仍能查看完整摘要。未读取、跳过的 SMART 显示为 `❔`；已通过总体健康检查但发现介质异常的磁盘仍显示异常。正文仅展示摘要，原始报告中的序列号等设备标识保留在附件中，不要把真实报告提交到公开仓库。

投递使用现有的本机 Postfix/sendmail，不再依赖 `mail` 命令，也不会修改 DNS、中转服务器或 SMTP 凭据。仅将收件地址改为 QQ 邮箱并不要求配置 QQ SMTP 中转；如现有 Postfix 已能发送到 QQ，可继续使用。若已有 SMTP 中转要求发件人和认证账号一致，可设置 `ALERT_FROM='你的发件邮箱'`，否则留空沿用 root 地址及 Postfix 的发件人改写。

修改配置后，下次执行会自动读取，无需重启定时器。当前存在异常时，运行一次即可测试摘要和附件：

```bash
systemctl start pve-raid-monitor.service
journalctl -u pve-raid-monitor.service -n 50 --no-pager
mailq
```

检查完全正常时默认不发邮件。检测到异常时 service 返回非零属于告警行为；邮件生成、缺失依赖、提交失败或超时会单独记录到服务日志和本地报告，不改变硬件检查等级。`告警邮件（含日志附件）已提交本机邮件队列` 仅表示 Postfix 已接收，最终送达还需查看收件箱和 Postfix 日志：

```bash
journalctl -b --since '10 minutes ago' --no-pager | grep -E 'postfix/(smtp|error)|status='
```

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

## 开发验证

下面的测试使用合成数据和模拟邮件程序，不访问真实硬盘，不向任何邮箱发信：

```bash
bash -n pve-raid-monitor.sh install.sh
bash tests/test-install.sh
uv run --no-project python -m unittest discover -s tests -p 'test_mail_report.py' -v
```

邮件的 HTML/纯文本组合及附件编码使用 [Python 标准库 email](https://docs.python.org/3/library/email.examples.html)，无需安装额外 Python 包。
