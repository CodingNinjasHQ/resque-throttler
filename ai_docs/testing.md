# Testing the `resque-throttler` Gem

This document describes how to run and extend the test suite for `resque-throttler`, and the manual verification steps that should be performed before any release. It exists because this gem enforces an invariant — a rate-limited queue must never become permanently stuck — that is easy to regress silently. The v3.1.0 fix (sorted-set based leak-proof tracking) came out of a real production incident where the old `INCR`/`DECR` counter leaked on worker SIGKILL and blocked the `lsq_rl_pro` queue for 3 days. The tests here are what stop that from recurring.

## What this gem guarantees (what the tests verify)

1. `rate_limit` correctly stores config and rejects bad options.
2. `queue_at_or_over_rate_limit?` triggers exactly at `:at` in the `:per` window.
3. `register_active_job` returns a token; `unregister_active_job(queue, token)` removes that token.
4. `queue_at_or_over_concurrent_limit?` triggers exactly at `:concurrent` active jobs.
5. **Leak-proof invariant**: an active-job entry that is never unregistered (i.e. the worker was SIGKILL'd before its `ensure` block could run) is evicted by the next `active_job_count` call after `:max_runtime` seconds have elapsed. The queue auto-unblocks.
6. `reset_throttling(queue)` clears both the v3.1+ sorted set and the legacy v3.0 counter key.
7. Backward-compat shims `increment_active_jobs` / `decrement_active_jobs` still behave reasonably (they now wrap the token API).

## Environment — run tests inside the NinjasTool Docker container, not on the host

The host macOS Ruby setup has incompatible gem builds (`~/.gem/gems/date-3.4.1/lib/date_core.bundle` compiled against a different Ruby). Running the test suite locally is flaky and not supported. Use the `ninjastool` Docker container instead — it has Ruby 2.7.8, compatible native extensions, and a running `redis-tool` service that the tests point at.

### Prerequisites

1. NinjasTool Docker stack is up:
   ```
   cd /path/to/NinjasTool
   docker-compose up -d
   ```
2. `ninjastool` and `redis-tool` services are running:
   ```
   docker-compose ps
   # NAME          SERVICE       STATUS
   # ninjastool    ninjastool    Up
   # redis-tool    redis-tool    Up
   ```

## Running the full test suite

From the gem directory:

```bash
# 1. Copy the current source into the container
docker cp /Users/parikshitsingh/Desktop/opensource/resque-throttler ninjastool:/tmp/resque-throttler

# 2. Install dev dependencies (regenerate Gemfile.lock inside the container,
#    because the host and container bundler versions may differ)
docker-compose exec -T ninjastool bash -lc '
  cd /tmp/resque-throttler
  rm -f Gemfile.lock
  bundle install --quiet
'

# 3. Run the test suite, pointing Resque at the compose redis-tool service
docker-compose exec -T ninjastool bash -lc '
  cd /tmp/resque-throttler
  RESQUE_REDIS=redis-tool:6379 bundle exec rake test
'
```

Expected output tail:

```
16 tests, 31 assertions, 0 failures, 0 errors, 0 skips
```

### Re-running without re-copying

After the first `docker cp`, you can iterate by copying just the changed file(s) instead of the whole tree:

```bash
# Edited lib/resque/throttler.rb?
docker cp /Users/parikshitsingh/Desktop/opensource/resque-throttler/lib/resque/throttler.rb \
          ninjastool:/tmp/resque-throttler/lib/resque/throttler.rb

# Re-run tests
docker-compose exec -T ninjastool bash -lc '
  cd /tmp/resque-throttler
  RESQUE_REDIS=redis-tool:6379 bundle exec rake test
'
```

## What each test covers

File: `test/resque_test.rb`. Test names are read verbatim by Minitest — keep them descriptive.

| Test | What it asserts | Why it matters |
| --- | --- | --- |
| `Resque::rate_limit stores basic config` | `:at`/`:per` persist into `@rate_limits` | Baseline config smoke test |
| `Resque::rate_limit accepts concurrent and max_runtime options` | New optional keys are accepted | Guards the v3.1 option addition |
| `Resque::rate_limit raises ArgumentError on unknown options` | Typo'd options fail loudly | Prevents silent config drift |
| `Resque::rate_limit raises ArgumentError when :at or :per missing` | Required keys enforced | Contract check |
| `Resque::queue_rate_limited? accepts symbol and string` | Queue identity is normalized | Common footgun |
| `Resque::queue_at_or_over_rate_limit? compares window counter to :at` | Window-counter math | The rate-limiting primitive |
| `register_active_job adds one entry to the sorted set` | Token registration works | Core of the concurrent-limit path |
| `unregister_active_job removes the matching token` | Correct token is removed (not the oldest) | Prevents mis-decrements |
| `unregister_active_job with nil token is a no-op` | Safe to call without a token | Keeps `ensure`-block path simple |
| `queue_at_or_over_concurrent_limit? fires at the configured ceiling` | Boundary behavior at `:concurrent` | The throttle edge |
| `queue_at_or_over_concurrent_limit? is false when no concurrent option set` | `:concurrent`-less queues are unthrottled for concurrency | Backward compat |
| **`stale entries older than :max_runtime are auto-evicted on count`** | **SIGKILL simulation — the whole point of v3.1** | **Regression guard for the production incident** |
| `reset_throttling clears the active-job set and legacy counter` | Admin reset works for both v3.0 and v3.1 keys | Safe migration path |
| `increment_active_jobs still bumps the count (returns a token)` | Deprecated shim still works | Backward compat |
| `decrement_active_jobs removes the oldest entry when no token given` | FIFO fallback for tokenless callers | Backward compat |
| `decrement_active_jobs does not go negative on empty set` | ZPOPMIN on empty set is safe | Edge-case hardening |

### The leak-proof test is the one that matters

`test_stale_entries_older_than_:max_runtime_are_auto-evicted_on_count` simulates the production SIGKILL condition. If this test ever starts failing, **do not release**. The simulation:

```ruby
Resque.rate_limit(:myqueue, :at => 10, :per => 1, :concurrent => 3, :max_runtime => 1)

# Three workers "start" jobs at T=0. Intentionally skip calling
# unregister_active_job on any of them — this is what SIGKILL does to the
# ensure block.
travel_to Time.at(1_700_000_000) do
  3.times { Resque.register_active_job(:myqueue) }
  assert_equal 3, Resque.active_job_count(:myqueue)
  assert Resque.queue_at_or_over_concurrent_limit?(:myqueue)
end

# Jump past :max_runtime. active_job_count must evict the stale tokens.
travel_to Time.at(1_700_000_000 + 5) do
  assert_equal 0, Resque.active_job_count(:myqueue)
  assert !Resque.queue_at_or_over_concurrent_limit?(:myqueue)
end
```

## Manual verification for release

Automated tests cover the logic. Before tagging a release also do a manual smoke test against real Resque workers, because the bug we are guarding against only manifests when a real OS process is SIGKILL'd — not when a test merely skips calling a method.

### 1. Set up a minimal test harness in Rails console (inside the container)

```bash
docker-compose exec ninjastool bundle exec rails console -- --nomultiline
```

```ruby
require 'resque/throttler'

# Fresh state
Resque.redis.del('throttler:active_jobs_set:smoke_q')
Resque.redis.del('throttler:lock:smoke_q')
Resque.redis.del('throttler:rate_limit:smoke_q')

Resque.rate_limit(:smoke_q, at: 100, per: 5, concurrent: 3, max_runtime: 10)

# Simulate the SIGKILL leak by registering without unregistering
Resque.register_active_job(:smoke_q)
Resque.register_active_job(:smoke_q)
Resque.register_active_job(:smoke_q)
puts Resque.active_job_count(:smoke_q)             # => 3
puts Resque.queue_at_or_over_concurrent_limit?(:smoke_q)  # => true

# Wait past max_runtime and re-check — the counter must self-heal
sleep 11
puts Resque.active_job_count(:smoke_q)             # => 0
puts Resque.queue_at_or_over_concurrent_limit?(:smoke_q)  # => false
```

### 2. End-to-end SIGKILL test with a real worker

In one terminal, start a worker on a test queue:

```bash
docker-compose exec ninjastool bundle exec rake resque:work QUEUE=smoke_q
```

In another terminal, enqueue a deliberately slow job and kill the worker:

```ruby
# Rails console
class SlowJob
  @queue = :smoke_q
  def self.perform
    sleep 60
  end
end

Resque.rate_limit(:smoke_q, at: 100, per: 5, concurrent: 1, max_runtime: 15)
Resque.enqueue(SlowJob)
```

Then on the host, find the worker PID and SIGKILL it:

```bash
docker-compose exec ninjastool bash -lc 'pgrep -f "resque:work QUEUE=smoke_q"'
docker-compose exec ninjastool bash -lc 'kill -9 <PID>'
```

Expected behavior:
- Immediately after SIGKILL: `Resque.active_job_count(:smoke_q)` returns `1` (the leaked token is still there).
- After `max_runtime` seconds (15s in this example): the next call to `active_job_count` evicts the token and returns `0`. Starting a new worker on `smoke_q` picks up work normally.

Before the v3.1 fix, the counter would stay at 1 indefinitely and the queue would remain stuck until `Resque.reset_throttling(:smoke_q)` was run manually. Do not ship a version that regresses this.

## Adding new tests

- Use `Minitest` with the `test "name"` macro from `test_helper.rb`.
- Always `Resque.redis.flushdb` in `setup` so tests don't pollute each other — the shared compose Redis will carry state across runs otherwise.
- For time-sensitive behavior (stale eviction windows, rate-limit windows), use `travel_to Time.at(...)` from `ActiveSupport::Testing::TimeHelpers` rather than real `sleep`. Tests must be fast — the full suite runs in well under a second.
- Don't mock `Resque.redis`. We did that in the old `resque_test.rb` and it drifted out of sync with the real implementation silently. Hitting real Redis catches bugs that mocks hide.

## Release checklist

Before building and pushing a new gem version:

1. Bump `s.version` in `resque-throttler.gemspec`.
2. Update `README.md` if any public API changed.
3. Run the full test suite in Docker (above). **All tests must pass.**
4. Run the manual SIGKILL verification (above) at least once per minor-version bump.
5. Tag the release and build with `gem build resque-throttler.gemspec`.
6. Update dependent apps (e.g. NinjasTool `Gemfile`) to point at the new version.
7. Deploy to staging first, watch Sentry for `Resque::PruneDeadWorkerDirtyExit` for 48h, then deploy to prod.

## Known gotchas

- **Container Redis vs host Redis.** The container's Resque points at `redis-tool:6379` (compose service name). If you see `Redis::CannotConnectError: Connection refused - connect(2) for 127.0.0.1:6379` in test output, you forgot to set `RESQUE_REDIS=redis-tool:6379`.
- **Bundler version mismatch on the host.** The gem's old `Gemfile.lock` pinned `bundler 1.17.3` which does not work on Ruby 2.7.8 due to `date_core.bundle` incompatibility. Always `rm -f Gemfile.lock` before `bundle install` inside the container.
- **`mocha/mini_test` is gone.** Newer mocha uses `mocha/minitest`. The old require name will LoadError.
- **ActiveSupport 7.x is incompatible on Ruby 2.7 with our piecemeal `require 'active_support/testing/time_helpers'`** — the `Gemfile` pins `activesupport ~> 6.1` to avoid this. Do not unpin without re-testing.
- **`redis-namespace` deprecation warnings** about `flushdb` being a passthrough are expected and harmless. They come from the `ninjastool` container's Resque 2.7 + `redis-namespace` 1.11 combo and can be ignored. Do not silence them at the gem level — they are not our problem to fix.
