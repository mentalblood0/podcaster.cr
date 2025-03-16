require "json"

module Podcaster
  class Cache
    @@dir = (Path.new.posix? ? Path.new("~", ".local", "share", "podcaster_cr") : Path.new("~", "AppData", "podcaster_cr", "cache")).expand(home: true)

    @entries : Set(JSON::Any) = Set(JSON::Any).new
    @path : Path

    def initialize(name : String)
      @path = @@dir / "#{name}.txt"
      if File.exists? @path
        File.each_line @path do |line|
          @entries << JSON.parse line
        end
      else
        Dir.mkdir_p @@dir
      end
    end

    def <<(entry : JSON::Any)
      return if @entries.includes? entry
      @entries << entry
      File.write @path, entry.to_json + "\n", mode: "a"
    end

    def includes?(entry : JSON::Any)
      @entries.includes? entry
    end
  end
end
