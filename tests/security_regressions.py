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
