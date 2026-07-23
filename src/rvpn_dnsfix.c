/* rvpn_dnsfix.c — LD_PRELOAD shim that short-circuits reverse DNS of private
 * IPv4 at the glibc layer, for the Wine process tree that runs Radmin's service.
 *
 * Issue #16, the real one: Radmin reverse-resolves each local candidate address
 * (e.g. docker0's 172.17.0.1) with a PTR lookup. On a host whose resolver black-
 * holes RFC1918 PTR queries — systemd-resolved forwarding upstream where nothing
 * answers — that lookup blocks ~5s per attempt and retries for over two minutes,
 * past Radmin's ready deadline: "registered but never ready".
 *
 * The call is issued by Wine's *Unix side* (ws2_32.so -> glibc getnameinfo), so
 * no in-process PE/IAT/EAT hook from the injected adapter_hook.dll can see it —
 * verified: hooking getnameinfo's IAT in every module, its ws2_32 export table,
 * and its entry via an inline detour all install correctly yet never fire for
 * 172.17.0.1. Interposing glibc getnameinfo with LD_PRELOAD catches it at exactly
 * the layer where it happens, for every caller in the process, and touches no
 * system file — it lives and dies with this launch only.
 *
 * For private/link-local/CGNAT/loopback IPv4 we return the numeric host + port
 * immediately (as NI_NUMERICHOST would). Radmin only uses these addresses
 * numerically, so it is lossless. Public addresses fall through to the real libc
 * function untouched. Build: gcc -shared -fPIC -O2 -o rvpn_dnsfix.so rvpn_dnsfix.c -ldl
 */
#define _GNU_SOURCE
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>

/* host-order IPv4 range test — same set as adapter_hook.c's is_private_v4_host */
static int dnsfix_is_private_v4(uint32_t h)
{
    if ((h & 0xFF000000u) == 0x7F000000u) return 1;   /* 127.0.0.0/8   loopback */
    if ((h & 0xFF000000u) == 0x0A000000u) return 1;   /* 10.0.0.0/8             */
    if ((h & 0xFFF00000u) == 0xAC100000u) return 1;   /* 172.16.0.0/12          */
    if ((h & 0xFFFF0000u) == 0xC0A80000u) return 1;   /* 192.168.0.0/16         */
    if ((h & 0xFFFF0000u) == 0xA9FE0000u) return 1;   /* 169.254.0.0/16  APIPA  */
    if ((h & 0xFFC00000u) == 0x64400000u) return 1;   /* 100.64.0.0/10   CGNAT  */
    return 0;
}

int getnameinfo(const struct sockaddr *sa, socklen_t salen,
                char *host, socklen_t hostlen,
                char *serv, socklen_t servlen, int flags)
{
    if (sa && sa->sa_family == AF_INET &&
        salen >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *si = (const struct sockaddr_in *)sa;
        if (dnsfix_is_private_v4(ntohl(si->sin_addr.s_addr))) {
            if (host && hostlen)
                inet_ntop(AF_INET, &si->sin_addr, host, hostlen);
            if (serv && servlen)
                snprintf(serv, servlen, "%u", (unsigned)ntohs(si->sin_port));
            return 0;
        }
    }
    static int (*real)(const struct sockaddr *, socklen_t, char *, socklen_t,
                       char *, socklen_t, int) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "getnameinfo");
    return real ? real(sa, salen, host, hostlen, serv, servlen, flags) : EAI_FAIL;
}

/* Same short-circuit for the classic reverse resolver, in case any path uses it. */
struct hostent *gethostbyaddr(const void *addr, socklen_t len, int type)
{
    if (addr && type == AF_INET && len == 4) {
        uint32_t net;
        memcpy(&net, addr, 4);
        if (dnsfix_is_private_v4(ntohl(net))) {
            h_errno = HOST_NOT_FOUND;
            return NULL;
        }
    }
    static struct hostent *(*real)(const void *, socklen_t, int) = NULL;
    if (!real) real = dlsym(RTLD_NEXT, "gethostbyaddr");
    return real ? real(addr, len, type) : NULL;
}
