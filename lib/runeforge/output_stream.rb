# frozen_string_literal: true

module Runeforge
  # Turns a role's live output into agent.output events. Writes are buffered and flushed every
  # flush_seconds (or once a chunk is big enough), so a chatty process costs a few rows a second,
  # not one per line. Output past max_bytes is dropped with a note; the full log is still written
  # to the task's log directory.
  class OutputStream
    CHUNK_BYTES = 4_096

    def initialize(db, msg, flush_seconds: 0.5, max_bytes: 262_144)
      @db = db
      @msg = msg
      @flush_seconds = flush_seconds
      @max_bytes = max_bytes
      @sent = 0
      @buffers = Hash.new { |hash, key| hash[key] = +"" }
      @mutex = Mutex.new
      @timer = nil
    end

    def write(text, stream: "stdout")
      text = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      return if text.empty?

      flush_now = @mutex.synchronize do
        @buffers[stream] << text
        @buffers[stream].bytesize >= CHUNK_BYTES
      end
      flush_now ? flush : start_timer
    end

    alias << write

    # One line of narration, for roles that report progress rather than run a process.
    def say(line) = write("#{line}\n")

    # Streams files a sandboxed process appends to (it writes them in the mounted workspace)
    # while the block runs. Files are opened without following symlinks, like Workspace#read_meta.
    def follow(paths)
      offsets = paths.to_h { |stream, _path| [stream, 0] }
      stop = false
      tailer = Thread.new do
        until stop
          sleep @flush_seconds
          offsets.each_key { |stream| offsets[stream] = read_from(paths[stream], offsets[stream], stream) }
        end
      end
      yield
    ensure
      stop = true
      tailer&.join
      offsets&.each_key { |stream| read_from(paths[stream], offsets[stream], stream) }
    end

    def flush
      chunks = @mutex.synchronize do
        @buffers.filter_map do |stream, buffer|
          next if buffer.empty?

          text = buffer.dup
          buffer.clear
          [stream, text]
        end
      end
      chunks.each { |stream, text| emit(text, stream) }
    end

    def close
      @timer&.kill
      @timer = nil
      flush
    end

    private

    def emit(text, stream)
      return if @sent >= @max_bytes

      room = @max_bytes - @sent
      text = "#{text.byteslice(0, room).scrub}\n[output truncated]\n" if text.bytesize > room
      @sent += text.bytesize
      Events.output(@db, @msg, text:, stream:)
    rescue Sequel::Error
      nil # live output is best-effort; never fail the work over it
    end

    def start_timer
      @mutex.synchronize do
        return if @timer&.alive?

        @timer = Thread.new do
          sleep @flush_seconds
          @mutex.synchronize { @timer = nil }
          flush
        end
      end
    end

    def read_from(path, offset, stream)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |io|
        return offset unless io.stat.file?

        io.seek(offset)
        data = io.read(CHUNK_BYTES * 16).to_s
        write(data, stream:) unless data.empty?
        offset + data.bytesize
      end
    rescue Errno::ENOENT, Errno::ELOOP, IOError
      offset
    end
  end
end
