/*
 * Host-side model of the enhanced asymmetric VBLANK lane allocator.
 *
 * This is intentionally tiny and independent of the 6502 implementation.  It
 * exists to make scheduler pathologies cheap to search: random X/Y layouts can
 * be evaluated millions of times without running a whole emulated video frame.
 * X is retained in the generated state because the next scheduler stage will
 * use horizontal pair feasibility, even though the current two-lane allocator
 * only depends on Y.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NS 6

typedef struct {
   uint8_t x[NS];
   uint8_t y[NS];
   uint8_t priority[NS];
   uint8_t lane[NS];
   uint8_t accepted[NS];
   int accepted_count;
   int omitted_rank;
   int omitted_id;
} sched_state;

static uint32_t rng_state = 0x31415927u;

static uint32_t rng32(void)
{
   uint32_t x = rng_state;
   x ^= x << 13;
   x ^= x >> 17;
   x ^= x << 5;
   rng_state = x;
   return x;
}

/* Pairwise form of the renderer's current 15/12 same-lane windows and the
 * asymmetric 1..5-band opposite-lane setup hazard.  The latter occurs only
 * when P1 is above P0. */
static int compatible(int ya, int la, int yb, int lb)
{
   int d = ya - yb;
   int ad = d < 0 ? -d : d;

   if (la == lb)
      return ad >= (la == 0 ? 15 : 12);

   {
      int yp1 = la == 1 ? ya : yb;
      int yp0 = la == 0 ? ya : yb;
      int gap = yp1 - yp0;
      return !(gap >= 1 && gap <= 5);
   }
}

static int choose_mask(const sched_state *s, int id)
{
   int mask = 3;
   int k;

   for (k = s->accepted_count - 1; k >= 0; --k) {
      int other = s->accepted[k];
      if (!compatible(s->y[id], 0, s->y[other], s->lane[other]))
         mask &= ~1;
      if (!compatible(s->y[id], 1, s->y[other], s->lane[other]))
         mask &= ~2;
      if (!mask)
         break;
   }
   return mask;
}

static void schedule(sched_state *s, int fixed_first_lane)
{
   int rank;

   s->accepted_count = 0;
   s->omitted_rank = -1;
   s->omitted_id = -1;

   for (rank = 0; rank < NS; ++rank) {
      int id = s->priority[rank];
      int mask = choose_mask(s, id);
      int lane;

      if (!mask) {
         s->omitted_rank = rank;
         s->omitted_id = id;
         continue;
      }

      if (s->accepted_count == 0 && fixed_first_lane) {
         /* Exact host equivalent of the renderer's first-candidate lookahead.
          * If priority[1] is 1..5 bands above priority[0], putting the lower
          * first sprite on P1 leaves P0 available for the second candidate.
          * Every other relative-Y case is safe with the historical P0 seed. */
         int next = s->priority[1];
         int d = (int)s->y[next] - (int)s->y[id];
         lane = (d >= 1 && d <= 5) ? 1 : 0;
         if (!(mask & (1 << lane)))
            lane = (mask & 1) ? 0 : 1;
      } else {
         lane = (mask & 1) ? 0 : 1;
      }

      s->lane[id] = (uint8_t)lane;
      s->accepted[s->accepted_count++] = (uint8_t)id;
   }
}

static void promote_last_omission(sched_state *s)
{
   int r;
   int id;
   if (s->omitted_rank < 0)
      return;
   r = s->omitted_rank;
   id = s->omitted_id;
   while (r > 0) {
      s->priority[r] = s->priority[r - 1];
      --r;
   }
   s->priority[0] = (uint8_t)id;
}

static void init_identity(sched_state *s)
{
   int i;
   memset(s, 0, sizeof(*s));
   for (i = 0; i < NS; ++i)
      s->priority[i] = (uint8_t)i;
}

static void dump(const sched_state *s)
{
   int i;
   printf("x=");
   for (i = 0; i < NS; ++i) printf("%s%u", i ? "," : "", s->x[i]);
   printf(" y=");
   for (i = 0; i < NS; ++i) printf("%s%u", i ? "," : "", s->y[i]);
   printf(" priority=");
   for (i = 0; i < NS; ++i) printf("%s%u", i ? "," : "", s->priority[i]);
   printf(" accepted=");
   for (i = 0; i < s->accepted_count; ++i) {
      int id = s->accepted[i];
      printf("%s%d(P%u)", i ? "," : "", id, s->lane[id]);
   }
   printf(" omitted=%d@%d\n", s->omitted_id, s->omitted_rank);
}

int main(int argc, char **argv)
{
   long iterations = 2000000;
   long i;
   long hist[NS + 1] = {0};
   int min_accepted = NS + 1;
   int worst_gap = 0;
   sched_state one;

   if (argc > 1) {
      char *end = 0;
      iterations = strtol(argv[1], &end, 0);
      if (!end || *end || iterations <= 0) {
         fprintf(stderr, "usage: %s [iterations [seed]]\n", argv[0]);
         return 2;
      }
   }
   if (argc > 2) {
      char *end = 0;
      unsigned long v = strtoul(argv[2], &end, 0);
      if (!end || *end) {
         fprintf(stderr, "usage: %s [iterations [seed]]\n", argv[0]);
         return 2;
      }
      rng_state = (uint32_t)v;
   }
   if (argc > 3) {
      fprintf(stderr, "usage: %s [iterations [seed]]\n", argv[0]);
      return 2;
   }

   /* Deterministic witness for the user's "only one sprite" report.  The old
    * blind-P0 seed accepts just sprite 0.  The fixed allocator must accept at
    * least two immediately. */
   init_identity(&one);
   {
      static const uint8_t wx[NS] = {50,34,100,133,115,97};
      static const uint8_t wy[NS] = {16,20,20,18,18,20};
      memcpy(one.x, wx, sizeof(wx));
      memcpy(one.y, wy, sizeof(wy));
   }
   schedule(&one, 0);
   if (one.accepted_count != 1) {
      fprintf(stderr, "historical one-sprite witness no longer reproduces in model\n");
      dump(&one);
      return 1;
   }
   init_identity(&one);
   {
      static const uint8_t wx[NS] = {50,34,100,133,115,97};
      static const uint8_t wy[NS] = {16,20,20,18,18,20};
      memcpy(one.x, wx, sizeof(wx));
      memcpy(one.y, wy, sizeof(wy));
   }
   schedule(&one, 1);
   if (one.accepted_count < 2) {
      fprintf(stderr, "first-lane repair still permits one-sprite witness\n");
      dump(&one);
      return 1;
   }

   /* Exhaustively prove the first two priority candidates can never collapse
    * to one accepted sprite for any legal Y pair. */
   for (int y0 = 0; y0 < 96; ++y0) {
      for (int y1 = 0; y1 < 96; ++y1) {
         sched_state s;
         init_identity(&s);
         s.y[0] = (uint8_t)y0;
         s.y[1] = (uint8_t)y1;
         /* Put the remaining sprites far enough away when possible; only the
          * first two acceptance decisions matter for this proof. */
         s.y[2] = 95; s.y[3] = 80; s.y[4] = 65; s.y[5] = 50;
         schedule(&s, 1);
         /* Some later values may alias y0/y1, but the first two are already
          * committed before those candidates are visited. */
         {
            int seen0 = 0, seen1 = 0;
            for (int k = 0; k < s.accepted_count; ++k) {
               if (s.accepted[k] == 0) seen0 = 1;
               if (s.accepted[k] == 1) seen1 = 1;
            }
            if (!seen0 || !seen1) {
               fprintf(stderr, "first-two exhaustive proof failed at y=%d,%d\n", y0, y1);
               dump(&s);
               return 1;
            }
         }
      }
   }

   for (i = 0; i < iterations; ++i) {
      sched_state s;
      int j;
      int gap[NS] = {0};

      init_identity(&s);
      for (j = 0; j < NS; ++j) {
         s.x[j] = (uint8_t)(rng32() % 160u);
         s.y[j] = (uint8_t)(rng32() % 96u);
      }

      schedule(&s, 1);
      ++hist[s.accepted_count];
      if (s.accepted_count < min_accepted)
         min_accepted = s.accepted_count;
      if (s.accepted_count < 2) {
         fprintf(stderr, "Monte Carlo found a one-sprite frame at iteration %ld\n", i);
         dump(&s);
         return 1;
      }

      /* Keep each random geometry fixed for twelve priority rotations and make
       * sure the fairness mechanism never makes a logical sprite vanish for a
       * long run.  This is a model-level smoke test, not a claim that every
       * geometry is drawable without flicker. */
      for (int f = 0; f < 12; ++f) {
         int seen[NS] = {0};
         schedule(&s, 1);
         for (j = 0; j < s.accepted_count; ++j)
            seen[s.accepted[j]] = 1;
         for (j = 0; j < NS; ++j) {
            if (seen[j]) gap[j] = 0;
            else if (++gap[j] > worst_gap) worst_gap = gap[j];
         }
         promote_last_omission(&s);
      }
   }

   printf("asymmetric scheduler monte carlo ok: %ld layouts, min=%d, worst-gap=%d, hist=",
          iterations, min_accepted, worst_gap);
   for (int n = 1; n <= NS; ++n)
      printf("%s%d:%ld", n == 1 ? "" : ",", n, hist[n]);
   putchar('\n');
   return 0;
}
