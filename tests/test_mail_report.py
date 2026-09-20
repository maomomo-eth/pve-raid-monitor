"""验证真实 MIME 解析和模拟巡检到投递流程，不访问硬盘或发送邮件。"""

import argparse
import importlib.util
import os
import subprocess
import tempfile
import unittest
from email import policy
from email.parser import BytesParser
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("mail_report", PROJECT / "mail_report.py")
MAIL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MAIL)


class MailTests(unittest.TestCase):
    def setUp(self):
        artifacts = PROJECT / ".test-artifacts"
        artifacts.mkdir(exist_ok=True)
        self.workspace = tempfile.TemporaryDirectory(prefix="mail-", dir=artifacts)
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.data = self.root / "data"
        self.data.mkdir()
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.report = self.logs / "report-20300101-031500.log"
        self.report.write_text("合成测试报告，不含真实设备信息。\n", encoding="utf-8")
        self.args = argparse.Namespace(
            data_dir=self.data, report=self.report, host="pve-demo", time="2030-01-01 03:15:00 +0800",
            level="严重异常", controller="0", expected_pd=8,
            recipient="admin@example.com, second@example.org", sender="",
        )

    def write_data(self, name, value):
        (self.data / name).write_text(value, encoding="utf-8", newline="\n")

    def parse(self, payload):
        message = BytesParser(policy=policy.default).parsebytes(payload)
        self.assertFalse(message.defects)
        for part in message.walk():
            self.assertFalse(part.defects)
        return message

    def test_mime_utf8_and_exact_attachment(self):
        self.write_data("email-issues.txt", "控制器状态异常：Needs Attention\n")
        self.write_data("email-warnings.txt", "温度需关注\n")
        self.write_data("physical-drive-rows.txt", "252:4\tOnln\tSATA\tDEMO\t4\n")
        self.write_data("smart-result-rows.txt", "4\tok\t总体健康通过\tsat+megaraid\n")
        content = ("测试日志\r\n.\r\n" * 4000).encode("utf-8") + "末尾没有换行 ✅".encode("utf-8")
        self.report.write_bytes(content)
        message = self.parse(MAIL.build_message(self.args).as_bytes())
        self.assertEqual(message.get_content_type(), "multipart/mixed")
        self.assertEqual(message.get_payload()[0].get_content_type(), "multipart/alternative")
        self.assertIn("🔴 [PVE][严重异常]", str(message["Subject"]))
        self.assertIn("严重 1 / 警告 1", str(message["Subject"]))
        self.assertEqual(len(message["To"].addresses), 2)
        self.assertIsNotNone(message["Date"])
        self.assertIsNotNone(message["Message-ID"])
        for kind in ("plain", "html"):
            body = message.get_body(preferencelist=(kind,)).get_content()
            self.assertIn("控制器状态异常", body)
            self.assertIn("📎", body)
            self.assertIn("252:4", body)
            self.assertIn("sat+megaraid", body)
        attachments = list(message.iter_attachments())
        self.assertEqual(len(attachments), 1)
        self.assertEqual(attachments[0].get_filename(), self.report.name)
        self.assertEqual(attachments[0].get_payload(decode=True), content)

    def test_html_escaping_and_no_header_injection(self):
        self.args.host = '<demo & "host">'
        self.write_data("email-issues.txt", "异常 <script>alert('test')</script>\n")
        message = MAIL.build_message(self.args)
        body = message.get_body(preferencelist=("html",)).get_content()
        self.assertNotIn("<script>", body)
        self.assertIn("&lt;script&gt;", body)
        self.assertIn("&lt;demo &amp; &quot;host&quot;&gt;", body)
        self.args.recipient = "admin@example.com\nBcc: second@example.org"
        with self.assertRaises(ValueError):
            MAIL.build_message(self.args)

    def test_missing_metrics_stay_unknown(self):
        self.write_data("physical-drive-rows.txt", "252:0\tOnln\tSAS\tDEMO\t0\n")
        plain = MAIL.build_message(self.args).get_body(preferencelist=("plain",)).get_content()
        self.assertIn("SMART：通过 0；需关注 0；未读取 8", plain)
        self.assertIn("未读取 / 已跳过", plain)
        self.assertIn("CacheVault：未读取", plain)

    def test_missing_attachment_fails(self):
        self.args.report = self.root / "does-not-exist.log"
        with self.assertRaises(FileNotFoundError):
            MAIL.build_message(self.args)

    def run_monitor(self, healthy=False, **overrides):
        # 仅绕过权限门槛，其余运行真实 main；所有命令均指向本地替身。
        script = r'''
set -Eeuo pipefail
CONFIG_FILE=/dev/null
source "$1/pve-raid-monitor.sh"
require_root() { return 0; }
log_line() { printf '[%s] %s\n' "$1" "$2"; }
TMP_DIR="$TEST_DATA"
TIMEOUT_BIN="$(command -v timeout)"
if main; then exit 0; else exit "$?"; fi
'''
        env = os.environ.copy()
        env.update({
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8", "LOG_DIR": str(self.logs), "TEST_DATA": str(self.data),
            "ALERT_EMAIL": "admin@example.com", "ALERT_FROM": "",
            "STORCLI_BIN": str(PROJECT / "tests/fake-storcli"),
            "SMARTCTL_BIN": str(PROJECT / "tests/fake-smartctl"), "SMART_BASE_DEVICE": "/dev/mock",
            "SENDMAIL_BIN": str(PROJECT / "tests/fake-sendmail"),
            "FAKE_EMAIL_PATH": str(self.root / "captured.eml"),
        })
        if healthy:
            fixture = self.root / "fixtures"
            fixture.mkdir()
            for source in (PROJECT / "tests/fixtures").iterdir():
                content = source.read_text(encoding="utf-8")
                content = content.replace("Controller Status = Needs Attention", "Controller Status = Optimal")
                content = content.replace("CVPM02 Dgd (Needs Attention) 35C", "CVPM02 Optimal 35C")
                (fixture / source.name).write_text(content, encoding="utf-8")
            env["FAKE_STORCLI_FIXTURE_DIR"] = str(fixture)
        env.update(overrides)
        return subprocess.run(["bash", "-c", script, "fixture", str(PROJECT)], env=env,
                              capture_output=True, text=True, encoding="utf-8", timeout=25)

    def captured_message(self):
        return self.parse((self.root / "captured.eml").read_bytes())

    def test_critical_alert_end_to_end(self):
        result = self.run_monitor()
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("已提交本机邮件队列", result.stdout)
        message = self.captured_message()
        self.assertIn("严重 2 / 警告 0", str(message["Subject"]))
        plain = message.get_body(preferencelist=("plain",)).get_content()
        self.assertIn("SMART：通过 8；需关注 0；未读取 0", plain)
        self.assertIn("发现 8 / 预期 8；在线 8；SAS 4 / SATA 4", plain)
        self.assertIn("DID 0 · 252:0 · SAS", plain)
        self.assertIn("DID 7 · 252:7 · SATA", plain)
        report = next(path for path in self.logs.glob("report-*.log") if path != self.report)
        attachment = next(message.iter_attachments()).get_payload(decode=True)
        self.assertEqual(attachment, report.read_bytes())
        self.assertIn("===== 检查结论 =====", attachment.decode("utf-8"))
        self.assertIn("megaraid\\,0", attachment.decode("utf-8"))
        self.assertIn("sat+megaraid\\,7", attachment.decode("utf-8"))

    def test_warning_mail_and_complete_attachment(self):
        result = self.run_monitor(healthy=True, ROC_TEMP_WARN="60")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        message = self.captured_message()
        self.assertIn("⚠️ [PVE][警告]", str(message["Subject"]))
        self.assertIn("严重 0 / 警告 1", str(message["Subject"]))
        self.assertIn("ROC温度为 62°C", message.get_body(preferencelist=("plain",)).get_content())

    def test_sender_sets_header_and_envelope(self):
        result = self.run_monitor(ALERT_FROM="PVE 监控 <sender@example.com>",
                                  FAKE_EXPECT_SENDER="sender@example.com")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("已提交本机邮件队列", result.stdout)
        self.assertEqual(self.captured_message()["From"].addresses[0].addr_spec, "sender@example.com")

    def test_smart_attribute_anomaly_not_green(self):
        result = self.run_monitor(healthy=True, FAKE_SMART_PENDING_ID="4")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        plain = self.captured_message().get_body(preferencelist=("plain",)).get_content()
        self.assertIn("通过 7；需关注 1；未读取 0", plain)
        row = next(line for line in plain.splitlines() if line.startswith("DID 4"))
        self.assertIn("🔴 存在严重介质指标", row)

    def test_smart_read_failure_visible(self):
        result = self.run_monitor(healthy=True, FAKE_SMART_UNREADABLE_ID="0")
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        plain = self.captured_message().get_body(preferencelist=("plain",)).get_content()
        self.assertIn("通过 7；需关注 0；未读取 1", plain)
        self.assertIn("❔ 未能读取", plain)

    def test_cachevault_temperature_uses_all_digits(self):
        result = self.run_monitor(healthy=True, CACHEVAULT_TEMP_CRIT="30")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("CacheVault温度为 35°C", result.stdout)

    def test_delivery_failure_does_not_change_hardware_level(self):
        result = self.run_monitor(FAKE_EMAIL_FAIL="1")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertNotIn("已提交本机邮件队列", result.stdout)
        self.assertIn("模拟邮件队列不可用", result.stdout)
        reports = "".join(path.read_text(encoding="utf-8") for path in self.logs.glob("report-*.log"))
        self.assertIn("===== 邮件通知 =====", reports)
        self.assertIn("sendmail 返回 75", reports)

    def test_delivery_timeout(self):
        result = self.run_monitor(FAKE_EMAIL_DELAY="3", EMAIL_TIMEOUT="1")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("提交邮件超时", result.stdout)

    def test_missing_sendmail_visible(self):
        result = self.run_monitor(SENDMAIL_BIN=str(self.root / "missing-sendmail"))
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("找不到 sendmail", result.stdout)
        self.assertFalse((self.root / "captured.eml").exists())

    def test_healthy_does_not_send(self):
        result = self.run_monitor(healthy=True)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertFalse((self.root / "captured.eml").exists())

    def test_empty_recipient_does_not_send(self):
        result = self.run_monitor(ALERT_EMAIL="")
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertFalse((self.root / "captured.eml").exists())


if __name__ == "__main__":
    unittest.main()
