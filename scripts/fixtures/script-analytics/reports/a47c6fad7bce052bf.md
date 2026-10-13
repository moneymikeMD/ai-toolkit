Re-check of commit 333607a, script <worktree>/scripts/host/pve-node-rename.sh. Selftest `pve-node-rename-selftest.sh`: all passed (clean env). No CRITICAL/HIGH found.

F1 FIXED. `m_files` (lines 229-266) writes hostname at 256, then runs `m_precheck` (260), including `ifreload --syntax-check` (277). On failure it runs `restore_copy` on hosts, hostname, interfaces and main.cf (261), and the `.pre-rename` copies are taken first by `keep_once` (233). So /etc/hostname returns to the old name and the next run sees PHASE=pre.
- Demo: I removed the restore loop in a scratch copy. The selftest then failed "hostname restored", "hosts restored byte-identical" and "re-run after a rolled-back edit starts from the top". The unmutated script passes them (selftest lines 343-350 use `ifreload.rc`=1).

F2 FIXED.
- Edits are staged in `mktemp -d` and `[ -s ]` is checked on each staged file (248-250).
- The staging-dir creation is checked (232).
- Staged hosts must contain the new-address line and staged interfaces the new address (251-254), all before the first write at 255.
- pci.cfg and the other mapping `*.cfg` files are staged to `/root/.pve-node-rename-map.$$` with an `-s` check before `cat` (318-320).
- Demo: dropping the `-s` check made the selftest fail "empty staged file named" (selftest 393-395).
- Note: the staged-interfaces assertion (253) is redundant with `m_precheck`. Removing it still passes, because the post-commit precheck rolls back. That is belt-and-braces, not a gap.

F3 FIXED.
- Local range checks at 84-90 reject octets above 255 and first octets 0, 127 and 224-255 (the `case` at 89), plus .0 and .255 hosts.
- Demo: with the range checks removed, the selftest fails "999.1.1.1 refused", "127.0.0.1 refused" and "0.0.0.5 refused".
- An old address missing from interfaces is refused in the pre phase (464-466), covering the Debian 127.0.1.1 case (selftest line 305).
- The new address is asserted in staged interfaces (253) and again in `m_precheck` (275), which rolls back on failure.
- Residual, not HIGH, so not filed as a finding: the regex at 84 accepts leading zeros ("010.1.1.1"), and the value is written verbatim.

F4 FIXED in code, UNPROVEN by test.
- The first probe (420) has no fallback and exits 2 with a message.
- `probe_any` (408-415) is used only after the reboot (560). It skips the new-address fallback when `LAB_SSH_HOST` is set. Reaching the new address is accepted only if the node reports hostname == NEW_NAME and a changed bootid (560).
- No selftest case exercises the fallback or the wrong-host path (no hits in the selftest for LAB_SSH_HOST routing beyond the isolation export).

Dry-run `refuse()` and --yes: unchanged in effect.
- `refuse()` calls `die` immediately when `$YES` is true (389), at the same call sites where `die` was before. Under --yes no plan is printed and nothing is stopped.
- Under --yes the only step line printed before a refusal is the backup-check step at 488, the same as before the change.
- Every converted guard was pre-write, and every write path (531+) is reached only after the `! $YES` exit at 521. No `die` on a write path was converted.

Lint was not re-run in full. This was a scoped re-check.