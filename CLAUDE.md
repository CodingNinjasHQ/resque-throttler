# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- **Install dependencies**: `bundle install`
- **Run tests**: `rake test` or `rake`
- **Build gem**: `rake build`
- **Release gem**: `rake release`
- **Generate documentation**: `rake rdoc`

## Architecture

This is a Ruby gem that adds rate limiting capabilities to Resque queues. The implementation works by:

1. **Core Module**: `Resque::Plugins::Throttler` in `/lib/resque/throttler.rb` contains all functionality
2. **Rate Limit Configuration**: Users set limits via `Resque.rate_limit(:queue_name, at: count, per: seconds)`
3. **Enforcement Mechanism**: Overrides `Resque::Worker#reserve` to check rate limits before allowing job reservation
4. **Redis-based Tracking**: Uses Redis counters with expiration for tracking job counts and distributed locks for thread safety

Key implementation details:
- Rate limit counters use Redis key: `throttler:rate_limit:{queue_name}`
- Distributed locks use Redis key: `throttler:lock:{queue_name}` with 30-second expiration
- Workers skip rate-limited queues rather than blocking
- All logic is contained in a single file for simplicity

## Testing

The project uses Minitest with Mocha for mocking. Note that some test files (particularly `/test/resque_test.rb` and `/test/resque/job_test.rb`) appear to be from an older implementation and may not reflect the current code structure.

## Development Guidelines

- The gem follows standard Ruby gem conventions
- Runtime dependency: resque > 1.25
- All core functionality is in `/lib/resque/throttler.rb`
- Keep the implementation simple - the entire gem is designed to do one thing well