# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is the Ruby implementation of `ci-queue`, a library that distributes tests over many workers using a queue. The project enables parallel test execution across CI workers with intelligent work distribution and failure handling.

**This is a FORK** focused on improving and maintaining RSpec compatibility. The upstream Shopify repository has deprecated RSpec support, but this fork actively develops RSpec features.

This is a **multi-language monorepo** - the current working directory is `/Users/rob.christie/dev/ci-queue/ruby`, but the parent directory contains Python and Redis implementations. The Lua scripts used by the Redis backend are located at `../redis/*.lua`.

### Current Branch

Working on: `rspec-dd-ci-compatibility` (see git status for recent modifications to Redis implementation files)

## Development Commands

### Running Tests

This project uses **Minitest** for its own test suite, even though it provides both Minitest and RSpec integrations for end users.

```bash
# Run all tests (includes RSpec integration tests)
bundle exec rake test

# Run specific test files
bundle exec rake test TEST_FILES="test/ci/queue_test.rb test/minitest/queue_test.rb"

# Run a single test (using Minitest syntax)
bundle exec ruby -Ilib:test test/ci/queue_test.rb -n test_name

# Run only the RSpec integration tests
bundle exec rake test TEST_FILES="test/integration/rspec_redis_test.rb"
```

### Testing RSpec Integration Locally

To manually test the rspec-queue executable:

```bash
# Basic RSpec queue run (requires Redis)
exe/rspec-queue --queue redis://localhost:6379/0 \
  --build test-build-1 \
  --worker 1 \
  --seed 123 \
  spec/

# Run with requeuing enabled
exe/rspec-queue --queue redis://localhost:6379/0 \
  --build test-build-1 \
  --worker 1 \
  --max-requeues 1 \
  --requeue-tolerance 0.1 \
  spec/

# Run the reporter (separate process)
exe/rspec-queue --queue redis://localhost:6379/0 \
  --build test-build-1 \
  --report \
  --timeout 600
```

**Note**: RSpec tests are in `test/fixtures/spec/` for integration testing purposes.

### Linting

```bash
bundle exec rubocop
```

### Building the Gem

```bash
# This automatically copies Lua scripts from ../redis/ to lib/ci/queue/redis/
bundle exec rake build
```

### Development Environment

For Shopify employees using `dev`, Redis is automatically configured:
```bash
dev up        # Starts Redis and installs dependencies
dev test      # Runs tests with REDIS_URL configured
```

## Architecture

### Core Components

**Queue Implementations** (in `lib/ci/queue/`):
- `CI::Queue::Static`: Static list-based queue (no coordination)
- `CI::Queue::File`: File-based queue (local development)
- `CI::Queue::Redis`: Distributed Redis-backed queue (production)
- `CI::Queue::Grind`: Repeated execution for flakiness detection
- `CI::Queue::Bisect`: Binary search to find test order dependencies

**Test Framework Integrations**:
- `Minitest::Queue` (in `lib/minitest/queue/`): Full-featured implementation
- `RSpec::Queue` (in `lib/rspec/queue/`): Actively maintained in this fork

**Redis Implementation** (in `lib/ci/queue/redis/`):
- `Base`: Connection management, heartbeat, Lua script execution
- `Worker`: Worker-side queue operations (reserve, acknowledge, requeue)
- `BuildRecord`: Tracks test results, errors, statistics
- `Supervisor`: Coordinator that monitors workers and aggregates results
- `Monitor`: Background process for heartbeat tracking

**Configuration** (in `lib/ci/queue/configuration.rb`):
- Automatically detects CI environment (Buildkite, CircleCI, Travis, Heroku CI, Semaphore)
- Configures build_id, worker_id, and seed from environment variables

### Key Architectural Concepts

**Leader Election**: Workers compete to become the leader. The leader populates the queue with all tests, then all workers (including the leader) process tests from the queue.

**Requeuing**: Failed tests can be automatically retried on different workers to detect flaky tests. Controlled by `--max-requeues` and `--requeue-tolerance` settings.

**Heartbeat System**: Workers send periodic heartbeats while processing tests. If a worker dies, its reserved tests are automatically returned to the queue after missing heartbeats.

**Lua Scripts**: Redis operations use atomic Lua scripts (in `../redis/`) for consistency:
- `reserve.lua`: Atomically claim next test from queue
- `acknowledge.lua`: Mark test as completed
- `requeue.lua`: Put test back in queue with requeue tracking
- `heartbeat.lua`: Update worker heartbeat timestamp
- `release.lua`: Release all reserved tests back to queue

### Test Execution Flow

1. Workers start and participate in leader election
2. Leader populates queue with test list (shuffled by seed)
3. All workers poll queue for tests to run
4. Each worker:
   - Reserves a test (with timeout)
   - Sends heartbeat while running test
   - Acknowledges completion or requeues on failure
5. Reporter process waits for all workers and aggregates results

## Important Implementation Details

### Minitest Integration

The `Minitest::Queue::Runner` (in `lib/minitest/queue/runner.rb`) provides these subcommands:

- `run`: Main worker command - participates in queue and runs tests
- `report`: Centralized error reporter - waits for workers and summarizes results
- `bisect`: Binary search to find test order dependencies causing failures
- `grind`: Run specific tests repeatedly to detect flakiness
- `report-grind`: Report results from grind runs

### Redis Connection Handling

- Connection errors are caught and retried automatically (see `Base#reconnect_attempts`)
- SSL verification is disabled for hosted Redis (self-signed certs)
- Default timeout: 2 seconds
- Supports debug logging with `--debug-log FILE`

### Working with Lua Scripts

When modifying Redis operations:
1. Edit scripts in `../redis/*.lua` (parent directory)
2. Run `bundle exec rake scripts:copy` to copy to `lib/ci/queue/redis/`
3. Build task automatically runs this before packaging the gem

### Test Fixtures

Test fixtures are in `test/fixtures/` and include sample test files used by integration tests. They are **intentionally excluded** from the gem package.

## RSpec Integration

**Note**: While the upstream Shopify repository has deprecated RSpec support in favor of Minitest, this fork actively maintains and improves the RSpec integration.

### RSpec Architecture

The RSpec integration (in `lib/rspec/queue/`) works by:

1. **Monkey-patching RSpec Core**: Extends RSpec's configuration, parser, and example execution
2. **Custom Runner**: `RSpec::Queue::Runner` extends `RSpec::Core::Runner` to participate in queue operations
3. **Custom Formatters**: Records test results and errors to Redis during execution

#### Key Components

**`lib/rspec/queue.rb`** - Main integration file that:
- Adds `--queue`, `--report`, `--build`, `--worker` CLI options to RSpec
- Patches `RSpec::Core::Configuration`, `RSpec::Core::Parser`, and `RSpec::Core::Example`
- Implements `SingleExample` wrapper to make examples queue-compatible
- Provides `Runner` (for workers) and `ReportRunner` (for centralized reporting)

**`lib/rspec/queue/build_status_recorder.rb`** - RSpec formatter that:
- Listens to `example_passed` and `example_failed` events
- Records successes/failures to Redis `BuildRecord`
- Serializes error reports using `ErrorReport` class

**`lib/rspec/queue/error_report.rb`** - Handles error serialization:
- Uses SnappyPack (Snappy + MessagePack) if available, falls back to Marshal
- Compresses error data before storing in Redis
- Stores test metadata (file, line, description) and formatted output

**`lib/rspec/queue/failure_formatter.rb`** - Formats failures for reporting:
- Wraps RSpec's exception presenter
- Generates colorized rerun commands (`rspec ./spec/file_spec.rb:123`)
- Converts notifications to structured hash for storage

**`lib/rspec/queue/order_recorder.rb`** - Records test execution order:
- Writes each example ID to `log/test_order.log` as tests start
- Used for debugging and bisect functionality

#### How RSpec Queue Execution Works

1. **Worker starts**: `exe/rspec-queue` invokes `RSpec::Queue::Runner.invoke`

2. **Configuration parsing**: Custom parser adds ci-queue options to RSpec

3. **Example collection**:
   - RSpec loads spec files and collects `example_groups`
   - Each example is wrapped in `SingleExample` (provides queue-compatible interface)

4. **Queue population**:
   - Leader calls `queue.populate(examples, random: ordering_seed, &:id)`
   - Examples shuffled using seed (from `--seed` or git commit hash)

5. **Queue polling**:
   ```ruby
   queue.poll do |example|
     example.run(QueueReporter.new(reporter, queue, example))
   end
   ```

6. **Example execution**:
   - `SingleExample#run` creates example group instance
   - Runs example through RSpec's normal execution path
   - `QueueReporter` wraps standard reporter to add queue operations

7. **Requeuing on failure**:
   - `ExampleExtension#finish` checks if test failed and is requeueable
   - Failed test requeued: `reporter.requeue` returns true
   - Requeued example marked as "pending" in output with failure details
   - Original example duplicated and retried on another worker

8. **Result recording**:
   - `BuildStatusRecorder` records pass/fail to Redis
   - Errors serialized with `ErrorReport` and stored with test ID

9. **Centralized reporting**:
   - `ReportRunner` (via `--report` flag) waits for queue exhaustion
   - Aggregates all error reports from Redis
   - Pretty-prints failure summary with file counts and rerun commands

### RSpec Limitations

**`before(:all)` and `after(:all)` hooks are NOT supported**:
- ci-queue runs examples independently across workers
- Examples may execute in different Ruby processes
- Shared state from `before(:all)` would not be available
- RSpec queue explicitly rejects these hooks at runtime

**`before(:suite)` and `after(:suite)` behavior**:
- Run once per worker (not once globally)
- Errors in `before(:suite)` halt that worker but don't populate queue
- Use with caution or avoid entirely

### RSpec CLI Usage

#### Basic Usage

```bash
# Worker execution
rspec-queue --queue redis://localhost/0 \
  --build BUILD_ID \
  --worker WORKER_ID \
  [--timeout 30] \
  [--max-requeues 1] \
  [--requeue-tolerance 0.05] \
  spec/

# Centralized reporter
rspec-queue --queue redis://localhost/0 \
  --build BUILD_ID \
  --report \
  [--timeout 600]
```

#### Typical CI Setup

```bash
# In your CI configuration (e.g., Buildkite, CircleCI)
# Worker step (parallel: 10 workers):
bundle exec rspec-queue \
  --queue $REDIS_URL \
  --build $CI_BUILD_ID \
  --worker $CI_WORKER_ID \
  --timeout 60 \
  --max-requeues 2 \
  --requeue-tolerance 0.05

# Reporter step (single instance, waits for all workers):
bundle exec rspec-queue \
  --queue $REDIS_URL \
  --build $CI_BUILD_ID \
  --report \
  --timeout 900
```

#### With RSpec Configuration

If you have a `.rspec` file, options are loaded automatically:
```
# .rspec
--color
--format documentation
--require spec_helper
```

Then run:
```bash
rspec-queue --queue redis://localhost/0 --build 1 --worker 1
```

**Important CLI Differences from Minitest**:
- RSpec uses `--report` flag (not a subcommand like `minitest-queue report`)
- No bisect or grind functionality for RSpec yet (Minitest only - potential enhancement for this fork)
- Spec files passed directly at the end (no `run` subcommand needed)
- All standard RSpec options still work (e.g., `--tag`, `--pattern`, `--exclude-pattern`)

### RSpec Test Fixtures

Located in `test/fixtures/spec/`:
- `dummy_spec.rb`: Sample specs including one flaky test
- `spec_helper.rb`: Minimal RSpec configuration
- `before_suite/`: Tests `before(:suite)` error handling
- `early_exit_suite/`: Tests early quit behavior (`world.wants_to_quit`)

### Debugging RSpec Integration

**Enable debug logging**:
```bash
rspec-queue --debug-log /tmp/ci-queue-debug.log ...
```

**Check execution order**:
```bash
cat log/test_order.log
```

**Test locally with fixture specs**:
```bash
cd test/fixtures
../../exe/rspec-queue --queue redis://localhost/0 --build test --worker 1
```

### Development Focus

This fork specifically focuses on:
- Improving RSpec integration compatibility and features
- Fixing bugs in RSpec queue execution
- Adding missing RSpec functionality (e.g., bisect, grind support)
- Ensuring parity with Minitest queue features where applicable

When contributing RSpec improvements:
- Ensure changes don't break Minitest integration
- Add integration tests in `test/integration/rspec_redis_test.rb`
- Update RSpec fixture specs in `test/fixtures/spec/` if needed
- Test against multiple RSpec versions if changing core behavior

## Ruby Version

Requires Ruby >= 2.7 (see `ci-queue.gemspec`)
Currently using Ruby 3.3.0 (see `.ruby-version`)

## CI Provider Integration

The library auto-detects these CI providers and configures itself:
- **Buildkite**: Uses `BUILDKITE_BUILD_ID`, `BUILDKITE_PARALLEL_JOB`, `BUILDKITE_COMMIT`
- **CircleCI**: Uses `CIRCLE_BUILD_URL`, `CIRCLE_NODE_INDEX`, `CIRCLE_SHA1`
- **Travis**: Uses `TRAVIS_BUILD_ID`, `TRAVIS_COMMIT`
- **Heroku CI**: Uses `HEROKU_TEST_RUN_ID`, `HEROKU_TEST_RUN_COMMIT_VERSION`
- **Semaphore**: Uses `SEMAPHORE_PIPELINE_ID`, `SEMAPHORE_JOB_ID`, `SEMAPHORE_GIT_SHA`

For other CI systems, explicitly pass `--build`, `--worker`, and `--seed` parameters.

## Common Pitfalls

### General

1. **Redis eviction policy**: Redis must use `allkeys-lru` eviction policy. Set `--redis-ttl` to control key expiration (default: 8 hours).

2. **Heartbeat timeout**: Set `--timeout` higher than your slowest test, otherwise tests will be incorrectly requeued while still running.

3. **Build ID consistency**: All workers must use the **exact same** `--build` value, or they won't share the queue. In CI, this is auto-detected from environment variables.

4. **Worker ID uniqueness**: Each worker needs a unique `--worker` ID for proper tracking and retry functionality.

### Minitest-Specific

1. **Don't overwrite Minitest reporters**: ci-queue registers custom reporters for tracking. Check if reporters exist before calling `Minitest::Reporters.use!`:
   ```ruby
   if Minitest::Reporters.reporters.nil?
     Minitest::Reporters.use!(SomeReporter.new)
   end
   ```

### RSpec-Specific

1. **`before(:all)` and `after(:all)` are REJECTED**: These hooks don't work with ci-queue's execution model. Use `before(:each)` / `after(:each)` instead. The system will explicitly reject attempts to use these hooks.

2. **`before(:suite)` runs per worker, not globally**: Don't rely on suite hooks for shared state across all workers. They execute once per worker process.

3. **Custom formatters must not replace ci-queue formatters**: If adding custom RSpec formatters, use `add_formatter`, not `formatters=` which would clear ci-queue's `BuildStatusRecorder` and `OrderRecorder`.

4. **Examples must be independently executable**: Each example may run in isolation on any worker. Don't depend on execution order or state from other examples.

## Testing Tips

- Most tests require Redis to be running (via `REDIS_URL` environment variable)
- Use `SimpleCov` for coverage reports (automatically started in `test/test_helper.rb`)
- Integration tests are in `test/integration/`
- Test support utilities are in `test/support/`
