"""Exercise isolated Bash helpers; never source the privileged setup entrypoint."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "setup.sh").read_text(encoding="utf-8")
BASH = os.environ.get("TEST_BASH") or shutil.which("bash")


def helper(name):
    match = re.search(
        rf"^{name}\(\) \{{\n.*?^\}}(?=\n\n(?:[a-z_]+\(\) \{{|main ))",
        SOURCE, re.M | re.S,
    )
    if not match:
        raise AssertionError(f"Missing helper: {name}")
    return match.group()


def bash(script, *args, check=True):
    if os.environ.get("TEST_BASH_TRACE"):
        script = "set -x\n" + script
    env = os.environ.copy()
    # MSYS otherwise silently copies files instead of creating real symlinks.
    env["MSYS"] = (env.get("MSYS", "") + " winsymlinks:nativestrict").strip()
    result = subprocess.run(
        [BASH, "--noprofile", "--norc", "-s", "--", *map(str, args)],
        input=script, text=True, capture_output=True, env=env,
    )
    if check and result.returncode:
        raise AssertionError(f"Bash exited {result.returncode}:\n{result.stdout}\n{result.stderr}")
    return result


class KeyBoundaryTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
                         "Real runuser boundary requires Linux root in a disposable environment")
    def test_real_unprivileged_user_cannot_modify_root_file(self):
        import pwd
        try:
            account = pwd.getpwnam("nobody")
        except KeyError:
            self.skipTest("No existing nobody account")
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            work.chmod(0o755)
            home = work / "home"
            home.mkdir()
            os.chown(home, account.pw_uid, account.pw_gid)
            home.chmod(0o700)
            script = helper("add_user_ssh_key") + '\nRUN_ID=test\nadd_user_ssh_key "$1" "$2" "$3"\n'
            bash(script, account.pw_name, home, "ssh-ed25519 NEW")
            key = home / ".ssh" / "authorized_keys"
            self.assertEqual(key.stat().st_uid, account.pw_uid)
            sentinel = work / "root-file"
            sentinel.write_text("sentinel")
            sentinel.chmod(0o600)
            key.unlink()
            key.symlink_to(sentinel)
            result = bash(script, account.pw_name, home, "BAD", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.stat().st_uid, 0)
            self.assertEqual(sentinel.read_text(), "sentinel")

    def key_script(self):
        # runuser is replaced only to run the unprivileged body as this test user.
        # Assert its exact argument boundary before passing the body to Bash.
        return helper("add_user_ssh_key") + r'''
set -euo pipefail
RUN_ID=test
runuser() {
    [[ $1 == -u && $2 == test-user && $3 == -- ]] || return 90
    shift 3
    "$@"
}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/home"
'''

    def test_key_write_preserves_existing_and_avoids_duplicates(self):
        bash(self.key_script() + r'''
add_user_ssh_key test-user "$work/home" 'ssh-ed25519 NEW'
printf 'ssh-ed25519 OLD' > "$work/home/.ssh/authorized_keys"
add_user_ssh_key test-user "$work/home" 'ssh-ed25519 NEW'
add_user_ssh_key test-user "$work/home" 'ssh-ed25519 NEW'
[[ $(grep -cx 'ssh-ed25519 NEW' "$work/home/.ssh/authorized_keys") == 1 ]]
grep -qx 'ssh-ed25519 OLD' "$work/home/.ssh/authorized_keys"
''')

    def test_symlinks_do_not_write_outside_home(self):
        result = bash(self.key_script() + r'''
printf sentinel > "$work/sentinel"
mkdir "$work/home/.ssh"
ln -s "$work/sentinel" "$work/home/.ssh/authorized_keys" || exit 77
[[ -L "$work/home/.ssh/authorized_keys" ]] || exit 94
if add_user_ssh_key test-user "$work/home" BAD; then exit 91; fi
[[ $(cat "$work/sentinel") == sentinel ]]
rm -rf "$work/home/.ssh"
mkdir "$work/elsewhere"
ln -s "$work/elsewhere" "$work/home/.ssh"
if add_user_ssh_key test-user "$work/home" BAD; then exit 93; fi
[[ ! -e "$work/elsewhere/authorized_keys" ]]
''', check=False)
        if result.returncode == 77:
            self.skipTest("Host does not permit real symlinks; run this test on Linux")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_hardlinked_key_is_rejected(self):
        bash(self.key_script() + r'''
mkdir "$work/home/.ssh"
printf sentinel > "$work/sentinel"
ln "$work/sentinel" "$work/home/.ssh/authorized_keys"
if add_user_ssh_key test-user "$work/home" BAD; then exit 92; fi
[[ $(cat "$work/sentinel") == sentinel ]]
''')

    def test_root_rollback_does_not_restore_user_home(self):
        self.assertNotIn("ssh_user_dir", SOURCE)
        self.assertNotIn('chown "$user_uid:$user_gid"', SOURCE)


class AuthenticationTests(unittest.TestCase):
    def audit_config(self, files):
        source = helper("check_ssh_password_overrides")
        program = source.split("<<'POLICY_PY'\n", 1)[1].split("\nPOLICY_PY", 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            return subprocess.run(
                [sys.executable, "-c", program, str(root / "sshd_config"), str(root)],
                capture_output=True, text=True,
            )

    def test_nested_match_password_and_keyboard_overrides_rejected(self):
        for directive in ("PasswordAuthentication yes", "KbdInteractiveAuthentication yes",
                          "ChallengeResponseAuthentication yes", "PasswordAuthentication=yes"):
            with self.subTest(directive=directive):
                result = self.audit_config({
                    "sshd_config": 'Include "parts/*.conf"\n',
                    "parts/10.conf": 'mAtCh User other\nInclude nested.conf\n',
                    "nested.conf": directive + "\n",
                })
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Conditional password", result.stderr)

    def test_global_old_values_and_safe_match_are_allowed(self):
        result = self.audit_config({
            "sshd_config": 'PasswordAuthentication yes\nInclude=parts/*.conf\n',
            "parts/10.conf": 'Match User sftp\nForceCommand internal-sftp\nPasswordAuthentication no\n',
        })
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_include_cycle_and_unsupported_expansion_fail_closed(self):
        for content in ("Include sshd_config\n", "Include %u.conf\n", 'Include "unterminated\n',
                        'Include "parts/back\\slash.conf"\n'):
            with self.subTest(content=content):
                self.assertNotEqual(self.audit_config({"sshd_config": content}).returncode, 0)

    def test_effective_policy_is_required(self):
        bash(helper("assert_password_auth_disabled") + r'''
set -euo pipefail
sshd() { printf '%s\n' "$POLICY"; }
check_ssh_password_overrides() { [[ $SCANNER_OK == 1 ]]; }
SCANNER_OK=1
POLICY=$'pubkeyauthentication yes\npasswordauthentication no\nkbdinteractiveauthentication no'
assert_password_auth_disabled
for POLICY in \
    $'pubkeyauthentication yes\npasswordauthentication yes\nkbdinteractiveauthentication no' \
    $'pubkeyauthentication yes\npasswordauthentication no\nkbdinteractiveauthentication yes' \
    $'pubkeyauthentication no\npasswordauthentication no\nkbdinteractiveauthentication no'; do
    if assert_password_auth_disabled; then exit 31; fi
done
POLICY=$'pubkeyauthentication yes\npasswordauthentication no\nkbdinteractiveauthentication no'
SCANNER_OK=0
if assert_password_auth_disabled; then exit 32; fi
''')

    def test_socket_mode_restarts_master_without_losing_activation_fds(self):
        bash(helper("assert_ssh_service_preserves_sessions") + '\n' + helper("reload_ssh") + r'''
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
TRACE="$work/trace"
ssh_service_name() { echo ssh.service; }
assert_effective_ssh_socket_endpoints() { return 0; }
systemctl() {
    printf '%s\n' "$*" >> "$TRACE"
    case $1 in
        show) echo "$KILL_MODE" ;;
        is-active) [[ $ACTIVE == 1 ]] ;;
        stop|restart|start) [[ $* != "$FAIL_COMMAND" ]] ;;
    esac
}
KILL_MODE=process ACTIVE=1 FAIL_COMMAND=''
SSH_SOCKET_MODE=1 SSH_CHANGE_PORT=0
reload_ssh
grep -q '^stop ssh.socket ssh.service$' "$TRACE"
grep -q '^start ssh.socket$' "$TRACE"
grep -q '^start ssh.service$' "$TRACE"
! grep -q '^reload ssh.service$' "$TRACE"
: > "$TRACE"
SSH_CHANGE_PORT=1
reload_ssh
[[ $(grep -E '^(stop|restart|start) ' "$TRACE") == $'stop ssh.socket ssh.service\nstart ssh.socket\nstart ssh.service' ]]
: > "$TRACE"
SSH_CHANGE_PORT=0
reload_ssh restore
grep -q '^start ssh.socket$' "$TRACE"
ACTIVE=0
: > "$TRACE"
reload_ssh
! grep -q '^start ssh.service$' "$TRACE"
SSH_SOCKET_SERVICE_WAS_ACTIVE=1
reload_ssh restore
grep -q '^start ssh.service$' "$TRACE"
SSH_SOCKET_SERVICE_WAS_ACTIVE=0 ACTIVE=1
: > "$TRACE"
reload_ssh restore
grep -q '^stop ssh.socket ssh.service$' "$TRACE"
! grep -q '^start ssh.service$' "$TRACE"
ACTIVE=1 SSH_CHANGE_PORT=1
for FAIL_COMMAND in 'stop ssh.socket ssh.service' 'start ssh.socket' 'start ssh.service'; do
    if reload_ssh; then exit 41; fi
done
FAIL_COMMAND='' KILL_MODE=control-group
: > "$TRACE"
if reload_ssh; then exit 42; fi
! grep -qE '^(stop|restart|start) ' "$TRACE"
''')

    def test_global_policy_precedes_old_settings_and_is_idempotent(self):
        bash(helper("set_ssh_global_key_only") + r'''
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
RUNTIME_DIR="$work"
config="$work/sshd_config"
printf 'PasswordAuthentication yes\nInclude conf.d/*.conf\n' > "$config"
write_file_if_changed() { cat > "$1"; }
set_ssh_global_key_only "$config"
set_ssh_global_key_only "$config"
[[ $(grep -c '^# BEGIN VPS SETUP KEY-ONLY AUTH$' "$config") == 1 ]]
[[ $(awk '$1 == "PasswordAuthentication" {print $2; exit}' "$config") == no ]]
grep -qx 'Include conf.d/\*.conf' "$config"
''')


class ListenerTests(unittest.TestCase):
    def endpoint_helpers(self):
        return "\n".join(helper(n) for n in (
            "valid_port", "validate_ssh_endpoint", "read_ssh_config_endpoints",
            "read_ssh_socket_endpoints", "ssh_endpoints_for_ports",
            "assert_effective_ssh_endpoints", "assert_effective_ssh_socket_endpoints",
            "make_ssh_socket_dropin", "capture_ssh_listener_state",
            "assert_ssh_service_preserves_sessions",
        ))

    def test_ipv4_ipv6_and_distinct_port_scopes(self):
        bash(self.endpoint_helpers() + r'''
set -euo pipefail
read_ssh_config_endpoints $'port 22\nlistenaddress 10.0.0.5:22\nlistenaddress [fd00::5]:2222'
SSH_CHANGE_PORT=1 SSH_NEW_PORT=3333
actual=$(ssh_endpoints_for_ports SSH_CONFIG_ENDPOINTS 22 2222 3333)
expected=$(printf '%s\n' '10.0.0.5:22' '10.0.0.5:3333' '[fd00::5]:2222' '[fd00::5]:3333' | sort -u)
[[ $actual == "$expected" ]]
SSH_CHANGE_PORT=0
actual=$(ssh_endpoints_for_ports SSH_CONFIG_ENDPOINTS 22 2222)
expected=$(printf '%s\n' '10.0.0.5:22' '[fd00::5]:2222' | sort -u)
[[ $actual == "$expected" ]]
SSH_CHANGE_PORT=1
sshd() { printf 'listenaddress 0.0.0.0:3333\n'; }
if assert_effective_ssh_endpoints 3333; then exit 21; fi
sshd() { printf 'listenaddress 10.0.0.5:3333\nlistenaddress [fd00::5]:3333\n'; }
assert_effective_ssh_endpoints 3333
''')

    def test_socket_scope_and_key_only_no_rewrite(self):
        bash(self.endpoint_helpers() + r'''
set -euo pipefail
systemctl() { printf '%s\n' "$SOCKETS"; }
SOCKETS='127.0.0.1:22 (Stream) [::1]:2222 (Stream)'
read_ssh_socket_endpoints
SSH_SOCKET_MODE=1 SSH_CHANGE_PORT=0
write_file_if_changed() { echo unexpected-write >&2; return 99; }
make_ssh_socket_dropin 22 2222
SSH_CHANGE_PORT=1 SSH_NEW_PORT=3333
write_file_if_changed() { cat; }
config=$(make_ssh_socket_dropin 22 2222 3333)
[[ $config == *'ListenStream=127.0.0.1:3333'* ]]
[[ $config == *'ListenStream=[::1]:3333'* ]]
[[ $config != *'ListenStream=3333'* ]]
SSH_PENDING_PORTS=(3333)
SOCKETS='127.0.0.1:3333 (Stream) [::1]:3333 (Stream)'
assert_effective_ssh_socket_endpoints
SOCKETS='0.0.0.0:3333 (Stream)'
if assert_effective_ssh_socket_endpoints; then exit 22; fi
SOCKETS='/run/custom.sock (Stream)'
if read_ssh_socket_endpoints; then exit 23; fi
SOCKETS='127.0.0.1:3333 (Datagram)'
if read_ssh_socket_endpoints; then exit 24; fi
''')

    def test_private_bind_health_probe(self):
        bash(helper("port_speaks_ssh") + r'''
set -euo pipefail
ss() { echo 'LISTEN 0 128 10.0.0.5:2222 0.0.0.0:*'; }
ssh-keyscan() {
    [[ ${@: -1} == 10.0.0.5 ]] || return 81
    echo '10.0.0.5 ssh-ed25519 AAAA'
}
port_speaks_ssh 2222
''')

    def test_enabled_but_inactive_socket_cannot_replace_service_scope(self):
        bash(self.endpoint_helpers() + r'''
set -euo pipefail
sshd() { echo 'listenaddress 127.0.0.1:22'; }
systemctl() {
    case $1 in
        is-active) return 1 ;;
        is-enabled) return 0 ;;
        *) echo 'Dormant socket must not be read or activated' >&2; return 91 ;;
    esac
}
capture_ssh_listener_state
[[ $SSH_SOCKET_MODE == 0 ]]
[[ ${SSH_CONFIG_ENDPOINTS[0]} == 127.0.0.1:22 ]]
''')

    def test_socket_preflight_rejects_unsafe_service_kill_mode(self):
        bash(self.endpoint_helpers() + r'''
set -euo pipefail
sshd() { echo 'listenaddress 127.0.0.1:22'; }
ssh_service_name() { echo ssh.service; }
systemctl() {
    case $1 in
        is-active) return 0 ;;
        show)
            [[ $* == *'--property=KillMode'* ]] || return 91
            echo control-group ;;
        *) return 92 ;;
    esac
}
if capture_ssh_listener_state; then exit 93; fi
''')


class FirewallTests(unittest.TestCase):
    def test_ssh_only_verifier_rejects_previous_and_routed_rules(self):
        bash(helper("ufw_user_rules_are_ssh_only") + r'''
set -euo pipefail
ufw() { printf '%s\n' 'Added user rules:' "$RULES"; }
RULES=$'ufw allow 22/tcp\nufw allow 2222/tcp'
ufw_user_rules_are_ssh_only 22 2222
RULES+=$'\nufw allow 443/tcp'
if ufw_user_rules_are_ssh_only 22 2222; then exit 11; fi
RULES=$'ufw allow 22/tcp\nufw route allow in on tun0'
if ufw_user_rules_are_ssh_only 22; then exit 12; fi
''')

    def test_preserve_replace_and_failure_restore(self):
        script = "\n".join(helper(n) for n in (
            "configure_ufw", "restore_ufw_state", "ufw_user_rules_are_ssh_only", "join_by"
        )) + r'''
set -euo pipefail
CHANGES=()
info() { :; }; warn() { :; }; install_packages() { :; }
backup_file() { :; }; snapshot_path() { printf 'snapshot %s\n' "$1" >> "$TRACE"; }
restore_snapshot() { printf 'restore %s\n' "$1" >> "$TRACE"; }
get_active_ssh_ports_for_rules() { echo 22; }
ufw_is_active() { [[ $ACTIVE == 1 ]]; }
ufw_has_explicit_port() { return 0; }
ask_yes_no() {
    if [[ $1 == Replace* ]]; then [[ $REPLACE == 1 ]]; else return 0; fi
}
ufw() {
    printf 'ufw %s\n' "$*" >> "$TRACE"
    if [[ $* == 'show added' ]]; then
        echo 'ufw allow 22/tcp'
    elif [[ $* == 'default allow outgoing' && $FAIL == 1 ]]; then
        return 1
    fi
}
die() { echo "$*" >&2; exit 73; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
TRACE="$work/trace"
REPLACE=0 ACTIVE=1 FAIL=0
configure_ufw
! grep -q 'ufw --force reset' "$TRACE"
[[ $UFW_RULE_MODE == *preserved* ]]
REPLACE=1
: > "$TRACE"
configure_ufw
grep -q 'ufw --force reset' "$TRACE"
grep -q 'ufw default deny routed' "$TRACE"
[[ $UFW_RULE_MODE == *SSH-only* ]]
for ACTIVE in 0 1; do
    FAIL=1
    : > "$TRACE"
    if (configure_ufw); then exit 14; fi
    grep -q 'restore ufw_config_dir' "$TRACE"
    grep -q 'restore ufw_defaults' "$TRACE"
    if [[ $ACTIVE == 1 ]]; then
        grep -q 'ufw reload' "$TRACE"
    else
        grep -q 'ufw --force disable' "$TRACE"
    fi
done
'''
        bash(script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
