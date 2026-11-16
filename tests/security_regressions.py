"""Exercise isolated Bash helpers; never source the privileged setup entrypoint."""
import os
from pathlib import Path
import re
import shutil
import subprocess
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


class ListenerTests(unittest.TestCase):
    def endpoint_helpers(self):
        return "\n".join(helper(n) for n in (
            "valid_port", "validate_ssh_endpoint", "read_ssh_config_endpoints",
            "read_ssh_socket_endpoints", "ssh_endpoints_for_ports",
            "assert_effective_ssh_endpoints", "assert_effective_ssh_socket_endpoints",
            "make_ssh_socket_dropin", "capture_ssh_listener_state",
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
