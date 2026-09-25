/* Slime OS — recovery PIN check
 *
 * Verifies a PIN against slime-recovery's real system password (never a
 * stored copy), the same property lock.sh's old `su -c true slime-recovery`
 * had. The difference is this skips PAM entirely: pam_unix.so enforces a
 * hardcoded 2-second minimum delay via pam_fail_delay() on every attempt,
 * success or failure, meant for network-facing logins, not a rate-limited
 * local PIN (lock.sh already does its own 5-free-attempts-then-backoff).
 * On the AMD box (old FX-6100) that floor plus yescrypt's own cost made a
 * correct PIN take 3-5s end to end (github.com/mulai/slimeos#33). This
 * binary does only the crypt(3) comparison PAM would have done, so the
 * remaining cost is just that hash computation.
 *
 * Root-only (must read /etc/shadow): installed 700 root:root, run via the
 * scoped `sudo -n` grant in install.sh section 3f — never setuid, so it
 * only runs when a real sudoers rule allows it, same posture as
 * remote-support-toggle.sh and apply-update-helper.sh.
 *
 * The PIN is read from stdin (never argv, which any local user can see in
 * the process list) and is wiped from memory before exit. Never logs
 * anything: a wrong PIN here isn't a security event lock.sh needs to know
 * beyond pass/fail, and this binary must not become a place the PIN could
 * leak to disk.
 *
 * Exit 0 = PIN matches. Exit 1 = wrong PIN, bad input, or any error —
 * lock.sh's caller (`sudo -n recovery-pin-check`) only checks $?, same as
 * it checked `su`'s exit code before.
 */
#define _GNU_SOURCE
#include <shadow.h>
#include <crypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PIN_MAX 16

static void wipe(void *s, size_t n) {
    explicit_bzero(s, n);
}

int main(void) {
    char pin[PIN_MAX + 2] = {0}; /* +1 for a trailing newline, +1 for NUL */
    ssize_t n = read(STDIN_FILENO, pin, sizeof(pin) - 1);
    if (n < 0) return 1;
    pin[n] = '\0';
    size_t len = strcspn(pin, "\r\n");
    pin[len] = '\0';

    /* Same shape lock.sh already required before it would even try su:
     * 4-16 digits. Reject anything else without touching crypt/shadow. */
    if (len < 4 || len > PIN_MAX) { wipe(pin, sizeof(pin)); return 1; }
    for (size_t i = 0; i < len; i++) {
        if (pin[i] < '0' || pin[i] > '9') { wipe(pin, sizeof(pin)); return 1; }
    }

    struct spwd *sp = getspnam("slime-recovery");
    if (!sp || !sp->sp_pwdp || sp->sp_pwdp[0] == '!' || sp->sp_pwdp[0] == '*') {
        wipe(pin, sizeof(pin));
        return 1; /* no account, or a locked/disabled hash */
    }

    struct crypt_data data;
    memset(&data, 0, sizeof(data));
    char *hash = crypt_r(pin, sp->sp_pwdp, &data);
    wipe(pin, sizeof(pin));
    if (!hash) return 1;

    /* Constant-time compare: this check is already rate-limited by lock.sh,
     * but there's no reason to leak timing here either. */
    size_t hlen = strlen(hash), elen = strlen(sp->sp_pwdp);
    volatile unsigned char diff = (unsigned char)(hlen != elen);
    size_t cmplen = hlen < elen ? hlen : elen;
    for (size_t i = 0; i < cmplen; i++) {
        diff |= (unsigned char)(hash[i] ^ sp->sp_pwdp[i]);
    }
    wipe(&data, sizeof(data));
    return diff ? 1 : 0;
}
