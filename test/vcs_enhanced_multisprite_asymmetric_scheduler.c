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
   uint8_t omitted_mask;
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
 * asymmetric 1..6-band opposite-lane setup hazard.  The latter occurs only
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
      return !(gap >= 1 && gap <= 6);
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
   s->omitted_mask = 0;

   for (rank = 0; rank < NS; ++rank) {
      int id = s->priority[rank];
      int mask = choose_mask(s, id);
      int lane;

      if (!mask) {
         s->omitted_rank = rank;
         s->omitted_id = id;
         s->omitted_mask |= (uint8_t)(1u << id);
         continue;
      }

      if (s->accepted_count == 0 && fixed_first_lane) {
         /* Exact host equivalent of the renderer's first-candidate lookahead.
          * If priority[1] is 1..6 bands above priority[0], putting the lower
          * first sprite on P1 leaves P0 available for the second candidate. */
         int next = s->priority[1];
         int d = (int)s->y[next] - (int)s->y[id];
         lane = (d >= 1 && d <= 6) ? 1 : 0;
         if (!(mask & (1 << lane)))
            lane = (mask & 1) ? 0 : 1;
      } else if (fixed_first_lane && rank == NS - 2 && mask == 3) {
         /* Safe one-candidate suffix lookahead.  At rank 4 there is no sprite
          * after priority[5], so orienting the current sprite to avoid the
          * +1..+6 P0->P1 trap can never reduce the frame's accepted count. */
         int next = s->priority[NS - 1];
         int d = (int)s->y[next] - (int)s->y[id];
         lane = (d >= 1 && d <= 6) ? 1 : 0;
      } else {
         lane = (mask & 1) ? 0 : 1;
      }

      s->lane[id] = (uint8_t)lane;
      s->accepted[s->accepted_count++] = (uint8_t)id;
   }
}


static int raster_stream_valid(const sched_state *s)
{
   struct event { int action; int lane; int id; } ev[NS];
   int n = s->accepted_count;
   int i;

   for (i = 0; i < n; ++i) {
      int id = s->accepted[i];
      ev[i].id = id;
      ev[i].lane = s->lane[id];
      ev[i].action = s->y[id] + (ev[i].lane ? 3 : 6);
   }
   for (i = 1; i < n; ++i) {
      struct event key = ev[i];
      int j = i;
      while (j > 0 && ev[j - 1].action < key.action) {
         ev[j] = ev[j - 1];
         --j;
      }
      ev[j] = key;
   }

   for (i = 1; i < n; ++i) {
      int gap = ev[i - 1].action - ev[i].action;
      if (gap >= 4)
         continue;
      /* The visible renderer has exactly one supported three-band handoff:
       * exact-same-Y P0 then P1.  P1-above-P0 by six logical bands also
       * produces a three-band action gap, but in the reverse P1->P0 order and
       * overruns the post-setup pipeline. */
      if (gap == 3 && ev[i - 1].lane == 0 && ev[i].lane == 1 &&
          s->y[ev[i - 1].id] == s->y[ev[i].id])
         continue;
      return 0;
   }
   return 1;
}

static void exact_search(const sched_state *s, int id, int lanes[NS],
                         int accepted, int *best)
{
   int lane;
   int other;

   if (accepted + (NS - id) <= *best)
      return;
   if (id == NS) {
      if (accepted > *best)
         *best = accepted;
      return;
   }

   lanes[id] = -1;
   exact_search(s, id + 1, lanes, accepted, best);
   for (lane = 0; lane < 2; ++lane) {
      int ok = 1;
      for (other = 0; other < id; ++other) {
         if (lanes[other] >= 0 &&
             !compatible(s->y[id], lane, s->y[other], lanes[other])) {
            ok = 0;
            break;
         }
      }
      if (ok) {
         lanes[id] = lane;
         exact_search(s, id + 1, lanes, accepted + 1, best);
      }
   }
   lanes[id] = -1;
}

static int exact_max_accepted(const sched_state *s)
{
   int lanes[NS];
   int best = 0;
   int i;
   for (i = 0; i < NS; ++i)
      lanes[i] = -1;
   exact_search(s, 0, lanes, 0, &best);
   return best;
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

/* Fair queue update used by the renderer: every sprite that lost this frame
 * moves ahead of every sprite that was shown, while relative order within the
 * omitted and accepted groups is preserved.  Promoting only the final loser
 * is not sufficient when two independent contention groups lose sprites in
 * the same frame; one member of each group can otherwise receive much less
 * service than its peers. */
static void promote_all_omissions(sched_state *s)
{
   uint8_t next[NS];
   int n = 0;
   int rank;

   for (rank = 0; rank < NS; ++rank) {
      int id = s->priority[rank];
      if (s->omitted_mask & (1u << id))
         next[n++] = (uint8_t)id;
   }
   for (rank = 0; rank < NS; ++rank) {
      int id = s->priority[rank];
      if (!(s->omitted_mask & (1u << id)))
         next[n++] = (uint8_t)id;
   }
   memcpy(s->priority, next, sizeof(next));
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
   long exact_checked = 0;
   long avoidable_omissions = 0;
   int worst_optimal_gap = 0;
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

   /* Generic exact-same-Y contention witness.  Three sprites cannot occupy
    * two hardware lanes simultaneously under the current one-sprite-per-lane
    * model, but persistent priority must rotate the unavoidable omission rather
    * than starving one logical sprite forever. */
   init_identity(&one);
   {
      static const uint8_t wx[NS] = {18,36,62,88,114,140};
      static const uint8_t wy[NS] = {76,76,76,42,42,16};
      int shown[NS] = {0};
      int f;
      memcpy(one.x, wx, sizeof(wx));
      memcpy(one.y, wy, sizeof(wy));
      for (f = 0; f < 6; ++f) {
         int k;
         schedule(&one, 1);
         if (!raster_stream_valid(&one)) {
            fprintf(stderr, "same-Y fairness witness produced an unsafe event stream\n");
            dump(&one);
            return 1;
         }
         for (k = 0; k < one.accepted_count; ++k)
            ++shown[one.accepted[k]];
         promote_all_omissions(&one);
      }
      if (shown[0] == 0 || shown[1] == 0 || shown[2] == 0) {
         fprintf(stderr, "same-Y 0/1/2 contention starved a logical sprite\n");
         dump(&one);
         return 1;
      }
   }

   /* Staggered-chain witness recovered from the user's phosphor screenshot.
    * Approximate/current joystick state is:
    *
    *   X={62,72,62,88,114,140}
    *   Y={86,82,76,42,42,16}
    *
    * Sprites 0/1/2 are NOT a three-way visible overlap.  With eight bitmap
    * bands, 0 occupies 86..79, 1 occupies 82..75, and 2 occupies 76..69:
    * at every band at most two are live.  The natural lane coloring is
    * 0+2 on one lane and 1 on the other.  Nevertheless the present renderer
    * must omit one of 0/1/2 because its allocation compatibility describes
    * the longer position/setup pipeline (P0 15 bands, P1 12 bands, plus the
    * directional 1..6 event hazard), not merely visible bitmap overlap.
    *
    * Keep this as an explicit known-deficit witness until a short same-lane
    * continuation/reuse event is implemented.  Fair priority should rotate
    * the unnecessary omission; it must not disguise it as starvation.
    */
   init_identity(&one);
   {
      static const uint8_t wx[NS] = {62,72,62,88,114,140};
      static const uint8_t wy[NS] = {86,82,76,42,42,16};
      int shown[3] = {0,0,0};
      int max_live = 0;
      int band;
      int f;
      memcpy(one.x, wx, sizeof(wx));
      memcpy(one.y, wy, sizeof(wy));

      for (band = 0; band < 96; ++band) {
         int live = 0;
         int id;
         for (id = 0; id < 3; ++id)
            if (band <= one.y[id] && band + 7 >= one.y[id])
               ++live;
         if (live > max_live)
            max_live = live;
      }
      if (max_live != 2) {
         fprintf(stderr, "staggered-chain witness unexpectedly has %d-way visible overlap\n", max_live);
         return 1;
      }

      for (f = 0; f < 3; ++f) {
         int k;
         schedule(&one, 1);
         if (one.accepted_count != 5) {
            fprintf(stderr, "staggered-chain known-deficit witness changed before continuation support\n");
            dump(&one);
            return 1;
         }
         for (k = 0; k < one.accepted_count; ++k)
            if (one.accepted[k] < 3)
               ++shown[one.accepted[k]];
         promote_all_omissions(&one);
      }
      if (shown[0] != 2 || shown[1] != 2 || shown[2] != 2) {
         fprintf(stderr, "staggered-chain fairness did not rotate the avoidable omission 2/2/2\n");
         return 1;
      }
   }

   /* Second phosphor witness: the user's later 12:04 scene resolves at
    * integer joystick coordinates to two horizontal columns:
    *
    *   X={34,34,46,46,34,46}
    *   Y={90,76,82,68,61,58}
    *
    * Its eight-band glyph intervals are still only two-deep, yet the current
    * setup-reservation graph cannot schedule all six.  More importantly, the
    * identity-priority greedy allocator accepts only four although the exact
    * current-graph oracle can accept five.  This separates two remaining
    * problems: avoidable greedy flicker (4 versus 5) and the retained-X
    * continuation work needed to get from the current graph's optimum 5 to
    * the visually possible six-sprite stream.
    */
   init_identity(&one);
   {
      static const uint8_t wx[NS] = {34,34,46,46,34,46};
      static const uint8_t wy[NS] = {90,76,82,68,61,58};
      int max_live = 0;
      int band;
      memcpy(one.x, wx, sizeof(wx));
      memcpy(one.y, wy, sizeof(wy));
      for (band = 0; band < 96; ++band) {
         int live = 0;
         int id;
         for (id = 0; id < NS; ++id)
            if (band <= one.y[id] && band + 7 >= one.y[id])
               ++live;
         if (live > max_live)
            max_live = live;
      }
      if (max_live != 2) {
         fprintf(stderr, "12:04 screenshot witness unexpectedly has %d-way visible overlap\n", max_live);
         return 1;
      }
      schedule(&one, 1);
      if (one.accepted_count != 4) {
         fprintf(stderr, "12:04 screenshot greedy witness changed from four accepted sprites\n");
         dump(&one);
         return 1;
      }
      if (exact_max_accepted(&one) != 5) {
         fprintf(stderr, "12:04 screenshot current-graph optimum changed from five\n");
         dump(&one);
         return 1;
      }
   }

   /* Two independent three-way piles expose the old single-loser promotion
    * bug cleanly.  Four sprites are visible every frame, so over six frames a
    * fair scheduler must show every logical sprite exactly four times.  The
    * historical "promote only the last omission" policy instead gives the
    * third member of each pile only two frames of service. */
   init_identity(&one);
   {
      static const uint8_t wy[NS] = {76,76,76,42,42,42};
      int shown[NS] = {0};
      int legacy[NS] = {0};
      sched_state old;
      int f;
      memcpy(one.y, wy, sizeof(wy));
      old = one;

      for (f = 0; f < 6; ++f) {
         int k;
         schedule(&old, 1);
         for (k = 0; k < old.accepted_count; ++k)
            ++legacy[old.accepted[k]];
         promote_last_omission(&old);

         schedule(&one, 1);
         for (k = 0; k < one.accepted_count; ++k)
            ++shown[one.accepted[k]];
         promote_all_omissions(&one);
      }
      if (legacy[2] >= legacy[0] || legacy[5] >= legacy[3]) {
         fprintf(stderr, "historical two-pile fairness witness stopped reproducing\n");
         return 1;
      }
      for (f = 0; f < NS; ++f) {
         if (shown[f] != 4) {
            fprintf(stderr,
               "all-omission fairness failed for sprite %d: shown %d/6\n",
               f, shown[f]);
            return 1;
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
      if (!raster_stream_valid(&s)) {
         fprintf(stderr, "Monte Carlo found an unsafe scheduled event stream at iteration %ld\n", i);
         dump(&s);
         return 1;
      }
      ++hist[s.accepted_count];
      if (s.accepted_count < min_accepted)
         min_accepted = s.accepted_count;
      if (s.accepted_count < 2) {
         fprintf(stderr, "Monte Carlo found a one-sprite frame at iteration %ld\n", i);
         dump(&s);
         return 1;
      }

      /* Compare a bounded prefix against an exact 3^6 host search over
       * omit/P0/P1 assignments.  This quantifies avoidable greedy flicker and
       * gives later rebalancing work a real oracle without burdening the 6502. */
      if (i < 20000) {
         int optimum = exact_max_accepted(&s);
         int optimal_gap = optimum - s.accepted_count;
         ++exact_checked;
         if (optimal_gap < 0) {
            fprintf(stderr, "scheduler accepted an impossible layout\n");
            dump(&s);
            return 1;
         }
         if (optimal_gap > 0)
            ++avoidable_omissions;
         if (optimal_gap > worst_optimal_gap)
            worst_optimal_gap = optimal_gap;
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
         promote_all_omissions(&s);
      }
   }

   printf("asymmetric scheduler monte carlo ok: %ld layouts, min=%d, worst-gap=%d, hist=",
          iterations, min_accepted, worst_gap);
   for (int n = 1; n <= NS; ++n)
      printf("%s%d:%ld", n == 1 ? "" : ",", n, hist[n]);
   printf(", exact=%ld, avoidable=%ld, optimal-gap=%d\n",
          exact_checked, avoidable_omissions, worst_optimal_gap);
   return 0;
}
