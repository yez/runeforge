# frozen_string_literal: true

module Runeforge
  # A throwaway directory for one attempt. It holds an export of the code (no host .git) plus
  # the .runeforge/ folder used to hand the prompt in and the patch and reports back out.
  class Workspace
    class UnsafeFile < Error; end

    META_DIR = ".runeforge"

    attr_reader :path

    def self.create(root:, name:)
      FileUtils.mkdir_p(root)
      new(Dir.mktmpdir("#{name}-", root))
    end

    def initialize(path)
      @path = File.realpath(path)
    end

    def meta_dir = File.join(path, META_DIR)

    def write_meta(name, content)
      FileUtils.mkdir_p(meta_dir)
      File.write(File.join(meta_dir, name), content)
    end

    # Reads a file the sandbox left behind. Symlinks, non-regular files and oversized files are
    # rejected so an agent can't make the host read something outside the workspace.
    def read_meta(name, max_bytes:)
      return nil if File.symlink?(meta_dir) || !File.directory?(meta_dir)

      file = File.join(meta_dir, name)
      return nil unless File.exist?(file) || File.symlink?(file)

      File.open(file, File::RDONLY | File::NOFOLLOW) do |io|
        stat = io.stat
        raise UnsafeFile, "#{META_DIR}/#{name} is not a regular file" unless stat.file?
        raise UnsafeFile, "#{META_DIR}/#{name} is #{stat.size} bytes (limit #{max_bytes})" if stat.size > max_bytes

        io.binmode.read
      end
    rescue Errno::ELOOP
      raise UnsafeFile, "#{META_DIR}/#{name} is a symlink"
    end

    def cleanup!
      FileUtils.rm_rf(path)
    end
  end
end
