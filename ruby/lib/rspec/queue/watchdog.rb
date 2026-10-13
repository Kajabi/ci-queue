# frozen_string_literal: true
module RSpec
  module Queue
    class Watchdog
      EXIT_CODE = 43

      class Disabled
        def start; self; end
        def stop; end
        def phase!(_name); end
        def touch!; end
      end

      def self.build(config)
        return Disabled.new if config.watchdog_timeout.nil?

        new(timeout: config.watchdog_timeout, worker_id: config.worker_id).start
      end

      attr_reader :timeout

      def initialize(timeout:, worker_id: nil, err: $stderr, out: $stdout,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     on_timeout: nil, interval: 1)
        @timeout = timeout
        @worker_id = worker_id
        @err = err
        @out = out
        @clock = clock
        @interval = interval
        @on_timeout = on_timeout || method(:abort_process)
        @mutex = Mutex.new
        @phase = 'starting'
        @last_activity = clock.call
        @stopped = false
        @fired = false
        @thread = nil
      end

      def start
        @mutex.synchronize do
          return self if @thread

          @thread = Thread.new { run_loop }
          @thread.name = 'RSpec::Queue::Watchdog'
          @thread.report_on_exception = false
        end
        self
      end

      def stop
        thread = @mutex.synchronize do
          @stopped = true
          @thread
        end
        begin
          thread&.wakeup
        rescue ThreadError
          nil
        end
      end

      def phase!(name)
        now = @clock.call
        @mutex.synchronize do
          @phase = name
          @last_activity = now
        end
      end

      def touch!
        now = @clock.call
        @mutex.synchronize { @last_activity = now }
      end

      def check!(now = @clock.call)
        fire = @mutex.synchronize do
          next false if @stopped || @fired
          next false if now - @last_activity < @timeout

          @fired = true
        end
        return false unless fire

        @err.puts(report(now))
        @on_timeout.call
        true
      end

      def report(now)
        phase, last_activity = @mutex.synchronize { [@phase, @last_activity] }
        idle = format('%.1f', now - last_activity)
        lines = []
        lines << "[ci-queue watchdog] no activity for #{idle}s (limit #{@timeout}s) while: #{phase} " \
                 "(worker #{@worker_id}, pid #{Process.pid})"
        lines << ''
        lines << process_tree
        lines << ''
        lines.concat(thread_dump)
        lines.join("\n")
      end

      private

      def run_loop
        until @mutex.synchronize { @stopped }
          sleep @interval
          begin
            break if check!
          rescue StandardError => error
            @err.puts("[ci-queue watchdog] check failed: #{error.class}: #{error.message}")
          end
        end
      end

      # exit! skips at_exit hooks, which may be the very thing that is stuck.
      def abort_process
        @out.flush
        @err.flush
        Process.exit!(EXIT_CODE)
      end

      def process_tree
        output = IO.popen(['ps', '-eo', 'pid,ppid,stat,etime,command'], err: File::NULL, &:read)
        header, *rows = output.lines.map(&:rstrip)
        children = Hash.new { |hash, key| hash[key] = [] }
        rows.each do |row|
          pid, ppid = row.split.first(2).map(&:to_i)
          children[ppid] << pid
        end
        # Keep only this process and its descendants.
        wanted = [Process.pid]
        wanted.each { |pid| wanted.concat(children[pid]) }
        kept = rows.select { |row| wanted.include?(row.split.first.to_i) }
        [header, *kept].join("\n")
      rescue StandardError, SystemCallError => error
        "(ps unavailable: #{error.message})"
      end

      def thread_dump
        main, others = Thread.list.partition { |thread| thread == Thread.main }
        (main + others).flat_map do |thread|
          header = "--- Thread #{thread.name || thread.inspect} status=#{thread.status || 'dead'}"
          header += ' (main)' if thread == Thread.main
          backtrace = thread.backtrace
          [header, *(backtrace.nil? || backtrace.empty? ? ['(no backtrace)'] : backtrace), '']
        end
      end
    end
  end
end
