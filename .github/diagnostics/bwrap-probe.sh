#!/usr/bin/env bash
set -euo pipefail
evidence="$PWD/bwrap-evidence"
mkdir -p "$evidence"
started="$(date --iso-8601=seconds)"
source_dir=packages/device-runtime/src/terminal
test_path="$source_dir/sandbox-confinement.test.ts"
implementation="$source_dir/sandbox-confinement.ts"
sha256sum "$test_path" "$implementation" package-lock.json > "$evidence/source-before.sha256"
git rev-parse HEAD > "$evidence/diagnostic-head.txt"
git show -s --format='%H %P %s' d3c26081c548129f17a6b7c4a51f6a02dd42689c > "$evidence/production-source-base.txt"
cp probe-deps/package-lock.json "$evidence/minimal-dependency-lock.json"
{
  uname -a
  cat /etc/os-release
  node --version
  npm --version
  id
  bwrap --version
  dpkg-query -W bubblewrap apparmor apparmor-profiles libcap2-bin || true
  stat /usr/bin/bwrap
  getcap /usr/bin/bwrap
  capsh --print
  grep -E '^(Uid|Gid|Cap|NoNewPrivs|Seccomp)' /proc/self/status
  cat /proc/self/uid_map /proc/self/gid_map /proc/self/attr/current
  sysctl kernel.unprivileged_userns_clone kernel.apparmor_restrict_unprivileged_userns kernel.apparmor_restrict_unprivileged_unconfined user.max_user_namespaces || true
  sudo aa-status || true
  sudo find /etc/apparmor.d -maxdepth 2 -iname '*bwrap*' -print -exec cat '{}' \; || true
} > "$evidence/environment-original.txt" 2>&1
sudo cat /sys/kernel/security/apparmor/profiles > "$evidence/loaded-profiles-before.txt" 2>&1 || true
command -v /usr/bin/bwrap > "$evidence/bwrap-path.txt"
run_test() {
  local label="$1" path="$2"
  set +e
  node --import tsx --test "$path" > "$evidence/$label.log" 2>&1
  local result=$?
  set -e
  printf '%s\n' "$result" > "$evidence/$label.exit"
  cat "$evidence/$label.log"
}
# Original source and original assertions are never edited.
run_test original "$test_path"

# One private implementation-only contrast: explicitly request user namespace.
# Network, process, mount isolation and the original test assertions stay intact.
mkdir -p private-userns
cp "$test_path" "$implementation" "$source_dir/types.ts" private-userns/
node --input-type=module <<'NODE'
import {readFileSync,writeFileSync} from 'node:fs';
const path='private-userns/sandbox-confinement.ts';
const source=readFileSync(path,'utf8');
const needle='const args: string[] = []';
if(source.split(needle).length!==2) throw new Error('Expected exactly one private-copy edit');
writeFileSync(path,source.replace(needle,'const args: string[] = ["--unshare-user"]'));
NODE
cmp "$test_path" private-userns/sandbox-confinement.test.ts
diff -u "$implementation" private-userns/sandbox-confinement.ts > "$evidence/private-userns.diff" || test "$?" = 1
run_test explicit-userns private-userns/sandbox-confinement.test.ts

# Third control uses only a profile shipped by the distro, if available.
# No custom profile and no global AppArmor/sysctl relaxation is introduced.
set +e
sudo apt-get install --yes --no-install-recommends apparmor-profiles > "$evidence/profile-package-install.log" 2>&1
package_exit=$?
set -e
printf '%s\n' "$package_exit" > "$evidence/profile-package-install.exit"
dpkg -L apparmor-profiles > "$evidence/profile-package-files.txt" 2>&1 || true
dpkg-query -W apparmor apparmor-profiles > "$evidence/profile-package-versions.txt" 2>&1 || true
mapfile -t profiles < <(grep '/bwrap-userns-restrict$' "$evidence/profile-package-files.txt" || true)
if test "$package_exit" = 0 && test "${#profiles[@]}" = 1 && test -f "${profiles[0]}" && ! grep -Eq '(^|[/ ])(bwrap|unpriv_bwrap)' "$evidence/loaded-profiles-before.txt"; then
  profile="${profiles[0]}"
  dpkg -S "$profile" > "$evidence/profile-owner.txt"
  sha256sum "$profile" > "$evidence/distro-profile.sha256"
  cp "$profile" "$evidence/distro-bwrap-profile.txt"
  set +e
  sudo apparmor_parser -r "$profile" > "$evidence/profile-load.log" 2>&1
  profile_exit=$?
  set -e
  printf '%s\n' "$profile_exit" > "$evidence/profile-load.exit"
  if test "$profile_exit" = 0; then
    run_test distro-profile "$test_path"
  else
    printf 'Profile failed to load; original test was not rerun under an unverified profile.\n' > "$evidence/distro-profile-unavailable.txt"
  fi
  sha256sum --check "$evidence/distro-profile.sha256" > "$evidence/profile-unchanged.log"
else
  printf 'No unambiguous distro-owned profile, or a bwrap profile was already attached. No profile invented or existing attachment overwritten.\n' > "$evidence/distro-profile-unavailable.txt"
fi
{
  sudo aa-status || true
  sysctl kernel.apparmor_restrict_unprivileged_userns || true
} > "$evidence/environment-after-profile.txt" 2>&1
set +e
sudo journalctl -k --since "$started" --no-pager | grep -Ei 'apparmor|DENIED|bwrap|userns' > "$evidence/relevant-kernel-audit.log"
printf '%s\n' "${PIPESTATUS[*]}" > "$evidence/kernel-audit-pipeline.exit"
set -e
sha256sum --check "$evidence/source-before.sha256" > "$evidence/source-unchanged.log"
git diff --exit-code -- "$test_path" "$implementation" package-lock.json
# A private contrast succeeding never turns the original failure green.
exit "$(cat "$evidence/original.exit")"
