#!/usr/bin/env python3
"""
ddnsman - 阿里云云解析 DNS 交互式管理工具
支持查看、新增、修改、删除 DNS 解析记录，自动获取本机公网 IP，定时检测更新（DDNS）。
"""

import json
import os
import subprocess
import sys
import threading
import time

# ---- 自动安装缺失依赖 ----
def _install_deps():
    MISSING = []
    try:
        from aliyunsdkcore.client import AcsClient
    except ImportError:
        MISSING.append("aliyun-python-sdk-alidns")
    try:
        import questionary
    except ImportError:
        MISSING.append("questionary")
    try:
        import requests
    except ImportError:
        MISSING.append("requests")
    if not MISSING:
        return

    print("⏳ 正在安装依赖: %s" % ", ".join(MISSING))

    try:
        subprocess.run([sys.executable, "-m", "pip", "--version"],
                       capture_output=True, check=True)
    except:
        try:
            subprocess.check_call(
                ["sudo", "apt-get", "install", "-y", "-qq", "python3-pip"]
            )
        except:
            print("❌ 安装 pip 失败，请手动执行: sudo apt-get install python3-pip -y")
            sys.exit(1)

    try:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--user", "--quiet"] + MISSING
        )
    except subprocess.CalledProcessError:
        try:
            subprocess.check_call(
                [sys.executable, "-m", "pip", "install", "--user", "--quiet",
                 "--break-system-packages"] + MISSING
            )
        except subprocess.CalledProcessError:
            try:
                subprocess.check_call(
                    ["sudo", sys.executable, "-m", "pip", "install", "--quiet"] + MISSING
                )
            except:
                print("❌ 自动安装失败，请手动执行:")
                print("   pip install %s" % " ".join(MISSING))
                sys.exit(1)

_install_deps()

from aliyunsdkcore.client import AcsClient
from aliyunsdkalidns.request.v20150109 import (
    DescribeDomainRecordsRequest,
    AddDomainRecordRequest,
    UpdateDomainRecordRequest,
    DeleteDomainRecordRequest,
)
import questionary
import requests

CONFIG_FILE = os.path.expanduser("~/.alidns_config.json")
CACHE_FILE = os.path.expanduser("~/.alidns_ip_cache.json")
DEFAULT_TTL = 600
IP_TIMEOUT = 10
IP_SOURCES = [
    "https://ipinfo.io/ip",
    "https://ifconfig.me",
    "https://icanhazip.com",
    "https://checkip.amazonaws.com",
]
RECORD_TYPES = ["A", "AAAA", "CNAME", "MX", "TXT", "NS"]


# ============================================================
#  工具函数
# ============================================================

def get_public_ip(silent=False):
    if silent:
        for src in IP_SOURCES:
            try:
                resp = requests.get(src, timeout=IP_TIMEOUT)
                if resp.status_code == 200:
                    ip = resp.text.strip()
                    if ip:
                        return ip
            except requests.RequestException:
                continue
        return None

    stop_flag = threading.Event()

    def _countdown():
        for i in range(IP_TIMEOUT, 0, -1):
            if stop_flag.is_set():
                return
            sys.stdout.write(f"\r⏳ 正在获取公网IP... {i}秒  ")
            sys.stdout.flush()
            time.sleep(1)
        sys.stdout.write("\r" + " " * 40 + "\r")
        sys.stdout.flush()

    for src in IP_SOURCES:
        stop_flag.clear()
        t = threading.Thread(target=_countdown, daemon=True)
        t.start()
        try:
            resp = requests.get(src, timeout=IP_TIMEOUT)
            if resp.status_code == 200:
                ip = resp.text.strip()
                if ip:
                    stop_flag.set()
                    sys.stdout.write(f"\r✅ 获取到公网IP: {ip}  \n")
                    sys.stdout.flush()
                    return ip
        except requests.RequestException:
            pass
        finally:
            stop_flag.set()

    sys.stdout.write("\r❌ 获取公网IP失败，请检查网络连接\n")
    sys.stdout.flush()
    return None


# ============================================================
#  配置管理
# ============================================================

def load_config():
    if not os.path.exists(CONFIG_FILE):
        return {}
    try:
        with open(CONFIG_FILE) as f:
            cfg = json.load(f)
        if not cfg.get("access_key_id") or not cfg.get("access_key_secret"):
            return {}
        return cfg
    except (json.JSONDecodeError, IOError):
        return {}


def save_config(cfg):
    os.makedirs(os.path.dirname(CONFIG_FILE) or ".", exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
    os.chmod(CONFIG_FILE, 0o600)


def guide_config():
    print("\n请配置阿里云 AccessKey（RAM 子账号，最小权限）\n")
    cfg = {}
    cfg["access_key_id"] = questionary.text("AccessKey ID:").ask()
    if cfg["access_key_id"] is None:
        return {}
    cfg["access_key_secret"] = questionary.password("AccessKey Secret:").ask()
    if cfg["access_key_secret"] is None:
        return {}
    cfg["domain"] = questionary.text("默认域名（如 example.com）:").ask()
    if cfg["domain"] is None:
        return {}
    cfg["ddns_records"] = []
    cfg["ddns_interval"] = 5
    return cfg


# ============================================================
#  缓存管理
# ============================================================

def load_ip_cache():
    if not os.path.exists(CACHE_FILE):
        return {}
    try:
        with open(CACHE_FILE) as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}


def save_ip_cache(cache):
    os.makedirs(os.path.dirname(CACHE_FILE) or ".", exist_ok=True)
    with open(CACHE_FILE, "w") as f:
        json.dump(cache, f, indent=2)


def get_ddns_status(cfg, rr):
    return rr in cfg.get("ddns_records", [])


def set_ddns_record(cfg, rr, enabled):
    ddns_records = cfg.get("ddns_records", [])
    if enabled and rr not in ddns_records:
        ddns_records.append(rr)
    elif not enabled and rr in ddns_records:
        ddns_records.remove(rr)
    cfg["ddns_records"] = ddns_records
    save_config(cfg)


# ============================================================
#  Cron 管理
# ============================================================

def get_script_path():
    return os.path.realpath(__file__)


def build_cron_line(interval):
    script = get_script_path()
    log_file = os.path.expanduser("~/.ddnsman.log")
    return (
        f"*/{interval} * * * * {sys.executable} {script} --watch >> {log_file} 2>&1"
    )


def install_cron(interval):
    cron_line = build_cron_line(interval)
    script = get_script_path()
    result = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    current = result.stdout if result.returncode == 0 else ""
    lines = current.splitlines()

    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if script in stripped and "--watch" in stripped:
            found = True
            if stripped.startswith("#"):
                new_lines.append(cron_line)
            elif stripped != cron_line:
                new_lines.append(cron_line)
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)

    if not found:
        new_lines.append(cron_line)

    new_cron = "\n".join(new_lines) + "\n"
    p = subprocess.Popen(["crontab"], stdin=subprocess.PIPE, text=True)
    p.communicate(new_cron)
    return found


def uninstall_cron():
    script = get_script_path()
    result = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    if result.returncode != 0:
        return False
    lines = result.stdout.splitlines()
    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if script in stripped and "--watch" in stripped and not stripped.startswith("#"):
            new_lines.append(f"# {line}")
            found = True
        else:
            new_lines.append(line)
    if found:
        new_cron = "\n".join(new_lines) + "\n"
        p = subprocess.Popen(["crontab"], stdin=subprocess.PIPE, text=True)
        p.communicate(new_cron)
    return found


def is_cron_installed():
    script = get_script_path()
    result = subprocess.run(["crontab", "-l"], capture_output=True, text=True)
    if result.returncode != 0:
        return False
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if script in stripped and "--watch" in stripped and not stripped.startswith("#"):
            return True
    return False


# ============================================================
#  阿里云客户端
# ============================================================

def get_client(cfg):
    return AcsClient(
        cfg["access_key_id"],
        cfg["access_key_secret"],
        "cn-hangzhou",
    )


def verify_config(cfg):
    try:
        client = get_client(cfg)
        req = DescribeDomainRecordsRequest.DescribeDomainRecordsRequest()
        req.set_DomainName(cfg["domain"])
        req.set_PageSize(1)
        client.do_action_with_exception(req)
        return True, None
    except Exception as e:
        return False, str(e)


# ============================================================
#  DNS 操作
# ============================================================

def get_records(client, domain):
    req = DescribeDomainRecordsRequest.DescribeDomainRecordsRequest()
    req.set_DomainName(domain)
    req.set_PageSize(500)
    resp = client.do_action_with_exception(req)
    data = json.loads(resp)
    return data.get("DomainRecords", {}).get("Record", [])


def add_dns_record(client, domain, rr, rtype, value, ttl=None, priority=None):
    req = AddDomainRecordRequest.AddDomainRecordRequest()
    req.set_DomainName(domain)
    req.set_RR(rr)
    req.set_Type(rtype)
    req.set_Value(value)
    if ttl:
        req.set_TTL(ttl)
    if priority is not None:
        req.set_Priority(priority)
    client.do_action_with_exception(req)


def update_dns_record(client, record_id, rr, rtype, value, ttl=None, priority=None):
    req = UpdateDomainRecordRequest.UpdateDomainRecordRequest()
    req.set_RecordId(record_id)
    req.set_RR(rr)
    req.set_Type(rtype)
    req.set_Value(value)
    if ttl:
        req.set_TTL(ttl)
    if priority is not None:
        req.set_Priority(priority)
    client.do_action_with_exception(req)


def delete_dns_record(client, record_id):
    req = DeleteDomainRecordRequest.DeleteDomainRecordRequest()
    req.set_RecordId(record_id)
    client.do_action_with_exception(req)


# ============================================================
#  交互流程
# ============================================================

def add_record_flow(client, domain, cfg):
    rr = questionary.text("主机记录（如 www、@）:").ask()
    if not rr:
        return
    rtype = questionary.select("记录类型:", choices=RECORD_TYPES).ask()
    if not rtype:
        return

    priority = None
    if rtype == "MX":
        priority = questionary.text("MX 优先级（默认 10）:", default="10").ask()
        if not priority:
            return
        try:
            priority = int(priority)
        except ValueError:
            print("❌ 优先级必须是数字")
            return

    use_auto = questionary.confirm("是否自动获取本机公网 IP？").ask()
    if use_auto is None:
        return
    if use_auto:
        ip = get_public_ip()
        if not ip:
            print("⚠️  改为手动输入")
            ip = questionary.text("记录值:").ask()
            if not ip:
                return
    else:
        ip = questionary.text("记录值:").ask()
        if not ip:
            return

    use_ddns = questionary.confirm(
        "是否开启定时更新（检测 IP 变化自动同步）？"
    ).ask()
    if use_ddns is None:
        return

    ttl = cfg.get("ttl", DEFAULT_TTL)
    summary = f"{rr}.{domain}  {rtype} -> {ip}"
    if priority is not None:
        summary += f" (优先级 {priority})"
    summary += f"  TTL={ttl}"
    if use_ddns:
        summary += "  [定时更新]"

    confirm = questionary.confirm(f"确认新增: {summary}").ask()
    if not confirm:
        print("已取消")
        return

    try:
        add_dns_record(client, domain, rr, rtype, ip, ttl, priority)
        print(f"✅ 已新增: {rr}.{domain}  {rtype} -> {ip}")
    except Exception as e:
        print(f"❌ 新增失败: {e}")
        return

    if use_ddns:
        set_ddns_record(cfg, rr, True)
        if not is_cron_installed():
            install_cron(cfg.get("ddns_interval", 5))
            print("📌 已添加 crontab 定时任务，每 %s 分钟检测一次" % cfg.get("ddns_interval", 5))
        print("📌 已加入定时更新列表")


def record_menu_flow(client, record, cfg):
    rid = record.get("RecordId")
    rr = record.get("RR", "")
    domain = record.get("DomainName", "")
    rtype = record.get("Type", "")
    val = record.get("Value", "")
    priority = record.get("Priority")
    ddns_on = get_ddns_status(cfg, rr)

    desc = f"{rr}.{domain} ({rtype} -> {val})"
    ddns_label = "关闭" if ddns_on else "开启"

    action = questionary.select(
        f"操作 [{desc}]",
        choices=[
            "1. 修改记录值",
            "2. 删除该记录",
            f"3. 定时更新 [{ddns_label}]",
            "4. 返回",
        ],
    ).ask()
    if not action:
        return

    if action.startswith("1"):
        new_val = questionary.text("新的记录值:", default=val).ask()
        if not new_val:
            return
        ttl = cfg.get("ttl", DEFAULT_TTL)
        try:
            update_dns_record(client, rid, rr, rtype, new_val, ttl, priority)
            print(f"✅ 已更新: {rr}.{domain}  {rtype} -> {new_val}")
        except Exception as e:
            print(f"❌ 更新失败: {e}")

    elif action.startswith("2"):
        confirm = questionary.confirm(
            f"确认删除 {desc}？此操作不可恢复"
        ).ask()
        if confirm:
            try:
                delete_dns_record(client, rid)
                print("✅ 已删除")
            except Exception as e:
                print(f"❌ 删除失败: {e}")

    elif action.startswith("3"):
        new_status = not ddns_on
        set_ddns_record(cfg, rr, new_status)
        if new_status:
            print(f"📌 {rr} 已加入定时更新列表")
            if not is_cron_installed():
                install_cron(cfg.get("ddns_interval", 5))
                print("📌 已添加 crontab 定时任务，每 %s 分钟检测一次" % cfg.get("ddns_interval", 5))
        else:
            print(f"📌 {rr} 已从定时更新列表移除")
            if not cfg.get("ddns_records"):
                uninstall_cron()
                print("📌 已暂停 crontab 定时任务（无跟踪记录）")


def list_records_flow(client, domain, cfg):
    try:
        records = get_records(client, domain)
    except Exception as e:
        print(f"❌ 获取解析记录失败: {e}")
        return

    if not records:
        print("该域名下暂无解析记录")
        return

    choices = []
    for r in records:
        rr = r["RR"]
        ddns_mark = " 🔄" if get_ddns_status(cfg, rr) else ""
        choices.append(
            f"{rr}.{r['DomainName']}  ({r['Type']} -> {r['Value']}){ddns_mark}"
        )
    choice = questionary.select("选择一条记录:", choices=choices).ask()
    if not choice:
        return
    idx = choices.index(choice)
    record_menu_flow(client, records[idx], cfg)


def ddns_settings_flow(cfg):
    records = cfg.get("ddns_records", [])
    interval = cfg.get("ddns_interval", 5)
    cron_ok = is_cron_installed()
    cron_status = "✅ 已安装" if cron_ok else "❌ 未安装"
    record_str = ", ".join(records) if records else "（无）"

    action = questionary.select(
        f"DDNS 设置  [跟踪: {record_str}]  [间隔: {interval}分钟]  [cron: {cron_status}]",
        choices=[
            "1. 查看/修改跟踪记录",
            "2. 修改检测间隔（当前 %s 分钟）" % interval,
            "3. 安装/更新 crontab" if not cron_ok else "3. 卸载 crontab",
            "4. 返回",
        ],
    ).ask()
    if not action:
        return

    if action.startswith("1"):
        if not records:
            print("当前没有跟踪的记录，请在新增或管理记录时开启定时更新")
            return
        print("当前定时更新的记录:")
        for i, rr in enumerate(records, 1):
            print(f"  {i}. {rr}")
        remove_rr = questionary.text(
            "输入要移除的 RR 名称（留空跳过）:"
        ).ask()
        if remove_rr and remove_rr in records:
            set_ddns_record(cfg, remove_rr, False)
            print(f"📌 {remove_rr} 已从定时更新列表移除")
            if not cfg.get("ddns_records"):
                uninstall_cron()
                print("📌 已暂停 crontab 定时任务（无跟踪记录）")

    elif action.startswith("2"):
        new_interval = questionary.text(
            "检测间隔（分钟，1~60）:", default=str(interval)
        ).ask()
        if new_interval:
            try:
                val = int(new_interval)
                if 1 <= val <= 60:
                    cfg["ddns_interval"] = val
                    save_config(cfg)
                    if is_cron_installed():
                        install_cron(val)
                    print(f"✅ 检测间隔已修改为 {val} 分钟")
                else:
                    print("❌ 请输入 1~60 之间的数字")
            except ValueError:
                print("❌ 请输入有效数字")

    elif action.startswith("3"):
        if cron_ok:
            if uninstall_cron():
                print("✅ 已暂停 crontab 定时任务（已注释）")
            else:
                print("未找到相关 crontab 任务")
        else:
            records = cfg.get("ddns_records", [])
            if not records:
                print("❌ 没有定时更新的记录，请先添加记录并开启定时更新")
                return
            install_cron(cfg.get("ddns_interval", 5))
            print("✅ 已安装 crontab 定时任务，每 %s 分钟检测一次" % cfg.get("ddns_interval", 5))


def main_menu_flow():
    cfg = load_config()
    if not cfg:
        cfg = guide_config()
        if not cfg.get("access_key_id"):
            print("配置取消，退出")
            return
        save_config(cfg)
        print("正在验证配置...")
        ok, err = verify_config(cfg)
        if not ok:
            print(f"❌ 配置验证失败: {err}")
            print("请重新运行脚本或手动编辑 ~/.alidns_config.json")
            return
        print("✅ 配置验证通过")

    client = get_client(cfg)
    domain = cfg.get("domain", "")

    while True:
        action = questionary.select(
            f"主菜单  [域名: {domain}]",
            choices=[
                "1. 查看/管理解析记录",
                "2. 新增解析记录",
                "3. 切换域名",
                "4. 重新配置 AccessKey",
                "5. DDNS 设置",
                "6. 退出",
            ],
        ).ask()
        if not action:
            break

        if action.startswith("1"):
            list_records_flow(client, domain, cfg)

        elif action.startswith("2"):
            add_record_flow(client, domain, cfg)

        elif action.startswith("3"):
            new_domain = questionary.text(
                "输入新域名（如 example.com）:", default=domain
            ).ask()
            if new_domain:
                domain = new_domain
                cfg["domain"] = domain
                save_config(cfg)
                print(f"✅ 已切换到域名: {domain}")

        elif action.startswith("4"):
            confirm = questionary.confirm(
                "确认重新配置 AccessKey？所有 DNS 操作将使用新密钥"
            ).ask()
            if confirm:
                cfg = guide_config()
                if not cfg.get("access_key_id"):
                    print("重新配置取消，使用旧配置")
                    cfg = load_config()
                    if not cfg:
                        break
                    continue
                save_config(cfg)
                print("正在验证新配置...")
                ok, err = verify_config(cfg)
                if not ok:
                    print(f"❌ 配置验证失败: {err}")
                    print("请重新运行脚本")
                    return
                print("✅ 配置验证通过")
                client = get_client(cfg)
                domain = cfg.get("domain", "")

        elif action.startswith("5"):
            ddns_settings_flow(cfg)

        elif action.startswith("6"):
            if questionary.confirm("确认退出？").ask():
                print("再见！")
                break


# ============================================================
#  Watch 模式（DDNS 后台检测）
# ============================================================

def watch_mode():
    cfg = load_config()
    if not cfg:
        print("❌ 配置文件不存在或无效，请先运行交互模式配置")
        sys.exit(1)

    domain = cfg.get("domain", "")
    ddns_records = cfg.get("ddns_records", [])
    interval = cfg.get("ddns_interval", 5)

    if not ddns_records or not domain:
        print("未配置 DDNS 跟踪记录或域名")
        sys.exit(1)

    ip = get_public_ip(silent=True)
    if not ip:
        print("❌ 获取公网 IP 失败")
        sys.exit(1)

    try:
        client = get_client(cfg)
        records = get_records(client, domain)
    except Exception as e:
        print(f"❌ 获取解析记录失败: {e}")
        sys.exit(1)

    record_map = {}
    for r in records:
        rr = r.get("RR", "")
        if rr not in record_map:
            record_map[rr] = r

    cache = load_ip_cache()
    updated = []

    print("[ddnsman] %s  公网 IP: %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), ip))

    for rr in ddns_records:
        target = record_map.get(rr)
        if not target:
            print(f"  ⚠️  {rr}.{domain}: 未在阿里云中找到此记录，跳过")
            continue

        cached_ip = cache.get(rr)
        if cached_ip == ip:
            print(f"  {rr}.{domain}: IP 无变化 ({ip})")
            continue

        try:
            rtype = target["Type"]
            rid = target["RecordId"]
            priority = target.get("Priority")
            ttl = cfg.get("ttl", DEFAULT_TTL)

            update_dns_record(client, rid, rr, rtype, ip, ttl, priority)
            print(f"  ✅ {rr}.{domain}: {cached_ip or '无'} -> {ip}")
            cache[rr] = ip
            updated.append(rr)
        except Exception as e:
            print(f"  ❌ {rr}.{domain}: 更新失败 - {e}")

    if updated:
        cache["last_check"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        save_ip_cache(cache)


# ============================================================
#  入口
# ============================================================

def main():
    try:
        main_menu_flow()
    except KeyboardInterrupt:
        print("\n再见！")
    except Exception as e:
        print(f"\n❌ 程序异常: {e}")
        sys.exit(1)


if __name__ == "__main__":
    if "--watch" in sys.argv:
        watch_mode()
    else:
        main()
