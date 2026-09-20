#!/usr/bin/env python3
"""把巡检摘要和原始日志组成 MIME 邮件，交由本机邮件服务投递。"""

import argparse
import html
import socket
import subprocess
import sys
from email.headerregistry import Address
from email.message import EmailMessage
from email.policy import SMTP
from email.utils import formatdate, make_msgid
from pathlib import Path


LEVELS = {
    "严重异常": ("🔴", "#b91c1c", "#fef2f2"),
    "警告": ("⚠️", "#92400e", "#fffbeb"),
    "正常": ("✅", "#166534", "#f0fdf4"),
}
SMART_ICONS = {"ok": "✅", "warning": "⚠️", "critical": "🔴", "unknown": "❔"}


def read_lines(path: Path) -> list[str]:
    """未执行的检查没有结果文件，应显示未读取而不是正常。"""
    if not path.exists():
        return []
    return [line for line in path.read_text(encoding="utf-8-sig").splitlines() if line.strip()]


def read_rows(path: Path, columns: int) -> list[list[str]]:
    rows = [line.split("\t", columns - 1) for line in read_lines(path)]
    if any(len(row) != columns for row in rows):
        raise ValueError(f"摘要文件格式错误：{path.name}")
    return rows


def disk_state(state: str) -> str:
    if state in ("Onln", "Online"):
        return f"✅ {state}"
    if state in ("Rbld", "Rebuild", "Cpybck", "Copyback"):
        return f"⚠️ {state}"
    if state == "未读取":
        return f"❔ {state}"
    return f"🔴 {state}"


def collect_summary(data_dir: Path, expected_pd: int):
    issues = read_lines(data_dir / "email-issues.txt")
    warnings = read_lines(data_dir / "email-warnings.txt")
    overview = read_rows(data_dir / "email-overview.txt", 2) or [
        ["阵列卡", "未读取"], ["ROC 温度", "未读取"], ["CacheVault", "未读取"]
    ]
    virtual = read_rows(data_dir / "virtual-drive-rows.txt", 3)
    for name, raid_type, state in virtual:
        icon = "✅" if state in ("Optl", "Optimal") else "🔴"
        overview.append([f"虚拟盘 {name}", f"{icon} {raid_type} · {state}"])
    if not virtual:
        overview.append(["虚拟盘", "未读取"])

    physical = read_rows(data_dir / "physical-drive-rows.txt", 5)
    smart = {
        device_id: (status, label, driver)
        for device_id, status, label, driver in read_rows(data_dir / "smart-result-rows.txt", 4)
    }
    disks = []
    for slot, state, interface, _model, device_id in physical:
        status, label, driver = smart.get(device_id, ("unknown", "未读取 / 已跳过", "-"))
        disks.append((device_id, slot, interface, disk_state(state),
                      f"{SMART_ICONS.get(status, '❔')} {label}", driver))
    mapped = {row[4] for row in physical}
    for device_id, (status, label, driver) in smart.items():
        if device_id not in mapped:
            disks.append((device_id, "未匹配槽位", "未知接口", "❔ 未读取",
                          f"{SMART_ICONS.get(status, '❔')} {label}", driver))

    online = sum(row[1] in ("Onln", "Online") for row in physical)
    sas = sum(row[2] == "SAS" for row in physical)
    sata = sum(row[2] == "SATA" for row in physical)
    overview.append(["物理盘", f"发现 {len(physical)} / 预期 {expected_pd}；在线 {online}；SAS {sas} / SATA {sata}"])
    passed = sum(row[0] == "ok" for row in smart.values())
    attention = sum(row[0] in ("warning", "critical") for row in smart.values())
    unread = max(expected_pd, len(disks)) - passed - attention
    overview.append(["SMART", f"通过 {passed}；需关注 {attention}；未读取 {unread}"])
    return issues, warnings, overview, disks


def render_bodies(args, issues, warnings, overview, disks) -> tuple[str, str]:
    icon, color, background = LEVELS[args.level]
    title = f"{icon} PVE 存储巡检 · {args.level}"
    counts = f"严重问题 {len(issues)} 项 · 警告 {len(warnings)} 项"
    footer = "SMART 为本次读取结果，不代表已完成全盘扫描。完整日志含设备标识，请仅供管理员查看。"
    plain = [title, f"主机：{args.host}    控制器：/c{args.controller}",
             f"检查时间：{args.time}", counts, ""]
    for heading, items in (("🔴 严重问题", issues), ("⚠️ 警告", warnings)):
        if items:
            plain += [heading] + [f"• {item}" for item in items] + [""]
    plain += ["🧩 硬件概览"] + [f"{label}：{value}" for label, value in overview]
    plain += ["", "💽 物理盘与 SMART"]
    for device_id, slot, interface, state, smart_label, driver in disks:
        plain.append(f"DID {device_id} · {slot} · {interface} | {state} | {smart_label} | {driver}")
    if not disks:
        plain.append("❔ 没有可用的逐盘数据，请查看告警和日志附件。")
    plain += ["", f"📎 完整日志附件：{args.report.name}", f"服务器路径：{args.report}", "", footer]

    escape = html.escape
    panels = []
    for heading, items, panel_color, panel_bg in (
        ("🔴 严重问题", issues, "#b91c1c", "#fef2f2"),
        ("⚠️ 警告", warnings, "#92400e", "#fffbeb"),
    ):
        if items:
            items_html = "".join(f'<li style="margin:8px 0;overflow-wrap:anywhere">{escape(item)}</li>' for item in items)
            panels.append(
                f'<div style="padding:16px 20px;margin:20px 0;background:{panel_bg};border-left:4px solid {panel_color}">'
                f'<h2 style="font-size:17px;color:{panel_color};margin:0">{heading} · {len(items)} 项</h2>'
                f'<ul style="padding-left:22px;margin:8px 0 0">{items_html}</ul></div>'
            )

    cell = 'style="padding:10px 12px;border-bottom:1px solid #e5e7eb;text-align:left;vertical-align:top;overflow-wrap:anywhere"'
    overview_html = "".join(
        f'<tr><th {cell} scope="row" width="25%"><span style="white-space:nowrap">{escape(label)}</span></th><td {cell}>{escape(value)}</td></tr>'
        for label, value in overview
    )
    disks_html = "".join(
        f'<tr><td {cell}><b>DID {escape(device_id)}</b><br>{escape(slot)} · {escape(interface)}</td>'
        f'<td {cell}>{escape(state)}</td><td {cell}>{escape(smart_label)}'
        f'<br><span style="color:#64748b;font-size:12px">{escape(driver)}</span></td></tr>'
        for device_id, slot, interface, state, smart_label, driver in disks
    ) or f'<tr><td {cell} colspan="3">❔ 没有可用的逐盘数据，请查看告警和日志附件。</td></tr>'

    rich = f"""<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:12px;background:#f1f5f9;color:#1e293b;font-family:Arial,'Microsoft YaHei',sans-serif;font-size:14px;line-height:1.6">
<div style="max-width:760px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;border-radius:12px;overflow:hidden">
<div style="padding:24px;background:{background};border-top:5px solid {color}">
<h1 style="font-size:23px;line-height:1.4;color:{color};margin:0 0 12px">{title}</h1>
<div><b>{escape(args.host)}</b> · 控制器 /c{escape(args.controller)}</div>
<div style="color:#64748b">{escape(args.time)}</div>
<div style="margin-top:14px;font-weight:bold">{counts}</div></div>
<div style="padding:4px 20px 24px">
{''.join(panels)}
<h2 style="font-size:17px;margin:24px 0 10px">🧩 硬件概览</h2>
<table width="100%" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse">{overview_html}</table>
<h2 style="font-size:17px;margin:24px 0 10px">💽 物理盘与 SMART</h2>
<table width="100%" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;table-layout:fixed">
<thead style="background:#f8fafc"><tr><th {cell} scope="col">物理盘</th><th {cell} scope="col">阵列状态</th><th {cell} scope="col">SMART</th></tr></thead>
<tbody>{disks_html}</tbody></table>
<div style="margin-top:24px;padding:16px;background:#f8fafc;border:1px solid #e2e8f0;overflow-wrap:anywhere">
<b>📎 完整日志已附上</b><br>{escape(args.report.name)}<br>
<span style="color:#64748b;font-size:12px">服务器路径：{escape(str(args.report))}</span></div>
<p style="font-size:12px;color:#64748b;margin:16px 0 0">{footer}</p>
</div></div></body></html>
"""
    return "\n".join(plain) + "\n", rich


def build_message(args) -> EmailMessage:
    for value in (args.recipient, args.sender, args.host):
        if "\r" in value or "\n" in value:
            raise ValueError("邮件地址或主机名不能包含换行")
    issues, warnings, overview, disks = collect_summary(args.data_dir, args.expected_pd)
    plain, rich = render_bodies(args, issues, warnings, overview, disks)
    message = EmailMessage(policy=SMTP)
    message["To"] = args.recipient
    if message["To"].defects or not message["To"].addresses:
        raise ValueError("ALERT_EMAIL 格式不正确")
    if any(not addr.username or not addr.domain for addr in message["To"].addresses):
        raise ValueError("ALERT_EMAIL 必须填写完整邮箱地址，多地址用英文逗号分隔")
    # 未配置发件人时交由 Postfix 按本机 origin 补全 root 地址，兼容现有发件人改写。
    message["From"] = args.sender or Address("PVE 阵列监控", username="root")
    if message["From"].defects or len(message["From"].addresses) != 1:
        raise ValueError("ALERT_FROM 格式不正确")
    icon = LEVELS[args.level][0]
    message["Subject"] = f"{icon} [PVE][{args.level}] {args.host} · 严重 {len(issues)} / 警告 {len(warnings)}"
    message["Date"] = formatdate(localtime=True)
    message["Message-ID"] = make_msgid(domain=socket.getfqdn())
    message.set_content(plain, charset="utf-8", cte="quoted-printable")
    message.add_alternative(rich, subtype="html", charset="utf-8", cte="quoted-printable")
    # 以字节读取和 Base64 编码，保留日志原始内容与换行，避免附件截断或中文乱码。
    message.add_attachment(args.report.read_bytes(), maintype="text", subtype="plain",
                           params={"charset": "utf-8"}, filename=args.report.name, cte="base64")
    return message


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True, help="本次检查的临时摘要目录")
    parser.add_argument("--report", type=Path, required=True, help="完整日志附件")
    parser.add_argument("--host", required=True, help="主机名")
    parser.add_argument("--time", required=True, help="检查时间")
    parser.add_argument("--level", choices=LEVELS, required=True, help="告警等级")
    parser.add_argument("--controller", required=True, help="控制器编号")
    parser.add_argument("--expected-pd", type=int, required=True, help="预期物理盘数量")
    parser.add_argument("--recipient", required=True, help="收件人，多个地址以英文逗号分隔")
    parser.add_argument("--sender", default="", help="可选发件人，默认由本机 Postfix 补全")
    parser.add_argument("--sendmail", default="/usr/sbin/sendmail", help="本机 sendmail 路径")
    parser.add_argument("--timeout", type=int, default=30, help="提交邮件超时秒数")
    args = parser.parse_args()
    try:
        if args.timeout <= 0:
            raise ValueError("EMAIL_TIMEOUT 必须大于 0")
        message = build_message(args)
        # -oi 避免正文里的单独句点结束输入，-t 从已验证的邮件头提取收件人。
        command = [args.sendmail, "-oi", "-t"]
        if args.sender:
            command.extend(["-f", message["From"].addresses[0].addr_spec])
        subprocess.run(command, input=message.as_bytes(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       timeout=args.timeout, check=True)
    except subprocess.TimeoutExpired:
        print("提交邮件超时，请检查本机 Postfix 状态和队列", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode("utf-8", errors="replace").strip()
        print(f"sendmail 返回 {exc.returncode}：{detail}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"无法生成或提交邮件：{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
