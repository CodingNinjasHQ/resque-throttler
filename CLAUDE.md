# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working on this gem.

## What this gem is

`resque-throttler` adds two primitives to Resque queues:

1. **Rate limiting** — cap how many jobs can start within a rolling time window (`at: N, per: S`).
2. **Concurrent limiting** — cap how many jobs can be running at the same time (`concurrent: N`).

Both are enforced at reservation time via `Resque::Worker#reserve`. Workers skip over queues that are at their cap rather than blocking, so throttled queues don't starve unthrottled ones.

## The production story behind v3.1.0

Before v3.1.0 the concurrent-limit counter was a simple `INCR` / `DECR` pair, with `DECR` run in a Ruby `ensure` block. `ensure` does not execute when a process is `SIGKILL`'d, which is exactly what `Resque::PruneDeadWorkerDirtyExit` represents. Each dirty exit leaked +1 on the counter, the Redis key had no TTL, and once leaks equalled `concurrent:`, the queue was permanently stuck with no worker able to reserve from it.

This happened in NinjasTool's `lsq_rl_pro` queue in April 2026 — five dirty exits over a weekend stuck a queue of ~32,700 jobs for three days. v3.1.0 replaces the counter with a Redis **Sorted Set of per-job tokens** whose score is the job's start timestamp. Every read of the count first evicts entries older than `:max_runtime` via `ZREMRANGEBYSCORE`, so leaked tokens self-heal without manual intervention.

**When working on this gem, preserving that leak-proof invariant is the single most important property.** If you are tempted to go back to a plain counter for any reason, don't — add a test that demonstrates why instead.

## Architecture

- **Core module**: `Resque::Plugins::Throttler`, extended onto `Resque`. All logic in `lib/resque/throttler.rb`.
- **Worker override**: `Resque::Worker#perform` and `#reserve` are re-opened in the same file. `#perform` wraps the original with token register/unregister. `#reserve` serializes the cap check + reservation with a 30-second Redis lock.

### Redis keys

| Key | Type | Purpose |
| --- | --- | --- |
| `throttler:lock:<queue>` | String (with EX=30) | Per-queue lock serializing reserve checks. Acquired in `#reserve` via `SET ... NX EX 30`. |
| `throttler:rate_limit:<queue>` | Integer (with EX=`:per`) | Counts jobs reserved in the current `:per` window. Compared against `:at`. |
| `throttler:active_jobs_set:<queue>` | Sorted Set | Active-job tokens. Members are random UUIDs; scores are job-start Unix timestamps. Size = concurrent count after stale eviction. |
| `throttler:active_jobs:<queue>` | String (legacy v3.0) | Old raw counter. Retained only so `reset_throttling` can `DEL` it during migration. Do not write. |

### Public API surface

- `Resque.rate_limit(queue, at:, per:, concurrent: nil, max_runtime: 3600)` — configure
- `Resque.rate_limit_for(queue)` → Hash
- `Resque.queue_rate_limited?(queue)` → Boolean
- `Resque.queue_at_or_over_rate_limit?(queue)` → Boolean (window-based)
- `Resque.queue_at_or_over_concurrent_limit?(queue)` → Boolean (sorted-set-based)
- `Resque.active_job_count(queue)` → Integer (side-effect: evicts stale entries)
- `Resque.register_active_job(queue)` → String token — **public since v3.1**
- `Resque.unregister_active_job(queue, token)` → void — **public since v3.1**
- `Resque.reset_throttling(queue = nil)` — clears both legacy and v3.1 keys
- `Resque.increment_active_jobs(queue)` / `Resque.decrement_active_jobs(queue)` — **deprecated** backward-compat shims; new code should use the token API

### Option constraints

- `:at` and `:per` are required together.
- `:concurrent` is optional; without it, only rate limiting applies.
- `:max_runtime` only matters when `:concurrent` is set. Defaults to `DEFAULT_MAX_RUNTIME = 3600` (1 hour). Tune it to be greater than the worst-case legitimate job runtime for the queue. Too short = risk of over-admission (evicting a token while its job is still running). Too long = slow self-healing after a SIGKILL.

## Commands

- **Install dependencies**: `bundle install`
- **Run tests**: `bundle exec rake test` (see testing note below)
- **Build gem**: `gem build resque-throttler.gemspec`

## Testing

**Run tests inside the NinjasTool Docker container, not on the host.** The host macOS Ruby environment has incompatible gem builds and bundler version pins that make local testing flaky. Full procedure, test inventory, manual SIGKILL verification, and release checklist are in [`ai_docs/testing.md`](ai_docs/testing.md) — read it before making changes.

Quick version:

```bash
docker cp . ninjastool:/tmp/resque-throttler
docker-compose exec -T ninjastool bash -lc '
  cd /tmp/resque-throttler && rm -f Gemfile.lock && bundle install --quiet &&
  RESQUE_REDIS=redis-tool:6379 bundle exec rake test
'
# Expect: "16 tests, 31 assertions, 0 failures, 0 errors, 0 skips"
```

### Test inventory

`test/resque_test.rb` has 16 tests. The one to watch is:

> `test_stale_entries_older_than_:max_runtime_are_auto-evicted_on_count`

It simulates the production SIGKILL condition with `ActiveSupport::TimeHelpers#travel_to`. If this test fails, **do not release** — the fix has regressed.

`test/resque/job_test.rb` and an earlier Mocha-heavy `test/resque_test.rb` were deleted in v3.1 because they referenced a long-gone prior incarnation of the gem (`@throttler_uuid`, `throttler:jobs:<uuid>`, per-Job#perform hooks). Don't recreate that style — tests should exercise the real Redis, not mocks.

## Conventions

- Ruby 2.7 minimum (NinjasTool still runs 2.7.8).
- `activesupport` is pinned to `~> 6.1` in the Gemfile for dev/test only; 7.x fails to load `time_helpers` in isolation.
- Runtime dependency: `resque > 1.25`.
- Keep all gem logic in `lib/resque/throttler.rb`. Resist the urge to split across files — a single-file gem is easier to audit for correctness.
- Do not silence deprecation noise from redis-namespace (`Passing 'flushdb' command to redis as is`). It originates downstream and fixing it is not our job.

## Deploying to NinjasTool

The consumer pins this gem by git tag in its `Gemfile`:

```ruby
gem 'resque-throttler', git: 'https://github.com/CodingNinjasHQ/resque-throttler.git', tag: 'vX.Y.Z'
```

To ship a new version:

1. Bump `s.version` in `resque-throttler.gemspec`.
2. Update `README.md` if public API changed.
3. Run the full test suite inside the container. All must pass.
4. Run the manual SIGKILL smoke test from `ai_docs/testing.md`.
5. `git tag vX.Y.Z && git push --tags` to the `CodingNinjasHQ/resque-throttler` fork.
6. In the NinjasTool `Gemfile`, bump the `tag:` value to `vX.Y.Z`.
7. `bundle update resque-throttler` inside the NinjasTool Docker container.
8. Deploy to staging first. Watch Sentry for `Resque::PruneDeadWorkerDirtyExit` and for any queue whose depth grows without draining, for 48 hours. Then deploy to prod.

## What not to change without a very good reason

- The single-file layout of `lib/resque/throttler.rb`.
- The backward-compat shims `increment_active_jobs` / `decrement_active_jobs`. They exist so existing NinjasTool code and any other consumers keep working on upgrade.
- The default `max_runtime` of 3600 seconds. Lowering it globally risks over-admission for any consumer running long jobs. Tune it per-queue in consumer configs.
- The sorted-set approach to active-job tracking. If a simpler design tempts you, first re-read "The production story behind v3.1.0" and then write the SIGKILL simulation test for your new design before writing code.
