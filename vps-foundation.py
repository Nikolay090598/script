#!/usr/bin/env python3
"""Interactive VPS provisioning for Debian and Ubuntu with systemd."""
import argparse
import ast
from contextlib import contextmanager
import datetime
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import fcntl
import hmac
import ipaddress
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import shlex
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

VERSION = "7.0.0-beta2"
COWRIE_VERSION = "3.1.2"
STATE = Path("/var/lib/vps-foundation-python")
PROGRAM = Path("/usr/local/libexec/vps-foundation/vps-foundation.py")
CONFIRMED = STATE / "config.json"
PENDING = STATE / "pending.json"
ACTIVE = STATE / "active.json"
UNIT_DIR = Path("/etc/systemd/system")
ADMIN = "vps-foundation-sshd.service"
SSH_CONFIG = Path("/etc/ssh/vps-foundation-python.conf")
ADMIN_KEYS = Path("/etc/ssh/vps-foundation-authorized-keys")
LEGACY_SSH = ("ssh.socket", "ssh.service")
ROLLBACK = "vps-foundation-python-rollback"
COWRIE = "vps-cowrie.service"
GUARD = "vps-cowrie-firewall-guard"
CLEAN = "vps-cowrie-maintenance"
COWRIE_PREFLIGHT = "vps-cowrie-firewall-preflight.service"
HOME = Path("/var/lib/vps-cowrie")
VENV = Path("/opt/vps-cowrie")
COWRIE_LOG = HOME / "var/log/cowrie/cowrie.json"
POLICY = Path("/etc/vps-cowrie-maintenance.json")
SSH_JAIL = Path("/etc/fail2ban/jail.d/99-vps-foundation.local")
BAN_FILTER = Path("/etc/fail2ban/filter.d/vps-cowrie-auth.conf")
BAN_JAIL = Path("/etc/fail2ban/jail.d/99-vps-cowrie-bans.local")
BAN_GLOBAL = Path("/etc/fail2ban/fail2ban.d/99-vps-cowrie-retention.local")
BAN_FILES = (BAN_FILTER, BAN_JAIL, BAN_GLOBAL)
FIREWALL = (Path("/etc/ufw/before.rules"), Path("/etc/ufw/before6.rules"))
MARKER = "VPS_FOUNDATION_PYTHON"
BAN_MARKER = "VPS_COWRIE_BANS_MANAGED"
SSH_DEADLINE = 15 * 60
APT = ("apt-get", "-o", "Acquire::Retries=3", "-o", "Dpkg::Options::=--force-confdef",
       "-o", "Dpkg::Options::=--force-confold")


class InstallError(Exception):
    pass


def run(*args, capture=False, check=True, timeout=60, data=None):
    result = subprocess.run(
        tuple(map(str, args)), text=True, capture_output=capture, input=data,
        timeout=timeout, env={**os.environ, "LC_ALL": "C", "DEBIAN_FRONTEND": "noninteractive"},
    )
    if check and result.returncode:
        error = (result.stderr or result.stdout or "").strip() if capture else ""
        raise InstallError(f"{shlex.join(map(str, args))}: код {result.returncode} {error}".rstrip())
    return result


def output(*args, **kwargs):
    return run(*args, capture=True, **kwargs).stdout.strip()


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write(path, content, mode=0o600, owner=(0, 0)):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    fd, name = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content.encode() if isinstance(content, str) else content)
            os.fchmod(stream.fileno(), mode)
            os.fchown(stream.fileno(), *owner)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        Path(name).unlink(missing_ok=True)


def save(path, value, mode=0o600):
    write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n", mode)


def load(path):
    return json.loads(path.read_text())


def remove(path):
    path.unlink(missing_ok=True)
    if path.parent.is_dir():
        sync_dir(path.parent)


def state_ready():
    STATE.mkdir(mode=0o700, exist_ok=True)
    info = STATE.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise InstallError(f"Для {STATE} нужны владелец root и права 0700.")


@contextmanager
def lock():
    fd = os.open(STATE / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise InstallError("Другой экземпляр сейчас изменяет систему.") from exc
        yield
    finally:
        os.close(fd)


def active(unit):
    return run("systemctl", "is-active", "--quiet", unit, capture=True, check=False).returncode == 0


def enabled(unit):
    return output("systemctl", "is-enabled", unit, check=False)


def service(*args, **kwargs):
    return run("systemctl", *args, **kwargs)


def apt(*args):
    run(*APT, *args, timeout=3600)


def install_program():
    if Path(__file__).resolve() != PROGRAM:
        secure_directory(PROGRAM.parent.parent)
        secure_directory(PROGRAM.parent)
        write(PROGRAM, Path(__file__).read_bytes(), 0o755)


def tty_prompt(message, default=""):
    suffix = f" [{default}]" if default != "" else ""
    with open("/dev/tty", "w", encoding="utf-8") as terminal:
        terminal.write(f"{message}{suffix}: ")
    with open("/dev/tty", encoding="utf-8") as terminal:
        answer = terminal.readline()
    if not answer:
        raise InstallError("Ввод закрыт.")
    return answer.strip() or str(default)


def question(message, default=True):
    while True:
        answer = tty_prompt(f"{message} (y/n)", "y" if default else "n").lower()
        if answer in ("y", "yes", "да", "д"):
            return True
        if answer in ("n", "no", "нет", "н"):
            return False


def number(message, default, low, high, excluded=()):
    while True:
        answer = tty_prompt(message, default)
        if re.fullmatch(r"[0-9]{1,8}", answer):
            value = int(answer)
            if low <= value <= high and value not in excluded:
                return value
        print(f"Допустимый диапазон {low}–{high}, исключения: {list(excluded)}")


def network_prompt(message, default=""):
    while True:
        answer = tty_prompt(message + " (- для любого адреса)", default)
        if answer in ("", "-"):
            return ""
        try:
            if "%" in answer:
                raise ValueError
            return str(ipaddress.ip_network(answer, strict=False))
        except ValueError:
            print("Укажите IPv4/IPv6 или сеть в записи CIDR.")


def ssh_connection():
    parts = os.environ.get("SSH_CONNECTION", "").split()
    if not parts:
        return None
    if len(parts) != 4:
        raise InstallError("Некорректный SSH_CONNECTION.")
    remote, source, local, port = parts
    return [str(ipaddress.ip_address(remote)), int(source), str(ipaddress.ip_address(local)), int(port)]


def require_new_connection(cfg):
    connection = ssh_connection()
    if not connection or connection[3] != cfg["port"]:
        raise InstallError(f"Нужна новая SSH-сессия на порту {cfg['port']}. При sudo сохраните SSH_CONNECTION.")
    return connection


def read_key():
    while True:
        answer = tty_prompt("Публичный SSH-ключ или путь к файлу")
        path = Path(answer).expanduser()
        if len(answer) < 240 and answer and path.is_file():
            answer = path.read_text().strip()
        if re.fullmatch(r"(?:ssh-(?:ed25519|rsa)|ecdsa-sha2-\S+|sk-\S+) [A-Za-z0-9+/=]+(?: [^\r\n]*)?", answer):
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as stream:
                stream.write(answer + "\n")
                stream.flush()
                ssh_keygen = shutil.which("ssh-keygen")
                if ssh_keygen and run(ssh_keygen, "-lf", stream.name, capture=True, check=False).returncode:
                    print("ssh-keygen не распознал ключ.")
                    continue
            return answer
        print("Нужен публичный ключ OpenSSH в одну строку.")


def port_rules(text, ssh_port):
    rules = []
    for item in text.split():
        value, sep, source = item.partition("@")
        match = re.fullmatch(r"([0-9]{1,5})(?::([0-9]{1,5}))?/(tcp|udp)", value)
        if not match or (sep and (not source or "%" in source)):
            raise ValueError(f"Неверное правило: {item}")
        first, last = int(match[1]), int(match[2] or match[1])
        protocol = match[3]
        if not 1 <= first <= last <= 65535 or first <= 22 <= last:
            raise ValueError(f"Порт 22 зарезервирован или диапазон неверен: {item}")
        if protocol == "tcp" and first <= ssh_port <= last:
            raise ValueError(f"Диапазон пересекает порт SSH: {item}")
        network = str(ipaddress.ip_network(source, strict=False)) if source else ""
        rule = [str(first) if first == last else f"{first}:{last}", protocol, network]
        if rule not in rules:
            rules.append(rule)
    if len(rules) > 20:
        raise ValueError("Укажите до 20 правил.")
    return rules


def ban_questions(cfg):
    cfg["bans"] = question("Включить автобаны Cowrie", cfg["bans"])
    if not cfg["bans"]:
        return
    cfg["ban_days"] = number("Срок бана в днях", cfg["ban_days"], 1, 365)
    cfg["ban_retries"] = number("Попыток входа до бана", cfg["ban_retries"], 1, 20)
    cfg["ban_window"] = number("Окно подсчёта в секундах", cfg["ban_window"], 60, 86400)
    cfg["ban_scope"] = number("1 — только Cowrie, 2 — все входящие порты", cfg["ban_scope"], 1, 2)
    if cfg["ban_scope"] == 2 and tty_prompt("Для бана на всех портах введите ALL") != "ALL":
        raise InstallError("Режим бана на всех портах не подтверждён.")
    cfg["ban_extra_ip"] = network_prompt("Дополнительная сеть в исключениях", cfg["ban_extra_ip"])


def cleanup_questions(cfg):
    cfg["clean_days"] = number("Хранить записи, дней", cfg["clean_days"], 2, 365)
    cfg["clean_mib"] = number("Целевой объём записей, MiB", cfg["clean_mib"], 128, 65536)
    cfg["min_free_mib"] = number("Минимум свободного места, MiB", cfg["min_free_mib"], 128, 65536)


def wizard(*, ssh_only=False):
    expert = number("1 — простой режим, 2 — расширенный", 1, 1, 2) == 2
    connection = ssh_connection()
    cfg = dict(
        port=number("Новый порт настоящего SSH", 45123, 1, 65535, (22, 80, 443)),
        user=pwd.getpwuid(0).pw_name, key_only=True, public_key="", ssh_network="",
        cowrie=True, log_22=False, ports=[], swap_gib=2, timezone="Asia/Yekaterinburg",
        upgrade=True, xanmod=0, cpu_level=2, tcp_profile=1, bbr=True, forward=False,
        bans=True, ban_days=30, ban_retries=3, ban_window=600, ban_scope=1, ban_extra_ip="",
        clean_days=14, clean_mib=1024, min_free_mib=512,
    )
    suggested_user = os.environ.get("SUDO_USER", cfg["user"])
    if expert or suggested_user != "root":
        cfg["user"] = tty_prompt("Пользователь для нового SSH", suggested_user)
    pwd.getpwnam(cfg["user"])
    if not re.fullmatch(r"[a-zA-Z_][a-zA-Z0-9_.-]*", cfg["user"]):
        raise InstallError("Неподдерживаемое имя пользователя.")
    cfg["key_only"] = not expert or question("Разрешить вход только по ключу")
    if cfg["key_only"]:
        cfg["public_key"] = read_key()
    elif output("passwd", "-S", cfg["user"]).split()[1] != "P":
        raise InstallError("У выбранного пользователя нет активного пароля.")
    cfg["ssh_network"] = network_prompt("Сеть администратора для SSH", connection[0] if connection else "")
    if not cfg["key_only"] and not cfg["ssh_network"]:
        raise InstallError("Для парольного SSH необходимо ограничить сеть источника.")
    if connection and cfg["port"] == connection[3]:
        raise InstallError("Выберите порт, отличный от порта текущей SSH-сессии.")
    if ssh_only:
        cfg.update(setup_scope="ssh", cowrie=False, bans=False)
        return cfg
    cfg["cowrie"] = question("Включить Cowrie на 22/tcp IPv4")
    if cfg["cowrie"]:
        if sys.version_info < (3, 11):
            raise InstallError("Cowrie требует Python 3.11 или новее.")
        if expert:
            ban_questions(cfg)
    else:
        cfg["bans"] = False
        cfg["log_22"] = expert and question("Логировать обращения к закрытому порту 22", False)
    while True:
        try:
            cfg["ports"] = port_rules(tty_prompt(
                "Порты 3x-ui и приложений, например 8443/tcp@203.0.113.10 443/tcp (ENTER — пропустить)"
            ), cfg["port"])
            break
        except ValueError as exc:
            print(exc)
    if expert:
        cfg["swap_gib"] = number("Swap GiB (0 — пропустить)", 2, 0, 64)
        cfg["timezone"] = timezone_prompt(cfg["timezone"])
        cfg["upgrade"] = question("Обновить установленные пакеты")
        cfg["xanmod"] = number("Ядро: 0 — штатное, 1 — XanMod LTS, 2 — XanMod MAIN", 0, 0, 2)
        if cfg["xanmod"]:
            cfg["cpu_level"] = number("Уровень CPU x64v2/v3", 2, 2, 3)
        cfg["tcp_profile"] = number("TCP: 0 — пропустить, 1 — balanced, 2 — throughput", 1, 0, 2)
        cfg["bbr"] = question("Включить BBR, если доступен")
        cfg["forward"] = question("Включить IPv4 forwarding", False)
        if cfg["cowrie"]:
            cleanup_questions(cfg)
    return cfg


def unit_file(unit):
    return UNIT_DIR / unit


def save_files(directory, paths):
    directory.mkdir(mode=0o700, parents=True)
    for index, path in enumerate(paths):
        if path.is_symlink():
            raise InstallError(f"Символическая ссылка требует ручной проверки: {path}")
        if path.exists():
            if not path.is_file():
                raise InstallError(f"Ожидается обычный файл: {path}")
            info = path.stat()
            write(directory / str(index), path.read_bytes(), stat.S_IMODE(info.st_mode),
                  (info.st_uid, info.st_gid))


def restore_files(directory, paths):
    for index, path in enumerate(paths):
        restore_file(directory / str(index), path)


def restore_file(old, path):
    if old.exists():
        info = old.stat()
        write(path, old.read_bytes(), stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
    else:
        remove(path)


def ufw_active():
    return output("ufw", "status").splitlines()[0] == "Status: active"


def ipv6_firewall():
    params = Path("/etc/default/ufw").read_text()
    configured = bool(re.search(r"^IPV6=yes\s*$", params, re.M | re.I))
    flag = Path("/proc/sys/net/ipv6/conf/all/disable_ipv6")
    disabled = flag.exists() and flag.read_text().strip() == "1"
    if flag.exists() and not disabled and not configured:
        raise InstallError("IPv6 включён. Для безопасной настройки включите IPv6 в UFW.")
    return configured and not disabled and Path("/proc/net/if_inet6").exists()


def tagged_rules(text, ver, inputs, outputs):
    for name in ("INPUT", "OUTPUT"):
        start = f"# {MARKER}_{name}_START"
        end = f"# {MARKER}_{name}_END"
        if text.count(start) != text.count(end) or text.count(start) > 1:
            raise InstallError("Маркеры управляемых правил UFW повреждены.")
        if start in text:
            first = text.index(start)
            last = text.index(end)
            if last < first:
                raise InstallError("Нарушен порядок маркеров UFW.")
            text = text[:first] + text[last + len(end):].lstrip("\n")
    for name, rules in (("input", inputs), ("output", outputs)):
        if not rules:
            continue
        chain = f"ufw{'6' if ver == 6 else ''}-before-{name}"
        first_rule = re.search(rf"^-A {chain}\s", text, re.M)
        if not first_rule:
            raise InstallError(f"В файле UFW отсутствует цепочка {chain}.")
        label = f"{MARKER}_{name.upper()}"
        block = [f"# {label}_START", *(f"-A {chain} {rule}" for rule in rules), f"# {label}_END"]
        at = first_rule.start()
        text = text[:at] + "\n".join(block) + "\n" + text[at:]
    return text


def accept_rule(port, proto, network, version):
    if network:
        if ipaddress.ip_network(network).version != version:
            return None
        source = f" -s {network}"
    else:
        source = ""
    return f"-p {proto}{source} --dport {port} -m conntrack --ctstate NEW -j ACCEPT"


def firewall_test_input(text, version):
    # UFW normally creates its logging chain before loading before.rules.
    # Supply that chain only in the test when checking a fresh firewall.
    chain = "ufw6-logging-deny" if version == 6 else "ufw-logging-deny"
    if re.search(rf"(?m)^:{chain}\s", text):
        return text
    return text.replace("*filter\n", f"*filter\n:{chain} - [0:0]\n", 1)


def firewall(cfg, *, final, fallback_ports=()):
    versions = (4, 6) if ipv6_firewall() else (4,)
    for ver, path in zip(versions, FIREWALL):
        admin = accept_rule(cfg["port"], "tcp", cfg["ssh_network"], ver)
        inputs = [admin] if admin else []
        if cfg["ssh_network"]:
            inputs.append(f"-p tcp --dport {cfg['port']} -m conntrack --ctstate NEW -j DROP")
        host_rules = cfg["ports"] if final else [(port, "tcp", "") for port in fallback_ports]
        inputs.extend(rule for item in host_rules if (rule := accept_rule(*item, ver)))
        outputs = []
        if final:
            base = "-p tcp --dport 22 -m conntrack --ctstate NEW"
            if cfg["cowrie"] and ver == 4:
                inputs.append(base + " -j ACCEPT")
            else:
                if cfg["log_22"]:
                    inputs.append(base + ' -m limit --limit 6/min --limit-burst 10 -j LOG --log-prefix "VPS_PORT22: "')
                inputs.append(base + " -j DROP")
            if cfg["cowrie"]:
                uid = pwd.getpwnam("vps-cowrie").pw_uid
                outputs = [
                    f"-m owner --uid-owner {uid} -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
                    f"-m owner --uid-owner {uid} -j REJECT",
                ]
        text = tagged_rules(path.read_text(), ver, inputs, outputs)
        command = "ip6tables-restore" if ver == 6 else "iptables-restore"
        run(command, "--test", "--noflush", data=firewall_test_input(text, ver), capture=True)
        info = path.stat()
        write(path, text, stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
    if ufw_active():
        run("ufw", "reload")
    else:
        run("ufw", "--force", "enable")
    service("enable", "ufw.service")


def listeners(port):
    return output("ss", "-H", "-lntp", f"sport = :{port}")


def ssh_ready(cfg):
    run("/usr/sbin/sshd", "-t", "-f", SSH_CONFIG)
    if not active(ADMIN) or "sshd" not in listeners(cfg["port"]):
        raise InstallError(f"На {cfg['port']}/tcp отсутствует административный sshd.")


def write_admin(cfg):
    Path("/run/sshd").mkdir(mode=0o755, exist_ok=True)
    if cfg["key_only"]:
        write(ADMIN_KEYS, cfg["public_key"] + "\n", 0o644)
        run("ssh-keygen", "-lf", ADMIN_KEYS, capture=True)
    publickey = "yes" if cfg["key_only"] else "no"
    password = "no" if cfg["key_only"] else "yes"
    root_login = "prohibit-password" if cfg["key_only"] else "yes"
    user_pattern = cfg["user"] + ("@" + cfg["ssh_network"] if cfg["ssh_network"] else "")
    write(SSH_CONFIG, f"""# {MARKER}
Port {cfg['port']}
PidFile /run/vps-foundation-sshd.pid
AllowUsers {user_pattern}
UsePAM yes
PermitRootLogin {root_login}
PubkeyAuthentication {publickey}
AuthorizedKeysFile {ADMIN_KEYS}
PasswordAuthentication {password}
KbdInteractiveAuthentication no
AuthenticationMethods {'publickey' if cfg['key_only'] else 'password'}
MaxAuthTries 6
X11Forwarding no
UseDNS no
Subsystem sftp internal-sftp
""")
    run("/usr/sbin/sshd", "-t", "-f", SSH_CONFIG)
    write(unit_file(ADMIN), f"""[Unit]
Description=VPS Foundation administration SSH
After=network.target ufw.service
[Service]
Type=simple
ExecStartPre=/usr/bin/install -d -m 0755 /run/sshd
ExecStartPre=/usr/sbin/sshd -t -f {SSH_CONFIG}
ExecStart=/usr/sbin/sshd -D -f {SSH_CONFIG}
ExecReload=/bin/kill -HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
""", 0o644)


def write_ssh_jail(cfg):
    ignored = "127.0.0.0/8 ::1"
    if cfg["ssh_network"]:
        ignored += " " + cfg["ssh_network"]
    write(SSH_JAIL, f"""# {MARKER}
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT={ADMIN} + _COMM=sshd + _COMM=sshd-session
port = {cfg['port']}
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = {ignored}
usedns = no
""", 0o644)
    run("fail2ban-client", "-t")
    service("enable", "fail2ban.service")
    service("restart", "fail2ban.service")


def install_rollback_timer():
    write(unit_file(ROLLBACK + ".service"), f"""[Unit]
Description=Recover an unconfirmed SSH migration
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {PROGRAM} --rollback-if-expired
TimeoutStartSec=600
""", 0o644)
    write(unit_file(ROLLBACK + ".timer"), """[Unit]
Description=Check the SSH migration deadline
[Timer]
OnBootSec=30s
OnUnitInactiveSec=30s
AccuracySec=1s
[Install]
WantedBy=timers.target
""", 0o644)
    service("daemon-reload")
    service("enable", "--now", ROLLBACK + ".timer")
    if not active(ROLLBACK + ".timer"):
        raise InstallError("Таймер отката не запущен.")


def ssh_files():
    maintenance = tuple(unit_file(name + suffix) for name in (GUARD, CLEAN)
                        for suffix in (".service", ".timer"))
    return (*FIREWALL, Path("/etc/ufw/ufw.conf"), SSH_CONFIG, ADMIN_KEYS, unit_file(ADMIN),
            SSH_JAIL, POLICY, *maintenance)


def state_of_units():
    return {unit: {"active": active(unit), "enabled": enabled(unit)}
            for unit in (*LEGACY_SSH, "fail2ban.service", "ufw.service",
                         ADMIN, COWRIE, GUARD + ".timer", CLEAN + ".timer")}


def restore_enablement(unit, status):
    if status in ("enabled", "enabled-runtime"):
        options = ("--runtime",) if status.endswith("-runtime") else ()
        service("enable", *options, unit)
    elif status == "disabled":
        service("disable", unit)
    elif status in ("masked", "masked-runtime"):
        options = ("--runtime",) if status.endswith("-runtime") else ()
        service("mask", *options, unit)


def snapshot(cfg, stage="initial"):
    txid = secrets.token_hex(12)
    state = {"id": txid, "config": cfg, "units": state_of_units(),
             "ufw": ufw_active(), "stage": stage, "deadline": time.time() + SSH_DEADLINE}
    save_files(STATE / ("ssh-" + txid), ssh_files())
    install_rollback_timer()
    save(ACTIVE, state)
    return state


def committed(state):
    return CONFIRMED.exists() and load(CONFIRMED).get("transaction") == state["id"]


def rollback(state):
    if committed(state):
        remove(ACTIVE)
        stop_rollback_timer()
        return
    errors = []

    def attempt(function, *args):
        try:
            function(*args)
        except (InstallError, OSError, subprocess.SubprocessError) as exc:
            errors.append(str(exc))

    units = state["units"]
    for unit in (CLEAN + ".timer", GUARD + ".timer", COWRIE, ADMIN):
        if active(unit) and not units[unit]["active"]:
            attempt(service, "stop", unit)
        if not units[unit]["enabled"].startswith("enabled") and enabled(unit).startswith("enabled"):
            attempt(service, "disable", unit)
    files = STATE / ("ssh-" + state["id"])
    for index, path in enumerate(ssh_files()):
        attempt(restore_file, files / str(index), path)
    attempt(service, "daemon-reload")
    for unit in LEGACY_SSH:
        if units[unit]["active"] and not active(unit):
            attempt(service, "start", unit)
        attempt(restore_enablement, unit, units[unit]["enabled"])
    if state["ufw"]:
        if not ufw_active():
            attempt(run, "ufw", "--force", "enable")
        attempt(run, "ufw", "reload")
    else:
        attempt(run, "ufw", "--force", "disable")
    attempt(restore_enablement, "ufw.service", units["ufw.service"]["enabled"])
    for unit in (COWRIE, GUARD + ".timer", CLEAN + ".timer"):
        if units[unit]["active"] and not active(unit):
            attempt(service, "start", unit)
    if units["fail2ban.service"]["active"]:
        attempt(service, "restart", "fail2ban.service")
    elif active("fail2ban.service"):
        attempt(service, "stop", "fail2ban.service")
    attempt(restore_enablement, "fail2ban.service", units["fail2ban.service"]["enabled"])
    if errors:
        raise InstallError("Откат будет повторён. Ошибки: " + " | ".join(errors))
    remove(ACTIVE)
    stop_rollback_timer()
    print("Предыдущие SSH, UFW и Fail2ban восстановлены.")


def rollback_now():
    if ACTIVE.exists():
        rollback(load(ACTIVE))
    else:
        stop_rollback_timer()
        print("Активной SSH-транзакции нет.")


def stop_rollback_timer():
    try:
        service("disable", "--now", ROLLBACK + ".timer", check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"Таймер не удалось выключить: {exc}", file=sys.stderr)


@contextmanager
def protect_transaction(state):
    try:
        yield
    except (Exception, KeyboardInterrupt):
        try:
            rollback(state)
        except Exception as exc:
            print(exc, file=sys.stderr)
        raise


def legacy_ports():
    found = set()
    for line in output("ss", "-H", "-lntp").splitlines():
        columns = line.split()
        if len(columns) > 5 and "sshd" in columns[-1]:
            found.add(int(columns[3].rsplit(":", 1)[-1]))
    con = ssh_connection()
    if con:
        found.add(con[3])
    if active("ssh.socket"):
        addresses = output("systemctl", "show", "ssh.socket", "-p", "Listen", "--value")
        found.update(int(value) for value in re.findall(r":?(\d+)\s+\(Stream\)", addresses))
    return sorted(found)


def start_ssh(cfg):
    if ACTIVE.exists() or CONFIRMED.exists():
        raise InstallError("Обнаружена текущая или уже подтверждённая установка.")
    if listeners(cfg["port"]):
        raise InstallError(f"Порт {cfg['port']}/tcp уже занят.")
    if any(path.exists() for path in (SSH_CONFIG, ADMIN_KEYS, unit_file(ADMIN), SSH_JAIL)):
        raise InstallError("Найдены существующие файлы управления SSH. Нужна отдельная миграция.")
    if active(COWRIE):
        raise InstallError("Перед первым переносом требуется отдельная миграция существующего Cowrie.")
    ipv6_firewall()
    fallback = legacy_ports()
    state = snapshot(cfg)
    with protect_transaction(state):
        write_admin(cfg)
        firewall(cfg, final=False, fallback_ports=() if state["ufw"] else fallback)
        service("daemon-reload")
        service("enable", "--now", ADMIN)
        ssh_ready(cfg)
    print(f"Старый SSH работает со своими настройками. Откройте новое подключение:")
    print(f"  ssh -p {cfg['port']} {cfg['user']}@IP_СЕРВЕРА")
    print(f"В новой сессии: {admin_command(cfg, '--finalize')}")
    print("На проверку 15 минут.")


def admin_command(cfg, args):
    command = f"/usr/bin/python3 {PROGRAM} {args}"
    if cfg["user"] != "root":
        command = f"sudo --preserve-env=SSH_CONNECTION {command}"
    return command


def get_stage(stage):
    if not ACTIVE.exists():
        raise InstallError("Активной SSH-транзакции нет.")
    state = load(ACTIVE)
    if state["stage"] != stage or committed(state):
        raise InstallError("Команда недоступна на текущем этапе.")
    if time.time() >= state["deadline"]:
        raise InstallError("Время подтверждения истекло. Дождитесь отката или выполните --rollback.")
    return state


def finalize():
    state = get_stage("initial")
    cfg = state["config"]
    connection = require_new_connection(cfg)
    with protect_transaction(state):
        ssh_ready(cfg)
        for unit in LEGACY_SSH:
            if active(unit):
                service("stop", unit)
            enablement = enabled(unit)
            if enablement.startswith("enabled"):
                options = ("--runtime",) if enablement == "enabled-runtime" else ()
                service("disable", *options, unit)
        if listeners(22):
            raise InstallError("После остановки штатного SSH порт 22 всё ещё занят.")
        firewall(cfg, final=True)
        if cfg["cowrie"]:
            install_maintenance(cfg)
            service("enable", "--now", COWRIE)
            cowrie_ready()
            service("enable", "--now", GUARD + ".timer", CLEAN + ".timer")
        write_ssh_jail(cfg)
        state.update(stage="awaiting-confirm", token=secrets.token_hex(16),
                     connection=connection, deadline=time.time() + SSH_DEADLINE)
        save(ACTIVE, state)
    print("Откройте ещё одну новую SSH-сессию без multiplexing и выполните:")
    print("  " + admin_command(cfg, "--confirm " + state["token"]))


def confirm(token):
    state = get_stage("awaiting-confirm")
    cfg = state["config"]
    connection = require_new_connection(cfg)
    if connection == state["connection"] or not hmac.compare_digest(token, state["token"]):
        raise InstallError("Нужна другая SSH-сессия и действительный код подтверждения.")
    with protect_transaction(state):
        ssh_ready(cfg)
        if cfg["cowrie"]:
            cowrie_ready()
            verify_firewall()
        cfg["transaction"] = state["id"]
        save(CONFIRMED, {**cfg, "bans": False})
    remove(ACTIVE)
    stop_rollback_timer()
    remove(PENDING)
    print("Новый SSH подтверждён. Автоматический откат больше не применяется.")
    if cfg["cowrie"] and cfg["bans"]:
        configure_bans(cfg)
    print("Установка завершена.")


def secure_directory(path, mode=0o755, gid=0):
    path.mkdir(mode=mode, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
        raise InstallError(f"Для {path} нужен обычный каталог root без записи группы и остальных.")
    os.chown(path, 0, gid)
    os.chmod(path, mode)


def prepare_cowrie():
    if active(COWRIE):
        raise InstallError("Cowrie уже запущен.")
    if sys.version_info < (3, 11):
        raise InstallError("Cowrie требует Python 3.11 или новее.")
    if not (HOME / ".vps-python").is_file() and os.path.lexists(HOME):
        raise InstallError(f"Обнаружен ранее созданный {HOME}. Нужна отдельная миграция.")
    if not (VENV / ".vps-python").is_file() and os.path.lexists(VENV):
        raise InstallError(f"Обнаружен ранее созданный {VENV}. Нужна отдельная миграция.")
    try:
        account = pwd.getpwnam("vps-cowrie")
    except KeyError:
        run("useradd", "--system", "--user-group", "--home-dir", HOME, "--shell", "/usr/sbin/nologin", "vps-cowrie")
        account = pwd.getpwnam("vps-cowrie")
    if account.pw_dir != str(HOME) or account.pw_uid == 0:
        raise InstallError("Конфликт пользователя Cowrie.")
    secure_directory(HOME, 0o750, account.pw_gid)
    write(HOME / ".vps-python", "", 0o640)
    secure_directory(HOME / "etc", 0o750, account.pw_gid)
    secure_directory(VENV)
    write(VENV / ".vps-python", "")
    python = VENV / "bin/python"
    if not (VENV / ".installed").is_file():
        prior_umask = os.umask(0o022)
        try:
            run("/usr/bin/python3", "-m", "venv", VENV, timeout=600)
            run(python, "-m", "pip", "--isolated", "install", "--cert", "/etc/ssl/certs/ca-certificates.crt",
                f"cowrie=={COWRIE_VERSION}", timeout=1200)
        finally:
            os.umask(prior_umask)
        write(VENV / ".installed", COWRIE_VERSION + "\n")
    elif (VENV / ".installed").read_text().strip() != COWRIE_VERSION:
        raise InstallError("Установка содержит другую версию Cowrie.")
    # Only this single directory is writable by the service. Never follow its
    # children from the installer running as root.
    var = HOME / "var"
    if not os.path.lexists(var):
        var.mkdir(mode=0o750)
        os.chown(var, account.pw_uid, account.pw_gid)
    info = var.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != account.pw_uid:
        raise InstallError(f"Небезопасный каталог состояния Cowrie: {var}")
    run("runuser", "-u", "vps-cowrie", "--", "mkdir", "-p",
        var / "log/cowrie", var / "lib/cowrie/downloads", var / "lib/cowrie/tty", var / "run")
    write(HOME / "etc/cowrie.cfg", """[honeypot]
hostname = srv-cache
auth_class = UserDB
backend = shell
download_limit_size = 10485760
logtype = rotating
[ssh]
enabled = true
listen_endpoints = tcp:22:interface=0.0.0.0
forwarding = false
sftp_enabled = false
[telnet]
enabled = false
[output_jsonlog]
enabled = true
""", 0o640, (0, account.pw_gid))
    write(HOME / "etc/userdb.txt", "root:x:*\nadmin:x:*\ntest:x:*\n", 0o640, (0, account.pw_gid))
    write(HOME / "installed-packages.txt", output(python, "-m", "pip", "freeze") + "\n")
    write(unit_file(COWRIE_PREFLIGHT), f"""[Unit]
Description=Verify Cowrie firewall isolation before startup
Requires=ufw.service
After=ufw.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {PROGRAM} --firewall-check
TimeoutStartSec=60
""", 0o644)
    write(unit_file(COWRIE), f"""[Unit]
Description=Cowrie SSH honeypot
Requires={COWRIE_PREFLIGHT}
After=network.target ufw.service {COWRIE_PREFLIGHT}
BindsTo=ufw.service
[Service]
Type=simple
User=vps-cowrie
Group=vps-cowrie
WorkingDirectory={HOME}
Environment=HOME={HOME}
Environment=PYTHONDONTWRITEBYTECODE=1
ExecStart={python} {VENV}/bin/twistd --umask 0077 --nodaemon --pidfile= -l - cowrie
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_UNIX
ReadWritePaths={var}
InaccessiblePaths=-/etc/ssh -/etc/x-ui -/etc/3x-ui -/etc/xray -/usr/local/x-ui -/var/lib/x-ui -/var/lib/3x-ui
MemoryMax=256M
TasksMax=64
CPUQuota=25%
LimitNOFILE=4096
LimitFSIZE=64M
[Install]
WantedBy=multi-user.target
""", 0o644)
    service("daemon-reload")
    run("runuser", "-u", "vps-cowrie", "--", python, "-c",
        "from twisted.application.service import IServiceMaker\n"
        "from twisted.plugin import getPlugins\n"
        "assert any(p.tapname == 'cowrie' for p in getPlugins(IServiceMaker))")


def cowrie_ready():
    uid = pwd.getpwnam("vps-cowrie").pw_uid
    for _ in range(15):
        rows = (line.split() for line in Path("/proc/net/tcp").read_text().splitlines()[1:])
        bound = any(row[1].endswith(":0016") and row[3] == "0A" and int(row[7]) == uid for row in rows)
        if bound and active(COWRIE):
            try:
                with socket.create_connection(("127.0.0.1", 22), timeout=2) as conn:
                    with conn.makefile("rb") as stream:
                        if stream.readline(256).startswith(b"SSH-2.0-"):
                            return
            except OSError:
                pass
        time.sleep(1)
    run("journalctl", "-u", COWRIE, "-b", "-n", "30", "--no-pager", check=False)
    raise InstallError("Cowrie не отвечает на 22/tcp.")


def chain_rules(command, chain):
    return [shlex.split(line) for line in output(command, "-w", "5", "-S", chain, timeout=10).splitlines()
            if line.startswith("-A ")]


def normal_rule(rule):
    result = list(rule)
    if "--ctstate" in result:
        index = result.index("--ctstate") + 1
        result[index] = ",".join(sorted(result[index].split(",")))
    if "--reject-with" in result:
        index = result.index("--reject-with")
        del result[index:index + 2]
    return result


def verify_firewall():
    if not ufw_active():
        raise InstallError("UFW выключен.")
    uid = str(pwd.getpwnam("vps-cowrie").pw_uid)
    commands = [("iptables", "ufw")]
    if ipv6_firewall():
        commands.append(("ip6tables", "ufw6"))
    for command, prefix in commands:
        chain = f"{prefix}-before-output"
        logging = f"{prefix}-before-logging-output"
        for rule in chain_rules(command, "OUTPUT"):
            if rule == ["-A", "OUTPUT", "-j", chain]:
                break
            if rule != ["-A", "OUTPUT", "-j", logging]:
                raise InstallError(f"{command}: правило OUTPUT перед UFW.")
            for logrule in chain_rules(command, logging):
                if "-g" in logrule or "-j" not in logrule or logrule[logrule.index("-j") + 1] not in ("LOG", "NFLOG", "RETURN"):
                    raise InstallError(f"{command}: нестандартная цепочка логирования UFW.")
        else:
            raise InstallError(f"{command}: отсутствует переход OUTPUT в {chain}.")
        rules = chain_rules(command, chain)
        owner = ["-A", chain, "-m", "owner", "--uid-owner", uid]
        expected = [owner + ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"],
                    owner + ["-j", "REJECT"]]
        if list(map(normal_rule, rules[:2])) != list(map(normal_rule, expected)):
            raise InstallError(f"{command}: отсутствуют правила изоляции Cowrie.")


def guard_firewall():
    if not active(COWRIE):
        return
    try:
        verify_firewall()
    except (InstallError, OSError, subprocess.SubprocessError):
        service("stop", COWRIE)
        raise


def prune_logs():
    policy = load(POLICY)
    max_age = policy["clean_days"] * 86400
    cap = policy["clean_mib"] * 1024**2
    reserve = policy["min_free_mib"] * 1024**2
    base = HOME / "var"
    now = time.time()
    files = []
    total = 0
    for relative in ("log/cowrie", "lib/cowrie/tty", "lib/cowrie/downloads"):
        root = base / relative
        for folder in (root, *root.parents):
            if folder == HOME:
                break
            if folder.is_symlink():
                raise InstallError(f"Символическая ссылка в каталоге Cowrie: {folder}")
        for directory, dirs, names in os.walk(root, followlinks=False):
            dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
            for name in names:
                path = Path(directory) / name
                try:
                    info = path.lstat()
                except FileNotFoundError:
                    continue
                if stat.S_ISREG(info.st_mode):
                    total += info.st_size
                    protected = name in ("cowrie.log", "cowrie.json") or info.st_mtime > now - 86400
                    files.append((info.st_mtime, info.st_size, path, protected))
    removed = 0
    free = shutil.disk_usage(base).free
    for mtime, size, path, protected in sorted(files):
        if protected or (mtime >= now - max_age and total <= cap and free >= reserve):
            continue
        try:
            path.unlink()
        except FileNotFoundError:
            continue
        removed += 1
        total -= size
        free = shutil.disk_usage(base).free
    print(f"Cowrie: удалено {removed}, записей {total // 1024**2} MiB, свободно {free // 1024**2} MiB.")
    if total > cap or free < reserve:
        raise InstallError("Место не удалось освободить до заданного порога.")


def clean_cowrie():
    if not active(COWRIE):
        return
    try:
        run("runuser", "-u", "vps-cowrie", "--", "/usr/bin/python3", PROGRAM, "--prune-logs", timeout=105)
    except (InstallError, OSError, subprocess.SubprocessError):
        service("stop", COWRIE)
        raise


def install_maintenance(cfg):
    save(POLICY, {key: cfg[key] for key in ("clean_days", "clean_mib", "min_free_mib")}, 0o644)
    for name, mode, interval, deadline in (
        (GUARD, "--firewall-guard", "30s", 65), (CLEAN, "--clean-cowrie", "5min", 180)
    ):
        write(unit_file(name + ".service"), f"""[Unit]
Description=VPS Foundation {name}
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 {PROGRAM} {mode}
TimeoutStartSec={deadline}
""", 0o644)
        write(unit_file(name + ".timer"), f"""[Unit]
Description=Schedule {name}
[Timer]
OnBootSec={interval}
OnUnitInactiveSec={interval}
[Install]
WantedBy=timers.target
""", 0o644)
    service("daemon-reload")


def maintenance():
    cfg = confirmed_settings()
    if not cfg["cowrie"] or not active(COWRIE):
        raise InstallError("Cowrie должен работать.")
    cleanup_questions(cfg)
    if tty_prompt("Для применения введите START") == "START":
        verify_firewall()
        install_maintenance(cfg)
        service("enable", "--now", GUARD + ".timer", CLEAN + ".timer")
        save(CONFIRMED, cfg)


def database_value(field):
    raw = output("fail2ban-client", "get", field)
    headings = {"dbpurgeage": "Current database purge age is:", "dbfile": "Current database file is:"}
    value = raw.removeprefix(headings[field]).strip()
    value = re.sub(r"^[`'|+]-\s*", "", value).strip()
    if field == "dbfile":
        if value[:1] in ("'", '"'):
            value = ast.literal_eval(value)
        if isinstance(value, str) and Path(value).is_absolute() and "\n" not in value:
            return value
    else:
        match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\s*(?:s|seconds?)?", value, re.I)
        if match:
            try:
                duration = Decimal(match[1])
                if 0 <= duration <= 10**12:
                    return int(duration.to_integral_value(rounding=ROUND_CEILING))
            except (InvalidOperation, OverflowError):
                pass
    raise InstallError(f"Fail2ban вернул неожиданное значение {field}: {raw!r}")


def ban_filter(work):
    q = r'"(?:[^"\\\r\n]|\\[^\r\n])*"'
    number = r'-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?'
    value = '(?:' + q + '|' + number + '|true|false|null)'
    pair = q + r'\s*:\s*' + value
    head = r'^\s*\{\s*(?:' + pair + r'\s*,\s*)*'
    middle = r'\s*,\s*(?:' + pair + r'\s*,\s*)*'
    tail = r'(?:\s*,\s*' + pair + r')*\s*\}\s*$'
    event = r'"eventid"\s*:\s*"cowrie\.login\.(?:failed|success)"'
    source = r'"src_ip"\s*:\s*"<ADDR>"'
    patterns = [head+event+middle+source+tail, head+source+middle+event+tail]
    date = r'{UNB}(?:(?<="timestamp": ")|(?<="timestamp":"))%%Y-%%m-%%dT%%H:%%M:%%S(?:\.%%f)?%%z'
    filt = work/'filter.new.conf'
    filt.write_text('# VPS_COWRIE_BANS_MANAGED\n[Definition]\nfailregex = ' + '\n            '.join(patterns) + '\nignoreregex =\nmaxlines = 1\ndatepattern = ' + date + '\n')
    compiled = [re.compile(p.replace('<ADDR>',r'(?P<host>[0-9a-fA-F:.]+)')) for p in patterns]
    now = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='microseconds').replace('+00:00','Z')
    valid = [
        {'eventid':'cowrie.login.failed','username':'u','password':'bad','src_ip':'192.0.2.10','timestamp':now},
        {'src_ip':'198.51.100.2','password':'"src_ip":"203.0.113.99"','timestamp':now,'eventid':'cowrie.login.success'},
        {'timestamp':now,'src_ip':'2001:db8::10','eventid':'cowrie.login.failed','message':'test'},
    ]
    invalid = [
        {'timestamp':now,'src_ip':'192.0.2.30','eventid':'cowrie.command.input','input':'"eventid":"cowrie.login.failed", "src_ip":"203.0.113.55"'},
        {'eventid':'cowrie.session.connect','src_ip':'192.0.2.40','timestamp':now,'message':'cowrie.login.success'},
    ]
    lines = []
    for i,obj in enumerate(valid+invalid):
        line = json.dumps(obj,separators=(',',':') if i%2 else None)
        matches = [m for rx in compiled if (m:=rx.fullmatch(line))]
        if i<len(valid):
            assert len(matches)==1 and matches[0].group('host')==obj['src_ip']
        else:
            assert not matches
        lines.append(line)
    fixture = work/'fixture.json'; fixture.write_text('\n'.join(lines)+'\n')
    def test_file(path,expected,count):
        result = run('fail2ban-regex', path, filt, capture=True, check=False, timeout=40)
        report = result.stdout+'\n'+result.stderr
        matched = re.search(r'Failregex:\s*(\d+)\s+total',report)
        section = report.split('Date template hits:',1)[-1].split('Lines:',1)[0]
        date_hits = sum(map(int,re.findall(r'(?m)^\s*\|\s*\[\s*(\d+)\s*\]',section)))
        if result.returncode or 'Date template hits:' not in report or not matched or int(matched[1])!=expected or date_hits<count:
            (work/'regex-diagnostic.txt').write_text(report)
            raise InstallError('Фильтр не прошёл fail2ban-regex; изменения не применены. Диагностика root-only: '+str(work/'regex-diagnostic.txt'))
    test_file(fixture,len(valid),len(lines))
    return filt, test_file


def backup_bans():
    for path in BAN_FILES:
        if path.is_symlink() or (path.exists() and BAN_MARKER not in path.read_text()):
            raise InstallError(f"Требуется ручная проверка существующего файла: {path}")
    backup = Path(tempfile.mkdtemp(prefix="bans-", dir=STATE))
    save_files(backup / "files", BAN_FILES)
    save(backup / "retention.json", database_value("dbpurgeage"))
    return backup


def reload_fail2ban():
    run("fail2ban-client", "-t")
    run("fail2ban-client", "reload")


def restore_bans(backup):
    restore_files(backup / "files", BAN_FILES)
    reload_fail2ban()
    run("fail2ban-client", "set", "dbpurgeage", load(backup / "retention.json"))


def ban_examples(work, test_file):
    # Read the service-owned log with the service account's permissions.
    result = run("runuser", "-u", "vps-cowrie", "--", "tail", "-c", "2097152", COWRIE_LOG,
                 capture=True, timeout=15)
    samples = []
    for line in result.stdout.splitlines():
        if len(line) > 65536:
            continue
        try:
            event = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if (isinstance(event, dict) and event.get("eventid") in {"cowrie.login.failed", "cowrie.login.success"}
                and event.get("timestamp") and event.get("src_ip")):
            samples.append(line)
    recent = samples[-30:]
    if recent:
        sample = work / "actual-auth.json"
        try:
            write(sample, "\n".join(recent) + "\n")
            test_file(sample, len(recent), len(recent))
        finally:
            remove(sample)
    print(f"Fail2ban: фильтр проверен на синтетических данных и {len(recent)} реальных строках.")


def configure_bans(cfg):
    if not active(COWRIE) or not active("fail2ban.service"):
        raise InstallError("Cowrie и Fail2ban должны работать.")
    if BAN_FILTER.with_suffix(".local").exists():
        raise InstallError("Найден vps-cowrie-auth.local. Проверьте настройки вручную.")
    database_value("dbfile")
    ignore = list(dict.fromkeys(filter(None, ("127.0.0.0/8", "::1", cfg["ssh_network"],
                                              (ssh_connection() or [""])[0], cfg["ban_extra_ip"]))))
    if cfg["ban_scope"] == 2 and len(ignore) <= 2:
        raise InstallError("Для бана на всех портах нужна сеть администратора в исключениях.")
    backup = backup_bans()
    filt, check_sample = ban_filter(backup)
    ban_examples(backup, check_sample)
    keep = max(load(backup / "retention.json"), 40 * 86400, (cfg["ban_days"] + 10) * 86400)
    name = "vps-cowrie-auth"
    if cfg["ban_scope"] == 1:
        action = f'iptables-multiport[name={name}, port="22", protocol=tcp]'
    else:
        action = f"iptables-allports[name={name}, protocol=all]"
    try:
        write(BAN_FILTER, filt.read_bytes(), 0o644)
        write(BAN_JAIL, f"""# {BAN_MARKER}
[{name}]
enabled = true
filter = {name}
backend = polling
logpath = {COWRIE_LOG} tail
logencoding = utf-8
logtimezone = UTC
usedns = no
maxretry = {cfg['ban_retries']}
findtime = {cfg['ban_window']}
bantime = {cfg['ban_days'] * 86400}
bantime.increment = false
ignoreself = true
ignoreip = {' '.join(ignore)}
action = {action}
""", 0o644)
        write(BAN_GLOBAL, f"# {BAN_MARKER}\n[Definition]\ndbpurgeage = {keep}\n", 0o644)
        run("fail2ban-client", "-t")
        found = None
        for line in output("fail2ban-client", "-d").splitlines():
            try:
                item = ast.literal_eval(line)
            except (SyntaxError, ValueError):
                continue
            if isinstance(item, (list, tuple)) and len(item) >= 3 and list(item[:2]) == ["set", "dbpurgeage"]:
                found = int(item[2])
        if found is None or found < keep:
            raise InstallError("Другой конфиг переопределяет dbpurgeage.")
        run("fail2ban-client", "reload")
        run("fail2ban-client", "set", "dbpurgeage", keep)
        run("fail2ban-client", "status", name)
        save(CONFIRMED, cfg)
    except (Exception, KeyboardInterrupt):
        restore_bans(backup)
        raise
    print(f"Откат настроек банов: sudo python3 {PROGRAM} --rollback-bans {backup}")


def change_bans(disable=False):
    cfg = confirmed_settings()
    if not cfg["cowrie"]:
        raise InstallError("Cowrie отключён.")
    if not disable:
        ban_questions(cfg)
        disable = not cfg["bans"]
    if tty_prompt("Для применения введите START") != "START":
        return
    if disable:
        if not BAN_JAIL.exists():
            cfg["bans"] = False
            save(CONFIRMED, cfg)
            return
        backup = backup_bans()
        try:
            write(BAN_JAIL, f"# {BAN_MARKER}\n[vps-cowrie-auth]\nenabled = false\n", 0o644)
            reload_fail2ban()
            cfg["bans"] = False
            save(CONFIRMED, cfg)
        except (Exception, KeyboardInterrupt):
            restore_bans(backup)
            raise
        print(f"Баны отключены. Резервная копия: {backup}")
    else:
        configure_bans(cfg)


def rollback_bans(value):
    backup = Path(value)
    if (backup.parent != STATE or not re.fullmatch(r"bans-[a-z0-9_]{8}", backup.name)
            or not (backup / "retention.json").is_file()):
        raise InstallError("Нужен путь к резервной копии банов из вывода установщика.")
    restore_bans(backup)
    cfg = confirmed_settings()
    cfg["bans"] = BAN_JAIL.is_file() and not re.search(r"(?m)^enabled\s*=\s*false\s*$", BAN_JAIL.read_text())
    save(CONFIRMED, cfg)


def check_grub():
    value = output("dpkg-query", "-W", "-f=${Status}", "grub-pc", check=False)
    if value != "install ok installed":
        return
    settings = output("debconf-show", "grub-pc")
    match = re.search(r"(?m)^\s*\*?\s*grub-pc/install_devices:\s*(.*)$", settings)
    for device in match[1].split(",") if match else ():
        device = device.strip()
        if device and not Path(device).is_block_device():
            raise InstallError(f"У GRUB отсутствует диск {device}. Проверьте загрузчик перед apt upgrade.")


def configure_swap(gib):
    if gib == 0:
        return
    swap = Path("/swapfile")
    if not os.path.lexists(swap):
        filesystem = output("findmnt", "-n", "-o", "FSTYPE", "-T", "/")
        if filesystem not in ("ext4", "xfs"):
            raise InstallError("Автосоздание swap поддерживается на ext4 и XFS. Выберите swap=0 для другой ФС.")
        if shutil.disk_usage("/").free <= (gib + 1) * 1024**3:
            raise InstallError("На диске нет места для swap и резерва 1 GiB.")
        fd, name = tempfile.mkstemp(prefix=".vps-swap-", dir="/")
        os.close(fd)
        try:
            run("dd", "if=/dev/zero", f"of={name}", "bs=1M", f"count={gib * 1024}", "status=progress", timeout=3600)
            run("mkswap", name)
            os.link(name, swap)
        finally:
            Path(name).unlink(missing_ok=True)
    if swap.is_symlink() or not swap.is_file() or output("blkid", "-p", "-s", "TYPE", "-o", "value", swap) != "swap":
        raise InstallError("Ожидается обычный swap-файл /swapfile.")
    swap.chmod(0o600)
    try:
        if str(swap) not in output("swapon", "--show=NAME", "--noheadings", "--raw").splitlines():
            run("swapon", swap)
        fstab = Path("/etc/fstab")
        current = fstab.read_text()
        if not re.search(r"(?m)^\s*/swapfile\s+", current):
            info = fstab.stat()
            write(fstab, current.rstrip("\n") + "\n/swapfile none swap sw 0 0\n",
                  stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
    except (Exception, KeyboardInterrupt):
        print("Проверьте /swapfile и /etc/fstab. SSH-транзакция ещё не началась.", file=sys.stderr)
        raise


SYSCTL = Path("/etc/sysctl.d/99-vps-foundation.conf")


def network_settings(cfg):
    values = {}
    profile = cfg["tcp_profile"]
    if profile:
        total = int(re.search(r"(?m)^MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text())[1])
        ceiling = 33554432 if total >= 2000000 else 16777216
        backlog, fin = 8192, 30
        if profile == 2:
            ceiling = 67108864 if total >= 4000000 else 33554432
            backlog, fin = 16384, 15
        values = {
            "net.core.default_qdisc": "fq", "net.core.somaxconn": 65535,
            "net.core.netdev_max_backlog": backlog, "net.ipv4.tcp_max_syn_backlog": backlog,
            "net.core.rmem_max": ceiling, "net.core.wmem_max": ceiling,
            "net.ipv4.tcp_rmem": f"4096 131072 {ceiling}", "net.ipv4.tcp_wmem": f"4096 65536 {ceiling}",
            "net.ipv4.tcp_moderate_rcvbuf": 1, "net.ipv4.tcp_keepalive_time": 600,
            "net.ipv4.tcp_keepalive_probes": 5, "net.ipv4.tcp_keepalive_intvl": 15,
            "net.ipv4.tcp_fin_timeout": fin, "net.ipv4.tcp_mtu_probing": 1,
            "net.ipv4.tcp_slow_start_after_idle": 0, "net.ipv4.tcp_fastopen": 3,
            "net.ipv4.tcp_tw_reuse": 2,
        }
    if cfg["bbr"]:
        run("modprobe", "tcp_bbr", capture=True, check=False)
        available = output("sysctl", "-n", "net.ipv4.tcp_available_congestion_control", check=False)
        if "bbr" in available.split():
            values.update({"net.core.default_qdisc": "fq", "net.ipv4.tcp_congestion_control": "bbr"})
        else:
            print("BBR недоступен на загруженном ядре.")
    if cfg["forward"]:
        values["net.ipv4.ip_forward"] = 1
    return values


def configure_network(cfg, backup):
    requested = network_settings(cfg)
    if not requested:
        return
    original = SYSCTL.read_text() if SYSCTL.exists() else ""
    previous = {}
    for key in tuple(requested):
        query = run("sysctl", "-n", key, capture=True, check=False)
        if query.returncode:
            requested.pop(key)
        else:
            previous[key] = query.stdout.strip()
    if not requested:
        return
    save(backup / "tcp-runtime.json", previous)
    save(STATE / "last-tcp.json", str(backup))
    preserved = [line for line in original.splitlines() if line.partition("=")[0].strip() not in requested]
    additions = [f"{key}={value}" for key, value in requested.items()]
    write(SYSCTL, "\n".join(preserved + additions) + "\n", 0o644)
    try:
        for assignment in additions:
            run("sysctl", "-w", assignment)
    except (Exception, KeyboardInterrupt):
        rollback_network()
        raise
    print(f"Откат TCP: sudo python3 {PROGRAM} --rollback-tcp")


def rollback_network():
    backup = Path(load(STATE / "last-tcp.json"))
    runtime = load(backup / "tcp-runtime.json")
    old = backup / ("files/0" if backup.name.startswith("tcp-") else "files/1")
    if old.is_file():
        info = old.stat()
        write(SYSCTL, old.read_bytes(), stat.S_IMODE(info.st_mode), (info.st_uid, info.st_gid))
    else:
        remove(SYSCTL)
    if "net.ipv4.ip_forward" in runtime:
        run("sysctl", "-w", f"net.ipv4.ip_forward={runtime.pop('net.ipv4.ip_forward')}")
    for key, value in runtime.items():
        run("sysctl", "-w", f"{key}={value}")
    print("Прежние настройки TCP восстановлены.")


XANMOD_SOURCE = Path("/etc/apt/sources.list.d/xanmod.sources")
XANMOD_KEY = Path("/etc/apt/keyrings/xanmod-archive-keyring.gpg")


def install_xanmod(cfg, release):
    if output("dpkg", "--print-architecture") != "amd64":
        raise InstallError("XanMod требует amd64.")
    flags = re.search(r"(?m)^flags\s*:\s*(.*)$", Path("/proc/cpuinfo").read_text())
    have = set(flags[1].split()) if flags else set()
    required = set("cx16 lahf_lm popcnt pni ssse3 sse4_1 sse4_2".split())
    if cfg["cpu_level"] == 3:
        required.update("avx avx2 bmi1 bmi2 f16c fma movbe xsave".split())
        if not {"lzcnt", "abm"} & have:
            required.add("lzcnt")
    if not required <= have:
        raise InstallError("CPU не поддерживает выбранный пакет. Нет: " + ", ".join(sorted(required - have)))
    codename = release.get("VERSION_CODENAME") or release.get("UBUNTU_CODENAME", "")
    if not re.fullmatch(r"[a-z][a-z0-9-]*", codename):
        raise InstallError("Не определено кодовое имя дистрибутива.")
    with tempfile.TemporaryDirectory() as work:
        key = Path(work) / "archive.key"
        binary = Path(work) / "archive.gpg"
        run("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https",
            "--proto-redir", "=https", "https://dl.xanmod.org/archive.key", "-o", key)
        run("gpg", "--batch", "--yes", "--dearmor", "--output", binary, key)
        write(XANMOD_KEY, binary.read_bytes(), 0o644)
    write(XANMOD_SOURCE, f"""Types: deb
URIs: https://deb.xanmod.org
Suites: {codename}
Components: main
Signed-By: {XANMOD_KEY}
""", 0o644)
    apt("update")
    branches = ("lts",) if cfg["xanmod"] == 1 or codename == "bookworm" else ("main", "lts")
    for branch in branches:
        suffix = "-lts" if branch == "lts" else ""
        package = f"linux-xanmod{suffix}-x64v{cfg['cpu_level']}"
        candidate = re.search(r"(?m)^\s*Candidate:\s+(\S+)", output("apt-cache", "policy", package))
        if candidate and candidate[1] != "(none)":
            exact = f"{package}={candidate[1]}"
            if run(*APT, "-s", "--no-remove", "install", exact, capture=True, check=False).returncode == 0:
                print(f"Устанавливается XanMod {branch}: {exact}")
                apt("install", "-y", "--no-remove", exact)
                return
    raise InstallError("Нет совместимого пакета XanMod.")


SSH_PACKAGES = ("openssh-server", "openssh-client", "ufw", "fail2ban", "python3-systemd",
                "util-linux", "iproute2", "iptables")
COWRIE_PACKAGES = ("python3-venv", "python3-dev", "libssl-dev", "libffi-dev", "build-essential",
                   "ca-certificates")


def timezone_prompt(default):
    zone = Path("/usr/share/zoneinfo")
    while True:
        answer = tty_prompt("Часовой пояс", default)
        path = (zone / answer).resolve()
        if not Path(answer).is_absolute() and path.is_relative_to(zone) and path.is_file():
            return answer
        print("Неизвестный часовой пояс.")


def configure_time(zone):
    run("timedatectl", "set-timezone", zone)
    service("enable", "--now", "chrony.service")


def update_packages():
    check_grub()
    run("dpkg", "--configure", "-a", timeout=3600)
    apt("update")
    apt("-y", "upgrade")


def base_setup(cfg, release):
    backup = Path(tempfile.mkdtemp(prefix="base-", dir=STATE))
    save_files(backup / "files", (Path("/etc/fstab"), SYSCTL, XANMOD_SOURCE, XANMOD_KEY))
    print(f"Резервная копия системных файлов: {backup}")
    if cfg["upgrade"]:
        update_packages()
    else:
        check_grub()
        run("dpkg", "--configure", "-a", timeout=3600)
        apt("update")
    packages = [*SSH_PACKAGES, "procps", "kmod", "ca-certificates", "chrony", "tzdata"]
    if cfg["cowrie"]:
        packages.extend(pkg for pkg in COWRIE_PACKAGES if pkg not in packages)
    if cfg["xanmod"]:
        packages.extend(("curl", "gnupg"))
    apt("install", "-y", *packages)
    if cfg["cowrie"]:
        prepare_cowrie()
    configure_time(cfg["timezone"])
    configure_swap(cfg["swap_gib"])
    if cfg["xanmod"]:
        try:
            install_xanmod(cfg, release)
        except (Exception, KeyboardInterrupt):
            for index, path in ((2, XANMOD_SOURCE), (3, XANMOD_KEY)):
                old = backup / "files" / str(index)
                if old.exists():
                    write(path, old.read_bytes(), stat.S_IMODE(old.stat().st_mode))
                else:
                    remove(path)
            raise
    configure_network(cfg, backup)


def confirmed_settings():
    if ACTIVE.exists():
        state = load(ACTIVE)
        if not committed(state):
            raise InstallError("Сначала завершите SSH-транзакцию.")
    if not CONFIRMED.exists():
        raise InstallError("Подтверждённой установки ещё нет.")
    return load(CONFIRMED)


def setup_swap():
    gib = number("Swap GiB (0 — вернуться)", 2, 0, 64)
    if gib and tty_prompt(f"Для настройки swap {gib} GiB введите START") == "START":
        configure_swap(gib)


def setup_time():
    current = output("timedatectl", "show", "--property=Timezone", "--value") or "UTC"
    zone = timezone_prompt(current)
    if tty_prompt(f"Для применения {zone} и запуска Chrony введите START") == "START":
        apt("update")
        apt("install", "-y", "chrony", "tzdata")
        configure_time(zone)


def setup_tcp():
    cfg = {"tcp_profile": number("TCP: 0 — без профиля, 1 — balanced, 2 — throughput", 1, 0, 2),
           "bbr": question("Включить BBR, если доступен"),
           "forward": question("Включить IPv4 forwarding", False)}
    if not any(cfg.values()) or tty_prompt("Для применения TCP введите START") != "START":
        return
    install_program()
    backup = Path(tempfile.mkdtemp(prefix="tcp-", dir=STATE))
    save_files(backup / "files", (SYSCTL,))
    configure_network(cfg, backup)


def setup_xanmod(release):
    branch = number("0 — вернуться, 1 — XanMod LTS, 2 — XanMod MAIN", 1, 0, 2)
    if not branch:
        return
    level = number("Уровень CPU x64v2/v3", 2, 2, 3)
    if tty_prompt("Для установки ядра введите START") != "START":
        return
    backup = Path(tempfile.mkdtemp(prefix="xanmod-", dir=STATE))
    paths = (XANMOD_SOURCE, XANMOD_KEY)
    save_files(backup / "files", paths)
    check_grub()
    apt("update")
    apt("install", "-y", "curl", "gnupg", "ca-certificates")
    try:
        install_xanmod({"xanmod": branch, "cpu_level": level}, release)
    except (Exception, KeyboardInterrupt):
        restore_files(backup / "files", paths)
        raise


def upgrade_system():
    if tty_prompt("Для обновления установленных пакетов введите START") == "START":
        update_packages()


def apply_firewall_settings(cfg, *, start_cowrie=False):
    install_program()
    state = snapshot(cfg, stage="component")
    with protect_transaction(state):
        ssh_ready(cfg)
        firewall(cfg, final=True)
        if start_cowrie:
            install_maintenance(cfg)
            service("enable", "--now", COWRIE)
            service("enable", "--now", GUARD + ".timer", CLEAN + ".timer")
        if cfg["cowrie"]:
            cowrie_ready()
            verify_firewall()
        ssh_ready(cfg)
        save(CONFIRMED, {**cfg, "transaction": state["id"]})
    remove(ACTIVE)
    stop_rollback_timer()


def setup_cowrie():
    cfg = confirmed_settings()
    if cfg["cowrie"] or active(COWRIE):
        raise InstallError("Cowrie уже настроен. Для изменения очистки используйте --setup-maintenance.")
    if sys.version_info < (3, 11):
        raise InstallError("Cowrie требует Python 3.11 или новее.")
    ssh_ready(cfg)
    if listeners(22):
        raise InstallError("Порт 22 занят. Освободите его перед установкой Cowrie.")
    cleanup_questions(cfg)
    if tty_prompt("Для установки Cowrie на 22/tcp введите START") != "START":
        return
    apt("update")
    apt("install", "-y", *COWRIE_PACKAGES)
    prepare_cowrie()
    cfg.update(cowrie=True, bans=False)
    apply_firewall_settings(cfg, start_cowrie=True)
    print("Cowrie работает на 22/tcp IPv4. Автобаны можно включить отдельным пунктом.")


def setup_ports():
    cfg = confirmed_settings()
    current = " ".join(f"{port}/{proto}" + (f"@{net}" if net else "") for port, proto, net in cfg["ports"])
    while True:
        answer = tty_prompt("Порты приложений, например 8443/tcp@203.0.113.10 (- очищает список)", current)
        try:
            rules = port_rules("" if answer == "-" else answer, cfg["port"])
            break
        except ValueError as exc:
            print(exc)
    if rules == cfg["ports"] or tty_prompt("Для применения правил UFW введите START") != "START":
        return
    cfg["ports"] = rules
    apply_firewall_settings(cfg)


def install(release, resume=False, ssh_only=False):
    if CONFIRMED.exists() or ACTIVE.exists():
        raise InstallError("Уже есть установка или активная транзакция. Используйте --status.")
    if any(path.exists() for path in (Path("/var/lib/vps-foundation/config.sh"),
                                      Path("/var/lib/vps-foundation/active"), Path("/root/.vps-config"),
                                      Path("/etc/ssh/vps-foundation.conf"), SSH_JAIL)):
        raise InstallError("Обнаружена Bash-версия. Эта сборка рассчитана на чистый VPS.")
    if resume:
        if not PENDING.exists():
            raise InstallError("Нет сохранённого плана для продолжения.")
        cfg = load(PENDING)
    else:
        cfg = wizard(ssh_only=ssh_only)
    print_settings(cfg)
    print("Разрешите новый SSH-порт в файрволе провайдера. Для первого прогона держите открытой его консоль.")
    print("Автооткат охватывает перенос SSH, правила UFW и конфигурацию SSH в Fail2ban.")
    if cfg.get("setup_scope") == "ssh":
        print("APT установит зависимости SSH, UFW и Fail2ban.")
    else:
        print("Пакеты, swap, время, Cowrie, ядро и TCP подготавливаются отдельно от переноса SSH.")
    if tty_prompt("Чтобы начать, введите START") != "START":
        return
    install_program()
    save(PENDING, cfg)
    if not resume or not cfg.get("prepared"):
        if cfg.get("setup_scope") == "ssh":
            apt("update")
            apt("install", "-y", *SSH_PACKAGES)
        else:
            base_setup(cfg, release)
        cfg["prepared"] = True
        save(PENDING, cfg)
    start_ssh(cfg)


def print_settings(cfg):
    public = cfg["ssh_network"] or "любой адрес"
    print(f"SSH: {cfg['user']}, {cfg['port']}/tcp, источник {public}, вход {'по ключу' if cfg['key_only'] else 'по паролю'}.")
    print(f"Cowrie: {'включён' if cfg['cowrie'] else 'выключен'}, автобаны: {'включены' if cfg['bans'] else 'выключены'}.")
    if cfg["bans"]:
        scope = "22/tcp" if cfg["ban_scope"] == 1 else "все входящие порты"
        print(f"Бан: {cfg['ban_days']} дней, {cfg['ban_retries']} попытки за {cfg['ban_window']} с, {scope}.")
    ports = " ".join(f"{port}/{proto}" + (f"@{net}" if net else "") for port, proto, net in cfg["ports"])
    print(f"Порты приложений: {ports or 'без новых разрешений'}.")
    if cfg.get("setup_scope") == "ssh":
        return
    profile = ("пропустить", "balanced", "throughput")[cfg["tcp_profile"]]
    kernel = ("штатное", "XanMod LTS", "XanMod MAIN")[cfg["xanmod"]]
    print(f"Swap: {cfg['swap_gib']} GiB, часовой пояс: {cfg['timezone']}, TCP: {profile}, ядро: {kernel}.")
    if cfg["cowrie"]:
        print(f"Записи Cowrie: {cfg['clean_days']} дней, целевой объём {cfg['clean_mib']} MiB, "
              f"резерв {cfg['min_free_mib']} MiB.")


def status():
    print(f"VPS Foundation {VERSION} · ядро {os.uname().release}")
    for unit in (*LEGACY_SSH, ADMIN, COWRIE, "fail2ban.service", ROLLBACK + ".timer",
                 GUARD + ".timer", CLEAN + ".timer"):
        print(f"{unit:42} {output('systemctl', 'is-active', unit, check=False)}")
    if ACTIVE.exists():
        state = load(ACTIVE)
        if not committed(state):
            remaining = max(0, int(state["deadline"] - time.time()))
            print(f"Транзакция: этап {state['stage']}, до автоотката {remaining} с.")
            cfg = state["config"]
            if state["stage"] == "initial":
                args = "--finalize"
            elif state["stage"] == "awaiting-confirm":
                args = "--confirm " + state["token"]
            else:
                args = "--rollback"
            print(admin_command(cfg, args))
    run("df", "-h", "/")
    run("free", "-h", check=False)
    for command in (("ufw", "status", "verbose"), ("ss", "-lntup"),
                    ("fail2ban-client", "status", "vps-cowrie-auth"),
                    ("sysctl", "net.ipv4.tcp_congestion_control", "net.core.default_qdisc")):
        if shutil.which(command[0]):
            run(*command, check=False)


def health():
    if not CONFIRMED.exists():
        if ACTIVE.exists():
            state = load(ACTIVE)
            if not committed(state):
                ssh_ready(state["config"])
                print("Ожидается подтверждение переноса SSH. Подробности в --status.")
                return
        run("/usr/sbin/sshd", "-t")
        if shutil.which("fail2ban-client"):
            run("fail2ban-client", "-t")
        print("Проверены доступные настройки текущего VPS.")
        return
    cfg = confirmed_settings()
    ssh_ready(cfg)
    run("fail2ban-client", "-t")
    if not active("fail2ban.service"):
        raise InstallError("Fail2ban не запущен.")
    if cfg["cowrie"]:
        cowrie_ready()
        verify_firewall()
        if cfg["bans"]:
            run("fail2ban-client", "status", "vps-cowrie-auth")
    run("df", "-h", "/")
    service("--failed", "--no-pager")
    print("Локальные проверки пройдены. Доступность SSH и панели проверьте с внешнего клиента.")


def logs():
    units = ((COWRIE,), (ADMIN, "ssh.service"), ("fail2ban.service",),
             (CLEAN + ".service", GUARD + ".service", ROLLBACK + ".service"))
    selection = number("1 — Cowrie, 2 — SSH, 3 — Fail2ban, 4 — обслуживание и автооткат", 1, 1, 4)
    run("journalctl", *(value for unit in units[selection - 1] for value in ("-u", unit)),
        "-n", "80", "--no-pager")


def unban():
    address = str(ipaddress.ip_address(tty_prompt("Какой IP разблокировать")))
    jail = ("vps-cowrie-auth", "sshd")[number("1 — Cowrie, 2 — настоящий SSH", 1, 1, 2) - 1]
    if tty_prompt(f"Для разблокировки {address} введите UNBAN") == "UNBAN":
        run("fail2ban-client", "set", jail, "unbanip", address)


SETUP_MENU = (
    ("Перенести SSH и настроить его защиту", "--setup-ssh"),
    ("Установить Cowrie после подтверждения SSH", "--setup-cowrie"),
    ("Настроить порты панели и приложений", "--setup-ports"),
    ("Настроить swap", "--setup-swap"),
    ("Настроить часовой пояс и Chrony", "--setup-time"),
    ("Настроить TCP, BBR и IPv4 forwarding", "--setup-tcp"),
    ("Установить ядро XanMod", "--setup-xanmod"),
    ("Обновить установленные пакеты", "--upgrade-system"),
    ("Запустить полный мастер установки", "--install"),
)
ADMIN_MENU = (
    ("Продолжить неудачную установку", "--resume-ssh"),
    ("Финализировать SSH из нового подключения", "--finalize"),
    ("Настроить автобаны Cowrie", "--configure-bans"),
    ("Состояние служб и портов", "--status"),
    ("Проверить конфигурацию и защиту", "--check"),
    ("Посмотреть журналы", "--logs"),
    ("Разблокировать IP", "--unban"),
    ("Настроить обслуживание Cowrie", "--setup-maintenance"),
    ("Отключить баны Cowrie", "--disable-bans"),
    ("Откатить неподтверждённый перенос SSH", "--rollback"),
    ("Показать сохранённые настройки", "--settings"),
)
MENU = SETUP_MENU + ADMIN_MENU


def menu():
    while True:
        print(f"\nVPS Foundation {VERSION}")
        for index, (label, _) in enumerate(MENU, 1):
            if index == 1:
                print("Настройка")
            if index == len(SETUP_MENU) + 1:
                print("Проверка и обслуживание")
            print(f"{index:2d}  {label}")
        print(" 0  Выход")
        default = next(index for index, (_, option) in enumerate(MENU, 1) if option == "--status")
        choice = number("Действие", default, 0, len(MENU))
        if not choice:
            return
        option = MENU[choice - 1][1]
        if option == "--rollback" and tty_prompt("Для отката введите ROLLBACK") != "ROLLBACK":
            continue
        run(sys.executable, Path(__file__).resolve(), option, check=False, timeout=None)
        tty_prompt("ENTER — меню")


def os_release():
    release = {}
    for line in Path("/etc/os-release").read_text().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields = shlex.split(value)
            if fields:
                release[key] = fields[0]
    if release.get("ID") not in ("debian", "ubuntu") or not Path("/run/systemd/system").is_dir():
        raise InstallError("Нужна Debian или Ubuntu, загруженная с systemd.")
    return release


def expired_rollback():
    if not ACTIVE.exists():
        return
    try:
        with lock():
            if ACTIVE.exists():
                state = load(ACTIVE)
                if committed(state) or time.time() >= state["deadline"]:
                    rollback(state)
    except InstallError as exc:
        # systemd's timer calls again even if another operation holds the lock.
        print(exc, file=sys.stderr)
        return 1


def exit_on_signal(signum, _frame):
    # A second signal can terminate a hung recovery, and the timer then retries.
    signal.signal(signum, signal.SIG_DFL)
    raise KeyboardInterrupt


def main(argv=None):
    parser = argparse.ArgumentParser(description=f"VPS Foundation {VERSION} для Debian/Ubuntu.")
    parser.add_argument("--version", action="version", version=VERSION)
    group = parser.add_mutually_exclusive_group()
    options = {option[2:]: label for label, option in MENU}
    options.update({"menu": "Открыть меню", "ssh-setup": "Продолжить настройку SSH",
                    "rollback-tcp": "Откатить настройки TCP"})
    for mode, label in options.items():
        group.add_argument("--" + mode, dest="mode", action="store_const", const=mode, help=label)
    group.add_argument("--confirm", metavar="КОД", help="Подтвердить перенос SSH из другой сессии")
    group.add_argument("--rollback-bans", metavar="КАТАЛОГ", help="Восстановить конфигурацию Fail2ban из копии")
    internal = ("rollback-if-expired", "firewall-check", "firewall-guard", "clean-cowrie", "prune-logs")
    for mode in internal:
        group.add_argument("--" + mode, dest="mode", action="store_const", const=mode, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    os.umask(0o077)
    os.environ["PATH"] = "/usr/sbin:/usr/bin:/sbin:/bin"
    for sig in (signal.SIGHUP, signal.SIGTERM):
        signal.signal(sig, exit_on_signal)
    if args.mode == "prune-logs":
        if os.geteuid() != pwd.getpwnam("vps-cowrie").pw_uid:
            raise InstallError("Очистка запускается пользователем vps-cowrie.")
        prune_logs()
        return 0
    if os.geteuid() != 0:
        raise InstallError("Запустите с sudo или из root-сессии.")
    release = os_release()
    readonly = {None: menu, "menu": menu, "status": status, "settings": lambda: print_settings(confirmed_settings()),
                "check": health, "logs": logs, "firewall-check": verify_firewall,
                "firewall-guard": guard_firewall, "clean-cowrie": clean_cowrie}
    if args.confirm is None and args.rollback_bans is None and args.mode in readonly:
        readonly[args.mode]()
        return 0
    state_ready()
    if args.mode == "rollback-if-expired":
        return expired_rollback() or 0
    actions = {
        "install": lambda: install(release), "resume-ssh": lambda: install(release, resume=True),
        "setup-ssh": lambda: install(release, ssh_only=True), "setup-cowrie": setup_cowrie,
        "setup-ports": setup_ports, "setup-swap": setup_swap, "setup-time": setup_time,
        "setup-tcp": setup_tcp, "setup-xanmod": lambda: setup_xanmod(release), "upgrade-system": upgrade_system,
        "ssh-setup": lambda: install(release, resume=True), "finalize": finalize, "rollback": rollback_now,
        "rollback-tcp": rollback_network, "setup-maintenance": maintenance, "configure-bans": change_bans,
        "disable-bans": lambda: change_bans(disable=True), "unban": unban,
    }
    with lock():
        if args.confirm is not None:
            confirm(args.confirm)
        elif args.rollback_bans is not None:
            rollback_bans(args.rollback_bans)
        else:
            if (args.mode in {flag[2:] for _, flag in SETUP_MENU} and ACTIVE.exists()
                    and not committed(load(ACTIVE))):
                raise InstallError("Завершите текущую транзакцию через --finalize, --confirm или --rollback.")
            actions[args.mode]()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit("Операция прервана.")
    except (InstallError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        sys.exit(f"Ошибка: {error}")
