// SPDX-License-Identifier: MIT
/*
 * tscsync.efi - measure, and optionally repair, per-core TSC offsets before
 * the operating system boots.
 *
 * Some firmware hands over with the cores' Time Stamp Counters out of sync.
 * Linux then measures a "TSC warp between CPUs", marks the TSC unstable and
 * falls back to the much slower HPET clock. CPUs with IA32_TSC_ADJUST let
 * the kernel repair this itself; AMD/Hygon Zen CPUs lack TSC_ADJUST, so the
 * only repair is writing the TSC MSR (0x10) before the kernel's check runs,
 * which is what Windows does at every boot. tscsync does that from GRUB.
 *
 * Modes (GRUB passes them as load options):
 *   mode=measure  (default) read-only: report each AP's offset, write nothing
 *   mode=sync     1. survey all APs (read-only)
 *                 2. if some AP is ahead of the BSP, move the BSP forward to
 *                    match (the median AP when the APs agree, else the
 *                    furthest-ahead AP)
 *                 3. move every AP that still lags forward to match the BSP
 *                    (small backward steps only to fine-tune an overshoot)
 *                 4. verify every AP, including a kernel-style warp test
 *   allow=any-cpu run sync on CPUs outside the supported list (see below)
 *
 * Safety properties:
 *   - Never touches flash, NVRAM, or non-volatile EFI variables. The result
 *     is stored in a volatile variable (RAM only) that Linux can read.
 *   - Writes MSR 0x10 only in sync mode. Large corrections only move a TSC
 *     forward; backward moves are limited to MAX_BACKWARD cycles.
 *   - Acts only when every enabled AP could be measured, and re-measures
 *     before each correction.
 *   - Sync runs only on CPUs with an invariant TSC and without TSC_ADJUST,
 *     and by default only on AMD/Hygon families 17h, 18h, 19h and 1Ah.
 *   - Every wait loop is bounded; APs exit on their own if the BSP goes away.
 *   - Any failure just returns to GRUB, which boots normally.
 *
 * Why the numbers below are what they are: see docs/DESIGN.md.
 */

#include <efi.h>
#include <efilib.h>

#define MSR_TSC			0x10
#define ROUNDS			4000
#define ACT_THRESHOLD		200	/* cycles: survey threshold for "ahead" */
#ifndef TSCSYNC_TEST
#define TOLERANCE		10	/* cycles: target when the tick is 1 */
#else
#define TOLERANCE		100	/* VM test build: KVM TSC writes jitter by 50-200 cycles */
#endif
#ifndef TSCSYNC_TEST
#define NUDGE			8	/* cycles: step when only the warp test fails */
#else
#define NUDGE			50	/* VM test build: matches KVM write jitter */
#endif
/*
 * Verify limit when the tick is 1. On real hardware APs at -18..+12 cycles
 * were always accepted by the kernel and +38..+51 were rejected. Corrections
 * still aim for TOLERANCE; this only keeps pass-to-pass noise from failing
 * verify.
 */
#ifndef TSCSYNC_TEST
#define VERIFY_LIMIT		25
#else
#define VERIFY_LIMIT		300
#endif
#define SPREAD_MAX		(1000000LL)	/* APs "agree" if within this; then use the median AP */
#define MAX_FORWARD		(150000000000LL) /* ~60 s at 2.5 GHz */
#define MAX_BACKWARD		(1000000LL)	/* ~0.4 ms */
#define MAX_ITER		12
#define MAX_CPUS		512
#define MAX_SHORTFALL		5000	/* cycles: sane bound for a write's landing error */
#define WARP_ITERS		20000	/* strictly alternating, so every round is cross-core */
#define AP_IDLE_SPINS		2000000000ULL
#define BSP_SPINS		200000000ULL
#define EDGE_SPINS		1000000ULL
#define AP_TIMEOUT_US		(60 * 1000 * 1000)
#define TSCSYNC_VERSION		u"2.0.0"

#ifdef TSCSYNC_TEST
/* Test build for VMs only: a warp of the size seen on a Legion Pro 5 16ADR10. */
#define TEST_WARP		5690270744LL
static BOOLEAN test_ap_behind;		/* "test=ap-behind": APs set back */
static BOOLEAN test_mixed;		/* "test=mixed": odd APs ahead, even APs behind */
static BOOLEAN test_bsp_loop;		/* default: exercise the BSP correction */
static BOOLEAN test_desynced[MAX_CPUS];
#endif

static EFI_GUID result_guid = { 0x950a48f2, 0xb67d, 0x4798,
	{ 0xa0, 0x24, 0x88, 0xb7, 0xbf, 0x38, 0x60, 0x00 } };
static EFI_GUID mp_guid = EFI_MP_SERVICES_PROTOCOL_GUID;

enum { CMD_NONE, CMD_ADJUST, CMD_WARPTEST, CMD_EXIT };

struct mailbox {
	volatile UINT64 ready __attribute__((aligned(64)));
	volatile UINT64 exited;
	volatile UINT64 req __attribute__((aligned(64)));
	volatile UINT64 ack __attribute__((aligned(64)));
	volatile UINT64 val;		/* same cache line as ack */
	volatile UINT64 cmd_seq __attribute__((aligned(64)));
	volatile UINT64 cmd;
	volatile INT64 delta;
	volatile UINT64 cmd_ack __attribute__((aligned(64)));
};

/*
 * Like the kernel's check_tsc_warp(), but the two cores strictly alternate,
 * so every read is compared against the other core's latest read.
 */
struct warpbox {
	volatile UINT64 turn __attribute__((aligned(64)));	/* 0: BSP, 1: AP */
	volatile UINT64 last;
	volatile UINT64 warps_bsp;	/* BSP read a TSC below the AP's last read */
	volatile UINT64 warps_ap;	/* AP read a TSC below the BSP's last read */
	volatile UINT64 max_warp;
	volatile UINT64 aborted;
};

struct result {
	INT64 off;		/* AP - BSP, quantized to whole ticks */
	UINT64 rtt;
	UINT64 warps_bsp, warps_ap, max_warp;
	BOOLEAN warp_tested;
};

static struct mailbox mb __attribute__((aligned(64)));
static struct warpbox wb __attribute__((aligned(64)));
static UINT64 s_rtt[ROUNDS];
static INT64 s_off2[ROUNDS];
static UINT64 tick = 1;
static EFI_EVENT ap_event[MAX_CPUS];	/* completion event of each AP's last session */
static INT64 bsp_shift;			/* total cycles added to the BSP TSC */
static UINT64 tsc_hz = 2495000000ULL;	/* calibrated in efi_main */
static CHAR16 report[16384];
static UINTN report_len;

#define barrier() __asm__ volatile("" ::: "memory")

static inline UINT64 rdtsc(void)
{
	UINT32 lo, hi;
	__asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi));
	return ((UINT64)hi << 32) | lo;
}

static inline UINT64 rdtscp(void)
{
	UINT32 lo, hi, aux;
	__asm__ volatile("rdtscp" : "=a"(lo), "=d"(hi), "=c"(aux)::"memory");
	return ((UINT64)hi << 32) | lo;
}

static inline void wrmsr(UINT32 msr, UINT64 v)
{
	__asm__ volatile("wrmsr" ::"c"(msr), "a"((UINT32)v), "d"((UINT32)(v >> 32)) : "memory");
}

/*
 * Add delta to this core's TSC. Waiting for a tick edge first makes the
 * delay between the read and the write land at a consistent tick phase.
 */
static inline void adjust_tsc(INT64 delta)
{
	UINT64 t = rdtsc(), n = t, spins = 0;

	while (n == t && ++spins < EDGE_SPINS)
		n = rdtsc();
	wrmsr(MSR_TSC, n + (UINT64)delta);
}

static inline void cpuid(UINT32 leaf, UINT32 sub, UINT32 *a, UINT32 *b, UINT32 *c, UINT32 *d)
{
	__asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d) : "a"(leaf), "c"(sub));
}

static void out(const CHAR16 *fmt, ...)
{
	CHAR16 line[256];
	va_list args;

	va_start(args, fmt);
	UnicodeVSPrint(line, sizeof(line), fmt, args);
	va_end(args);
	Print(u"%s", line);
	for (UINTN i = 0; line[i] && report_len + 1 < sizeof(report) / sizeof(report[0]); i++)
		report[report_len++] = line[i];
	report[report_len] = 0;
}

static INT64 abs64(INT64 v)
{
	return v < 0 ? -v : v;
}

/*
 * Take the newly measured landing error of a write only if it is plausible;
 * otherwise keep the previous estimate, so one disturbed write (for example
 * an interrupt between the read and the write) cannot make the next
 * correction overshoot.
 */
static INT64 update_shortfall(INT64 old, INT64 measured)
{
	return abs64(measured) <= MAX_SHORTFALL ? measured : old;
}

/* Smallest step between distinct TSC reads on the BSP (25 on this CPU). */
static UINT64 detect_tick(void)
{
	UINT64 g = 0, prev = rdtsc();

	for (UINTN i = 0; i < 20000; i++) {
		UINT64 now = rdtsc(), d = now - prev, a = d, b = g;

		prev = now;
		if (!d)
			continue;
		while (b) {
			UINT64 r = a % b;
			a = b;
			b = r;
		}
		g = a;
	}
	return g >= 1 && g <= 1000 ? g : 1;
}

static INT64 quantize(INT64 off)
{
	INT64 t = (INT64)tick, h = t / 2;

	if (t <= 1)
		return off;
	return (off >= 0 ? (off + h) / t : -((-off + h) / t)) * t;
}

static BOOLEAN in_sync(INT64 off_q)
{
	return tick > 1 ? off_q == 0 : abs64(off_q) <= TOLERANCE;
}

static BOOLEAN verify_ok(INT64 off_q)
{
	return tick > 1 ? off_q == 0 : abs64(off_q) <= VERIFY_LIMIT;
}

static void warp_loop(BOOLEAN is_bsp)
{
	UINT64 me = is_bsp ? 0 : 1;

	for (UINTN i = 0; i < WARP_ITERS && !wb.aborted; i++) {
		UINT64 spins = 0;

		while (wb.turn != me) {
			if (wb.aborted || ++spins > BSP_SPINS) {
				wb.aborted = 1;
				return;
			}
		}
		UINT64 prev = wb.last;
		UINT64 now = rdtscp();
		wb.last = now;
		if (prev > now) {
			if (is_bsp)
				wb.warps_bsp++;
			else
				wb.warps_ap++;
			if (prev - now > wb.max_warp)
				wb.max_warp = prev - now;
		}
		barrier();
		wb.turn = 1 - me;
	}
}

/*
 * AP side. Runs on one AP at a time, started non-blocking by MP services.
 * Only touches the mailbox, the warp box and the TSC; it must not call boot
 * services.
 */
static VOID EFIAPI ap_main(VOID *arg)
{
	struct mailbox *m = arg;
	UINT64 seen_req = 0, seen_cmd = 0, idle = 0;

	m->ready = 1;
	for (;;) {
		UINT64 r = m->req;

		if (r != seen_req) {
			m->val = rdtscp();
			barrier();
			m->ack = r;
			seen_req = r;
			idle = 0;
			continue;
		}
		UINT64 c = m->cmd_seq;
		if (c != seen_cmd) {
			seen_cmd = c;
			idle = 0;
			if (m->cmd == CMD_EXIT)
				break;
			if (m->cmd == CMD_ADJUST)
				adjust_tsc(m->delta);
			else if (m->cmd == CMD_WARPTEST)
				warp_loop(FALSE);
			barrier();
			m->cmd_ack = c;
			continue;
		}
		if (++idle > AP_IDLE_SPINS)
			break;	/* BSP went away: give the AP back */
	}
	barrier();
	m->exited = 1;
}

/*
 * Offset estimate = AP TSC - BSP TSC. Averages the fastest round trips,
 * which resolves offsets finer than one tick, then rounds to whole ticks.
 */
static BOOLEAN measure(UINT64 *req, INT64 *off, UINT64 *rtt_out)
{
	UINT64 best = ~0ULL;

	for (UINTN i = 0; i < ROUNDS; i++) {
		UINT64 n = ++*req, spins = 0;
		UINT64 t0 = rdtscp();

		mb.req = n;
		while (mb.ack != n)
			if (++spins > BSP_SPINS)
				return FALSE;
		UINT64 t1 = rdtscp();
		UINT64 a = mb.val;
		s_rtt[i] = t1 - t0;
		s_off2[i] = (INT64)(2 * a - t0 - t1);
		if (s_rtt[i] < best)
			best = s_rtt[i];
	}

	INT64 sum = 0, n = 0;
	for (UINTN pass = 0; pass < 2 && n < 32; pass++) {
		UINT64 limit = best + (pass ? tick : 0);

		sum = n = 0;
		for (UINTN i = 0; i < ROUNDS; i++)
			if (s_rtt[i] <= limit) {
				sum += s_off2[i];
				n++;
			}
	}
	INT64 off2 = n ? sum / n : 0;
	*off = quantize(off2 >= 0 ? (off2 + 1) / 2 : -((-off2 + 1) / 2));
	*rtt_out = best;
	return TRUE;
}

static UINT64 ap_send(UINT64 cmd, INT64 delta)
{
	UINT64 seq = mb.cmd_seq + 1;

	mb.delta = delta;
	mb.cmd = cmd;
	barrier();
	mb.cmd_seq = seq;
	return seq;
}

static BOOLEAN ap_wait(UINT64 seq)
{
	UINT64 spins = 0;

	while (mb.cmd_ack != seq)
		if (++spins > BSP_SPINS)
			return FALSE;
	return TRUE;
}

static BOOLEAN ap_command(UINT64 cmd, INT64 delta)
{
	UINT64 seq = ap_send(cmd, delta), spins = 0;

	if (cmd != CMD_EXIT)
		return ap_wait(seq);
	while (!mb.exited)
		if (++spins > BSP_SPINS)
			return FALSE;
	return TRUE;
}

/* The kernel's check, BSP against the current AP. */
static BOOLEAN warp_test(struct result *r)
{
	ZeroMem((void *)&wb, sizeof(wb));
	barrier();
	UINT64 seq = ap_send(CMD_WARPTEST, 0);
	warp_loop(TRUE);
	BOOLEAN done = ap_wait(seq);

	r->warps_bsp = wb.warps_bsp;
	r->warps_ap = wb.warps_ap;
	r->max_warp = wb.max_warp;
	r->warp_tested = TRUE;
	return done && !wb.aborted;
}

static BOOLEAN warp_clean(const struct result *r)
{
	return r->warp_tested && r->warps_bsp == 0 && r->warps_ap == 0;
}

/*
 * Wait until MP services has marked AP idx idle after its previous session.
 * The event is only closed once signaled: closing it earlier could leave the
 * firmware signaling a freed event. Returns FALSE if the AP is still busy.
 */
static BOOLEAN wait_idle(UINTN idx)
{
	if (idx >= MAX_CPUS || !ap_event[idx])
		return TRUE;
	for (UINTN t = 0; t < 200000; t++) {	/* up to ~2 s */
		if (uefi_call_wrapper(BS->CheckEvent, 1, ap_event[idx]) == EFI_SUCCESS) {
			uefi_call_wrapper(BS->CloseEvent, 1, ap_event[idx]);
			ap_event[idx] = NULL;
			return TRUE;
		}
		uefi_call_wrapper(BS->Stall, 1, 10);
	}
	return FALSE;
}

/*
 * Stop the responder on the current AP. MP services notices the AP is idle
 * on its own timer; that is only waited for when the AP is used again.
 */
static void end_session(UINTN idx)
{
	if (!ap_command(CMD_EXIT, 0))
		out(u"  cpu %lu: AP did not acknowledge exit (it self-exits when idle)\n", (UINT64)idx);
}

/* Start the responder on AP idx; on success the caller must end_session(). */
static BOOLEAN start_session(EFI_MP_SERVICES_PROTOCOL *mp, UINTN idx)
{
	EFI_EVENT ev = NULL;
	EFI_STATUS st;

	if (idx >= MAX_CPUS)
		return FALSE;
	if (!wait_idle(idx)) {
		out(u"  cpu %lu: still busy from its previous session: skipped\n", (UINT64)idx);
		return FALSE;
	}
	ZeroMem((void *)&mb, sizeof(mb));
	st = uefi_call_wrapper(BS->CreateEvent, 5, 0, 0, NULL, NULL, &ev);
	if (EFI_ERROR(st)) {
		out(u"  cpu %lu: CreateEvent failed: %r\n", (UINT64)idx, st);
		return FALSE;
	}
	st = uefi_call_wrapper(mp->StartupThisAP, 7, mp, ap_main, idx, ev,
			       (UINTN)AP_TIMEOUT_US, &mb, NULL);
	if (EFI_ERROR(st)) {
		out(u"  cpu %lu: StartupThisAP failed: %r\n", (UINT64)idx, st);
		uefi_call_wrapper(BS->CloseEvent, 1, ev);
		return FALSE;
	}
	ap_event[idx] = ev;
	for (UINTN t = 0; !mb.ready && t < 100000; t++)	/* up to ~1 s */
		uefi_call_wrapper(BS->Stall, 1, 10);
	if (!mb.ready) {
		out(u"  cpu %lu: AP did not start\n", (UINT64)idx);
		end_session(idx);
		return FALSE;
	}
	return TRUE;
}

/* Milliseconds since t0, not counting cycles deliberately added to the BSP. */
static UINT64 ms_since(UINT64 t0, INT64 shift0)
{
	INT64 d = (INT64)(rdtsc() - t0) - (bsp_shift - shift0);

	return d > 0 ? (UINT64)d / (tsc_hz / 1000) : 0;
}

static void print_line(UINTN idx, UINT64 apic_id, const CHAR16 *what, INT64 off0,
		       const struct result *r, UINTN iters, BOOLEAN ok, const CHAR16 *note)
{
	CHAR16 warp[64] = u"";

	if (r->warp_tested)
		UnicodeSPrint(warp, sizeof(warp), u"  warps bsp/ap %lu/%lu",
			      r->warps_bsp, r->warps_ap);
	if (iters)
		out(u"  %s %2lu apic %3lu: before %ld  after %ld  rtt %lu  iter %lu%s  %s%s\n",
		    what, (UINT64)idx, apic_id, off0, r->off, r->rtt, (UINT64)iters, warp,
		    ok ? u"OK " : u"BAD ", note);
	else
		out(u"  %s %2lu apic %3lu: offset %ld  rtt %lu%s  %s%s\n",
		    what, (UINT64)idx, apic_id, r->off, r->rtt, warp,
		    ok ? u"OK " : u"BAD ", note);
}

/*
 * Measure one AP; with fix, correct it to the exact tick; with warp, run the
 * kernel-style test afterwards. Returns TRUE when the AP was measured; *ok
 * says whether it ends in sync (and warp-free if tested).
 */
static BOOLEAN handle_ap(EFI_MP_SERVICES_PROTOCOL *mp, UINTN idx, UINT64 apic_id,
			 BOOLEAN fix, BOOLEAN warp, struct result *r, BOOLEAN *ok)
{
	EFI_TPL old_tpl;
	UINT64 req = 0;
	INT64 off0 = 0;
	BOOLEAN measured;
	UINTN iters = 0;
	const CHAR16 *note = u"";

	ZeroMem(r, sizeof(*r));
	*ok = FALSE;
	if (!start_session(mp, idx))
		return FALSE;

	/* Interrupts off on the BSP only while measuring and adjusting. */
	old_tpl = uefi_call_wrapper(BS->RaiseTPL, 1, TPL_HIGH_LEVEL);
#ifdef TSCSYNC_TEST
	/* VM test build only: desync this AP once, before the survey measures it. */
	if ((test_ap_behind || test_mixed) && idx < MAX_CPUS && !test_desynced[idx]) {
		ap_command(CMD_ADJUST, test_mixed && (idx & 1) ? TEST_WARP :
			   test_mixed ? -TEST_WARP / 2 : -TEST_WARP);
		test_desynced[idx] = TRUE;
	}
#endif
	measured = measure(&req, &off0, &r->rtt);
	r->off = off0;
	if (!measured) {
		note = u"measure timeout";
	} else if (!fix && warp) {
		*ok = verify_ok(off0);	/* warp test below decides the rest */
	} else if (!fix || in_sync(off0)) {
		*ok = in_sync(off0);
	} else if (off0 > MAX_BACKWARD) {
		note = u"AP far ahead of BSP: left alone";
	} else if (-off0 > MAX_FORWARD) {
		note = u"offset implausibly large: left alone";
	} else {
		INT64 delta = -off0, shortfall = 0, prev = off0;

		for (iters = 1; iters <= MAX_ITER; iters++) {
			if (delta < -MAX_BACKWARD) {
				note = u"would need a large backward step: stopped";
				break;
			}
			if (!ap_command(CMD_ADJUST, delta)) {
				note = u"adjust timeout";
				break;
			}
			if (!measure(&req, &r->off, &r->rtt)) {
				note = u"measure timeout after adjust";
				break;
			}
			INT64 want;	/* how far the AP must move */

			if (!in_sync(r->off)) {
				want = -r->off;
			} else {
				/* In range: accept only if the kernel-style test agrees. */
				if (!warp_test(r)) {
					note = u"warp test timeout";
					break;
				}
				if (warp_clean(r)) {
					*ok = TRUE;
					break;
				}
				INT64 step = tick > NUDGE ? (INT64)tick : NUDGE;

				/* AP-side warps: the AP is behind; BSP-side: it is ahead. */
				want = r->warps_ap >= r->warps_bsp ? step : -step;
				r->warp_tested = FALSE;
			}
			/* The AP lands short of its target by this much. */
			shortfall = update_shortfall(shortfall, (prev + delta) - r->off);
			prev = r->off;
			delta = want + shortfall;
		}
		if (iters > MAX_ITER)
			note = u"did not converge";
	}
	if (measured && warp) {
		if (!warp_test(r))
			note = u"warp test timeout";
		if (!warp_clean(r))
			*ok = FALSE;
	}
	uefi_call_wrapper(BS->RestoreTPL, 1, old_tpl);

	print_line(idx, apic_id, u"cpu", off0, r, iters, *ok, note);
	end_session(idx);
	return measured;
}

/*
 * Move the BSP's TSC until it matches reference AP ref_idx exactly and the
 * kernel-style warp test is clean in both directions.
 */
static BOOLEAN bump_bsp(EFI_MP_SERVICES_PROTOCOL *mp, UINTN ref_idx)
{
	EFI_TPL old_tpl;
	struct result r;
	UINT64 req = 0;
	INT64 off0 = 0, shortfall = 0;
	BOOLEAN ok = FALSE;
	UINTN iters = 0;
	const CHAR16 *note = u"";

	ZeroMem(&r, sizeof(r));
	if (!start_session(mp, ref_idx))
		return FALSE;
	old_tpl = uefi_call_wrapper(BS->RaiseTPL, 1, TPL_HIGH_LEVEL);
#ifdef TSCSYNC_TEST
	/* VM test build only: KVM keeps TSC writes within a session. */
	if (test_bsp_loop)
		ap_command(CMD_ADJUST, TEST_WARP);
#endif
	if (!measure(&req, &off0, &r.rtt)) {
		note = u"measure timeout";
	} else if (off0 <= ACT_THRESHOLD || off0 > MAX_FORWARD) {
		note = u"reference AP no longer ahead by a plausible amount: BSP left alone";
		r.off = off0;
	} else {
		r.off = off0;
		for (iters = 1; iters <= MAX_ITER; iters++) {
			INT64 want;	/* how far the BSP must move */

			if (!in_sync(r.off)) {
				want = r.off;
			} else {
				if (!warp_test(&r)) {
					note = u"warp test timeout";
					break;
				}
				if (warp_clean(&r)) {
					ok = TRUE;
					break;
				}
				/* In sync to the tick but the kernel test still sees
				 * warps: nudge one tick toward the side that loses. */
				INT64 step = tick > NUDGE ? (INT64)tick : NUDGE;

				want = r.warps_bsp >= r.warps_ap ? step : -step;
			}
			INT64 delta = want + shortfall, before = r.off;

			if (delta < -MAX_BACKWARD || delta > MAX_FORWARD) {
				note = u"correction out of range: stopped";
				break;
			}
			adjust_tsc(delta);	/* on the BSP */
			bsp_shift += delta;
			if (!measure(&req, &r.off, &r.rtt)) {
				note = u"measure timeout after adjust";
				break;
			}
			r.warp_tested = FALSE;
			/* The BSP lands short of its target by this much. */
			shortfall = update_shortfall(shortfall, r.off - (before - delta));
		}
		if (iters > MAX_ITER)
			note = u"did not converge";
	}
	uefi_call_wrapper(BS->RestoreTPL, 1, old_tpl);
	print_line(ref_idx, 0, u"bsp vs cpu", off0, &r, iters, ok, note);
	end_session(ref_idx);
	return ok;
}

static BOOLEAN has_token(EFI_LOADED_IMAGE *li, const CHAR16 *tok)
{
	CHAR16 *s = li ? li->LoadOptions : NULL;
	UINTN n = li ? li->LoadOptionsSize / sizeof(CHAR16) : 0;
	UINTN tl = StrLen(tok);

	for (UINTN i = 0; s && i + tl <= n; i++) {
		BOOLEAN start = i == 0 || s[i - 1] == u' ';
		BOOLEAN end = i + tl == n || s[i + tl] == u' ' || s[i + tl] == 0;
		if (start && end && CompareMem(&s[i], tok, tl * sizeof(CHAR16)) == 0)
			return TRUE;
	}
	return FALSE;
}

static void save_report(void)
{
	EFI_STATUS st = uefi_call_wrapper(RT->SetVariable, 5, u"TscSyncResult", &result_guid,
		EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS,	/* volatile */
		(report_len + 1) * sizeof(CHAR16), report);

	if (EFI_ERROR(st))
		Print(u"tscsync: could not store result variable: %r\n", st);
}

/*
 * One pass over every enabled AP. Returns the number of APs that are not OK
 * and fills the survey arrays when they are given.
 */
static UINTN ap_pass(EFI_MP_SERVICES_PROTOCOL *mp, UINTN nproc, UINTN bsp, BOOLEAN fix,
		     BOOLEAN warp, INT64 *offs, BOOLEAN *measured, UINTN *n_measured)
{
	UINTN good = 0, bad = 0;

	if (n_measured)
		*n_measured = 0;
	for (UINTN i = 0; i < nproc && i < MAX_CPUS; i++) {
		EFI_PROCESSOR_INFORMATION info;
		struct result r;
		BOOLEAN ok;

		if (i == bsp)
			continue;
		ZeroMem(&info, sizeof(info));
		if (EFI_ERROR(uefi_call_wrapper(mp->GetProcessorInfo, 3, mp, i, &info)) ||
		    !(info.StatusFlag & PROCESSOR_ENABLED_BIT))
			continue;
		BOOLEAN m = handle_ap(mp, i, info.ProcessorId, fix, warp, &r, &ok);
		if (offs)
			offs[i] = r.off;
		if (measured)
			measured[i] = m;
		if (m && n_measured)
			(*n_measured)++;
		if (ok)
			good++;
		else
			bad++;
	}
	out(u"  %lu ok, %lu not ok\n", (UINT64)good, (UINT64)bad);
	return bad;
}

/* gnu-efi's crt0 converts the firmware's MS ABI call into a SysV call. */
EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *systab)
{
	static INT64 offs[MAX_CPUS];
	static BOOLEAN measured[MAX_CPUS];
	EFI_LOADED_IMAGE *li = NULL;
	EFI_MP_SERVICES_PROTOCOL *mp = NULL;
	UINTN nproc = 0, nenabled = 0, bsp = 0, n_measured = 0, bad = 1;
	UINT32 a, b, c, d;
	BOOLEAN sync;
	EFI_STATUS st;

	InitializeLib(image, systab);
	uefi_call_wrapper(BS->HandleProtocol, 3, image, &LoadedImageProtocol, (void **)&li);
	sync = has_token(li, u"mode=sync");
	BOOLEAN any_cpu = has_token(li, u"allow=any-cpu");
#ifdef TSCSYNC_TEST
	test_ap_behind = has_token(li, u"test=ap-behind");
	test_mixed = has_token(li, u"test=mixed");
	test_bsp_loop = sync && !test_ap_behind && !test_mixed;
	out(u"*** TEST BUILD: %s; for VMs only ***\n", test_ap_behind ?
	    u"sets every AP back before syncing" : test_mixed ?
	    u"sets odd APs ahead and even APs back before syncing" :
	    u"pushes one AP ahead and forces the BSP correction");
#endif
	out(u"tscsync %s: mode=%s\n", TSCSYNC_VERSION, sync ? u"sync" : u"measure");

	cpuid(0, 0, &a, &b, &c, &d);
	UINT32 max_leaf = a;
	BOOLEAN amd = b == 0x68747541 && d == 0x69746e65 && c == 0x444d4163;	/* AuthenticAMD */
	BOOLEAN hygon = b == 0x6f677948 && d == 0x6e65476e && c == 0x656e6975;	/* HygonGenuine */
	cpuid(1, 0, &a, &b, &c, &d);
	UINT32 family = ((a >> 8) & 0xf) + (((a >> 8) & 0xf) == 0xf ? ((a >> 20) & 0xff) : 0);
	BOOLEAN tsc_adjust = FALSE;
	if (max_leaf >= 7) {
		cpuid(7, 0, &a, &b, &c, &d);
		tsc_adjust = (b >> 1) & 1;
	}
	cpuid(0x80000000, 0, &a, &b, &c, &d);
	BOOLEAN invariant = FALSE;
	if (a >= 0x80000007) {
		cpuid(0x80000007, 0, &a, &b, &c, &d);
		invariant = (d >> 8) & 1;
	}
	/* Zen: families 17h (Zen 1/2), 18h (Hygon Dhyana), 19h (Zen 3/4), 1Ah (Zen 5). */
	BOOLEAN known = (amd && (family == 0x17 || family == 0x19 || family == 0x1a)) ||
			(hygon && family == 0x18);
#ifdef TSCSYNC_TEST
	tsc_adjust = FALSE;	/* KVM advertises TSC_ADJUST to guests */
	invariant = TRUE;	/* and hides invariant TSC unless asked */
#endif
	tick = detect_tick();
	{
		UINT64 c0 = rdtsc();

		uefi_call_wrapper(BS->Stall, 1, 10000);	/* 10 ms */
		UINT64 hz = (rdtsc() - c0) * 100;
		if (hz > 500000000ULL && hz < 10000000000ULL)
			tsc_hz = hz;
	}
	out(u"cpu: vendor=%s family=0x%x invariant_tsc=%d tsc_adjust=%d tsc_tick=%lu\n",
	    amd ? u"amd" : hygon ? u"hygon" : u"other", family, invariant, tsc_adjust, tick);
	if (sync && tsc_adjust) {
		out(u"sync refused: this CPU has TSC_ADJUST, so the kernel corrects offsets itself; measuring only\n");
		sync = FALSE;
	} else if (sync && !invariant) {
		out(u"sync refused: no invariant TSC, so Linux will not use the TSC anyway; measuring only\n");
		sync = FALSE;
	} else if (sync && !known && !any_cpu) {
		out(u"sync refused: CPU not in the supported list (add allow=any-cpu to override); measuring only\n");
		sync = FALSE;
	}

	st = uefi_call_wrapper(BS->LocateProtocol, 3, &mp_guid, NULL, (void **)&mp);
	if (EFI_ERROR(st)) {
		out(u"MP services not available: %r\n", st);
		goto done;
	}
	uefi_call_wrapper(mp->GetNumberOfProcessors, 3, mp, &nproc, &nenabled);
	uefi_call_wrapper(mp->WhoAmI, 2, mp, &bsp);
	out(u"processors: %lu (%lu enabled), bsp index %lu, bsp tsc %lu\n",
	    (UINT64)nproc, (UINT64)nenabled, (UINT64)bsp, rdtsc());
	if (nproc > MAX_CPUS) {
		out(u"more than %d processors: not supported\n", MAX_CPUS);
		goto done;
	}

	UINT64 t_all = rdtsc(), t_phase = t_all;
	INT64 s_all = bsp_shift, s_phase = s_all;

	/*
	 * In measure mode the survey is the only pass, so it judges each AP the
	 * way the kernel will: verify limit plus the warp test.
	 */
	out(u"survey (read-only%s):\n", sync ? u"" : u", with kernel-style warp test");
	bad = ap_pass(mp, nproc, bsp, FALSE, !sync, offs, measured, &n_measured);
	out(u"  (%lu ms)\n", ms_since(t_phase, s_phase));

	INT64 minoff = 0, maxoff = 0;
	UINTN maxidx = 0;
	BOOLEAN first = TRUE;
	for (UINTN i = 0; i < nproc; i++) {
		if (i == bsp || !measured[i])
			continue;
		if (first || offs[i] < minoff)
			minoff = offs[i];
		if (first || offs[i] > maxoff) {
			maxoff = offs[i];
			maxidx = i;
		}
		first = FALSE;
	}
	/* Reference AP: the median offset, so the BSP lands mid-cluster. */
	UINTN refidx = maxidx;
	for (UINTN i = 0; i < nproc; i++) {
		UINTN below = 0, above = 0;

		if (i == bsp || !measured[i])
			continue;
		for (UINTN j = 0; j < nproc; j++) {
			if (j == bsp || !measured[j] || j == i)
				continue;
			if (offs[j] < offs[i])
				below++;
			else if (offs[j] > offs[i])
				above++;
		}
		if (below <= n_measured / 2 && above <= n_measured / 2) {
			refidx = i;
			break;
		}
	}
	out(u"APs vs BSP: min %ld  max %ld  spread %ld  median cpu %lu  (%lu measured)\n",
	    minoff, maxoff, maxoff - minoff, (UINT64)refidx, (UINT64)n_measured);

#ifdef TSCSYNC_TEST
	if (test_bsp_loop) {
		UINTN ref = bsp == 0 ? 1 : 0;

		out(u"test: forcing the BSP correction against cpu %lu:\n", (UINT64)ref);
		bump_bsp(mp, ref);
		goto ap_fix;
	}
#endif
	if (!sync)
		goto result;
	if (bad == 0)
		goto verify;	/* offsets already zero: still run the warp test */

	if (n_measured + 1 != nenabled) {
		out(u"sync skipped: not every AP could be measured\n");
		goto result;
	}
	/*
	 * Everything only moves forward. If any AP is ahead of the BSP, the BSP
	 * catches up first: to the median AP when the APs agree with each other
	 * (then usually nothing else needs a write), otherwise to the
	 * furthest-ahead AP. The AP pass then brings every lagging AP forward.
	 */
	if (maxoff > ACT_THRESHOLD) {
		UINTN ref = maxoff - minoff <= SPREAD_MAX && minoff > ACT_THRESHOLD ? refidx : maxidx;

		if (maxoff > MAX_FORWARD) {
			out(u"sync skipped: an AP is %ld cycles ahead, beyond the %ld-cycle limit\n",
			    maxoff, (INT64)MAX_FORWARD);
			goto result;
		}
		out(u"moving BSP forward by ~%ld cycles to match cpu %lu:\n", offs[ref], (UINT64)ref);
		if (!bump_bsp(mp, ref)) {
			out(u"BSP adjustment incomplete; APs left untouched\n");
			goto verify;
		}
	}
#ifdef TSCSYNC_TEST
ap_fix:
#endif
	out(u"AP pass (corrects any AP still off):\n");
	t_phase = rdtsc();
	s_phase = bsp_shift;
	ap_pass(mp, nproc, bsp, TRUE, FALSE, NULL, NULL, NULL);
	out(u"  (%lu ms)\n", ms_since(t_phase, s_phase));
verify:
	out(u"verify (read-only, with kernel-style warp test):\n");
	t_phase = rdtsc();
	s_phase = bsp_shift;
	bad = ap_pass(mp, nproc, bsp, FALSE, TRUE, NULL, NULL, NULL);
	out(u"  (%lu ms)\n", ms_since(t_phase, s_phase));
result:
	for (UINTN i = 0; i < MAX_CPUS; i++)
		if (!wait_idle(i))
			out(u"cpu %lu still busy at exit; its event is left open\n", (UINT64)i);
	out(u"total %lu ms\n", ms_since(t_all, s_all));
	out(u"%s\n", bad == 0 ? u"RESULT: all APs in sync (Linux should keep the TSC)" :
			      u"RESULT: some APs out of sync (Linux will fall back to HPET)");
done:
	save_report();
	return EFI_SUCCESS;	/* always hand control back to GRUB */
}
