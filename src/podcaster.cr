require "process"
require "json"
require "uri"

module Podcaster
  class_property ytdlp_proxy, temp_files_dir
  @@ytdlp_proxy = "http://127.0.0.1:2080"
  @@temp_files_dir = Path.new "/mnt/tmpfs"

  class Command
    class RecoverableError < Exception
      class_property substrings
      @@substrings = [
        "SSL: UNEXPECTED_EOF_WHILE_READING", "Unable to connect to proxy",
        "Read timed out.", "Unable to fetch PO Token for mweb client", "IncompleteRead",
        "Remote end closed connection without response", "Cannot connect to proxy.",
        "Temporary failure in name resolution", "timed out. (connect timeout",
        "Connection reset by peer",
      ]
    end

    class FatalError < Exception
      class_property substrings
      @@substrings = [
        "No video formats found!;", "The page doesn't contain any tracks;",
        "Sign in to confirm your age", ": Premieres in ",
        ": Requested format is not available",
        "Postprocessing: Error opening output files: Invalid argument",
        "members-only content like this video",
      ]
    end

    def initialize(@command : String, @args : Enumerable(String))
      @process = Process.new command, args,
        {"http_proxy" => Podcaster.ytdlp_proxy, "https_proxy" => Podcaster.ytdlp_proxy},
        output: :pipe, error: :pipe,
        chdir: Podcaster.temp_files_dir
    end

    def result
      output = @process.output.gets_to_end
      error = @process.error.gets_to_end
      ec = @process.wait.exit_code
      raise Exception.new "No exit code for process #{@command} #{@args}" if ec == nil
      if ec != 0
        raise RecoverableError.new "#{@command} #{@args}" if RecoverableError.substrings.any? { |sub| error.includes? sub }
        raise FatalError.new "#{@command} #{@args}" if FatalError.substrings.any? { |sub| error.includes? sub }
      end
      output
    end
  end

  class Cache
    @@dir = (Path.new.posix? ? Path.new("~", ".local", "share", "podcaster_cr") : Path.new("~", "AppData", "podcaster_cr")).expand(home: true)

    @items : Set(JSON::Any) = Set(JSON::Any).new
    @path : Path

    def initialize(name : String)
      @path = @@dir / "#{name}.txt"
      if File.exists? @path
        File.each_line @path do |line|
          @items << JSON.parse line
        end
      else
        Dir.mkdir_p @@dir
      end
    end

    def <<(item : JSON::Any)
      return if @items.includes? item
      @items << item
      File.write @path, item.to_json + "\n", mode: "a"
    end

    def includes?(item : JSON::Any)
      @items.includes? item
    end
  end

  struct Item
    getter url : URI
    getter performer : String?
    getter title : String
    getter duration : Time::Span

    def initialize(@url, performer : String, @title, @duration)
      performer = performer.sub(/Various Artists? *(?:-|—)? */, "").strip
      @title = @title.sub(/Various Artists? *(?:-|—)? */, "").strip

      if performer == "" || performer == "NA"
        splitted = @title.split(/-|—/, 1).map &.strip
        return if splitted.size == 1
        @performer, @title = splitted
      else
        @performer = performer
      end

      @title = @title.sub(/#{@performer} ?-|—/, "").strip
    end
  end

  class UrlError < Exception
  end

  class Bandcamp
    def initialize(@artist_id : String)
      @artist_url = URI.new "http", "#{artist_id}.bandcamp.com"
      @cache = Cache.new artist_id
    end

    protected def cache_item(url : URI)
      JSON::Any.new url.path
    end

    def items(start_after_album_id : String? = nil, &)
      Command.new("yt-dlp", ["--flat-playlist", "--proxy", "",
                             "--print", "url", @artist_url.to_s])
        .result.lines.reverse
        .map { |line| URI.parse line }
        .skip_while { |url| start_after_album_id && (Path.new(url.path).basename != start_after_album_id) }.skip(1)
        .select { |url| !@cache.includes? cache_item url }
        .each do |album_url|
          Command.new("yt-dlp", ["--flat-playlist", "--proxy", "",
                                 "--print", "url", album_url.to_s])
            .result.lines
            .map { |line| URI.parse line }
            .select { |url| !@cache.includes? cache_item url }
            .each do |track_url|
              Command.new("yt-dlp", ["--flat-playlist", "--proxy", "",
                                     "--print", "uploader",
                                     "--print", "title",
                                     "--print", "duration", track_url.to_s])
                .result.lines
                .each_slice 3 do |track_info|
                  yield item = Item.new track_url, track_info[0], track_info[1], track_info[2].to_f.seconds
                  @cache << cache_item track_url
                end
            end
          @cache << cache_item album_url
        end
    end
  end
end

bandcamp = Podcaster::Bandcamp.new "archeannights"
bandcamp.items "long-forgotten-cities-ii" do |item|
  puts item
end
