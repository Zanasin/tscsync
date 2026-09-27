// SPDX-License-Identifier: MIT
// tscprobe: measure each CPU's TSC offset relative to CPU 0 from user space.
// Read-only: it only executes RDTSC/RDTSCP. It never writes MSRs or changes
// kernel state, so it is safe to run at any time.
//
// Method: CPU 0 and CPU n ping-pong through a shared cache line. For each
// round, CPU 0 reads t0, signals, CPU n reads its TSC (a) and answers, CPU 0
// reads t1. The offset estimate is a - (t0 + t1) / 2; the round with the
// smallest round-trip (t1 - t0) is kept because it has the least uncertainty.
//
// Build: gcc -O2 -pthread -o tscprobe tscprobe.c
// Usage: ./tscprobe [rounds] [tsc_mhz]

#define _GNU_SOURCE
#include <inttypes.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static inline uint64_t rdtsc_ordered(void)
{
	uint32_t lo, hi, aux;
	__asm__ volatile("rdtscp" : "=a"(lo), "=d"(hi), "=c"(aux)::"memory");
	return ((uint64_t)hi << 32) | lo;
}

struct shared {
	_Alignas(64) atomic_uint_fast64_t req;
	_Alignas(64) atomic_uint_fast64_t ack;
	_Alignas(64) atomic_uint_fast64_t val;
	_Alignas(64) atomic_int stop;
};

struct target_arg {
	struct shared *sh;
	int cpu;
};

static int pin(int cpu)
{
	cpu_set_t set;
	CPU_ZERO(&set);
	CPU_SET(cpu, &set);
	return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}

static void *target_thread(void *p)
{
	struct target_arg *ta = p;
	struct shared *sh = ta->sh;
	uint64_t seen = 0;

	if (pin(ta->cpu))
		return (void *)1;
	while (!atomic_load(&sh->stop)) {
		uint64_t r = atomic_load_explicit(&sh->req, memory_order_acquire);
		if (r == seen)
			continue;
		uint64_t now = rdtsc_ordered();
		atomic_store_explicit(&sh->val, now, memory_order_relaxed);
		atomic_store_explicit(&sh->ack, r, memory_order_release);
		seen = r;
	}
	return NULL;
}

int main(int argc, char **argv)
{
	int rounds = argc > 1 ? atoi(argv[1]) : 20000;
	int ncpu = sysconf(_SC_NPROCESSORS_ONLN);
	/* TSC rate from "tsc: Detected ... MHz" in the kernel log. */
	double mhz = argc > 2 ? atof(argv[2]) : 2495.247;

	if (pin(0)) {
		perror("pin cpu0");
		return 1;
	}
	printf("reference CPU 0, %d rounds per CPU, TSC %.3f MHz\n", rounds, mhz);
	printf("%4s %20s %12s %10s\n", "cpu", "offset_cycles", "offset_ms", "best_rtt");

	for (int cpu = 1; cpu < ncpu; cpu++) {
		struct shared *sh = aligned_alloc(64, sizeof(*sh));
		struct target_arg ta = { sh, cpu };
		pthread_t th;
		int64_t best_off = 0;
		uint64_t best_rtt = UINT64_MAX;

		atomic_init(&sh->req, 0);
		atomic_init(&sh->ack, 0);
		atomic_init(&sh->val, 0);
		atomic_init(&sh->stop, 0);
		if (pthread_create(&th, NULL, target_thread, &ta)) {
			perror("pthread_create");
			return 1;
		}
		for (uint64_t i = 1; i <= (uint64_t)rounds; i++) {
			uint64_t t0 = rdtsc_ordered();
			atomic_store_explicit(&sh->req, i, memory_order_release);
			while (atomic_load_explicit(&sh->ack, memory_order_acquire) != i)
				;
			uint64_t t1 = rdtsc_ordered();
			uint64_t a = atomic_load_explicit(&sh->val, memory_order_relaxed);
			uint64_t rtt = t1 - t0;
			if (rtt < best_rtt) {
				best_rtt = rtt;
				best_off = (int64_t)(a - (t0 + rtt / 2));
			}
		}
		atomic_store(&sh->stop, 1);
		pthread_join(th, NULL);
		printf("%4d %20" PRId64 " %12.3f %10" PRIu64 "\n", cpu, best_off,
		       best_off / (mhz * 1000.0), best_rtt);
		free(sh);
	}
	return 0;
}
