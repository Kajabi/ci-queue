# frozen_string_literal: true
require 'test_helper'
require 'rspec/queue'

module RSpec::Queue
  class WatchdogTest < Minitest::Test
    def setup
      @now = 100.0
      @fired = 0
      @err = StringIO.new
      @watchdog = Watchdog.new(
        timeout: 10,
        worker_id: '7',
        err: @err,
        clock: -> { @now },
        on_timeout: -> { @fired += 1 },
      )
    end

    def test_does_not_fire_before_the_deadline
      refute @watchdog.check!(109.9)
      assert_equal 0, @fired
      assert_empty @err.string
    end

    def test_fires_once_the_idle_time_reaches_the_timeout
      @watchdog.phase!('running ./spec/foo_spec.rb[1:1]')

      assert @watchdog.check!(110.0)
      assert_equal 1, @fired
      report = @err.string
      assert_includes report, '[ci-queue watchdog] no activity for 10.0s (limit 10s)'
      assert_includes report, 'while: running ./spec/foo_spec.rb[1:1]'
      assert_includes report, "(worker 7, pid #{Process.pid})"
      assert_match(/watchdog_test\.rb/, report)
    end

    def test_report_lists_the_main_thread_first
      report = @watchdog.report(110.0)
      threads = report.lines.grep(/^--- Thread /)

      assert_includes threads.first, '(main)'
    end

    def test_phase_resets_the_deadline
      @now = 109.0
      @watchdog.phase!('after(:suite) hooks')
      @now = 118.0

      refute @watchdog.check!(118.0)
      assert_equal 0, @fired
    end

    def test_touch_resets_the_deadline
      @now = 109.0
      @watchdog.touch!

      refute @watchdog.check!(118.0)
      assert_equal 0, @fired
    end

    def test_fires_only_once
      assert @watchdog.check!(110.0)
      refute @watchdog.check!(120.0)
      refute @watchdog.check!(130.0)
      assert_equal 1, @fired
    end

    def test_stop_prevents_firing
      @watchdog.stop

      refute @watchdog.check!(200.0)
      assert_equal 0, @fired
    end

    def test_build_returns_a_disabled_watchdog_without_a_timeout
      watchdog = Watchdog.build(CI::Queue::Configuration.new)

      assert_instance_of Watchdog::Disabled, watchdog
      assert_nil watchdog.phase!('anything')
      assert_nil watchdog.touch!
      assert_nil watchdog.stop
    end

    def test_build_returns_a_started_watchdog_with_a_timeout
      watchdog = Watchdog.build(CI::Queue::Configuration.new(watchdog_timeout: 1000, worker_id: '3'))

      assert_instance_of Watchdog, watchdog
      assert_equal 1000, watchdog.timeout
      assert(Thread.list.any? { |thread| thread.name == 'RSpec::Queue::Watchdog' })
    ensure
      watchdog&.stop
    end

    def test_background_thread_fires_after_the_timeout
      fired = Thread::Queue.new
      watchdog = Watchdog.new(timeout: 0.05, interval: 0.01, err: StringIO.new, on_timeout: -> { fired << :fired })
      watchdog.start

      assert_equal :fired, fired.pop(timeout: 2)
    ensure
      watchdog&.stop
    end
  end
end
