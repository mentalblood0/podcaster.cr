require "http/client"
require "process"
require "json"
require "log"
require "uri"

module Podcaster
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
      # puts "#{@command} #{@args}"
      @process = Process.new command, args, output: :pipe, error: :pipe
    end

    def result
      output = @process.output.gets_to_end
      # puts "output: #{output}" if output.size > 1
      error = @process.error.gets_to_end
      # puts "error: #{error}" if error.size > 1
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

  struct Item
    getter url : URI
    getter performer : String?
    getter title : String
    getter duration : Time::Span
    getter thumbnail : URI

    def initialize(@url, performer : String, @title, @duration, @thumbnail)
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
    def initialize(artist_id : String, @proxy : URI? = nil)
      @artist_url = URI.new "http", "#{artist_id}.bandcamp.com"
      @cache = Cache.new artist_id
    end

    protected def cache_entry(url : URI)
      JSON::Any.new url.path
    end

    def items(start_after_album_id : String? = nil, &)
      Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                             "--print", "url", @artist_url.to_s])
        .result.lines.reverse
        .map { |line| URI.parse line }
        .skip_while { |url| start_after_album_id && (Path.new(url.path).basename != start_after_album_id) }.skip(1)
        .select { |url| !@cache.includes? cache_entry url }
        .each do |album_url|
          Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                 "--print", "url", album_url.to_s])
            .result.lines
            .map { |line| URI.parse line }
            .select { |url| !@cache.includes? cache_entry url }
            .each do |track_url|
              Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                     "--print", "uploader",
                                     "--print", "title",
                                     "--print", "duration",
                                     "--print", "thumbnail", track_url.to_s])
                .result.lines
                .each_slice 4 do |track_info|
                  yield item = Item.new track_url, track_info[0], track_info[1], track_info[2].to_f.seconds, URI.parse track_info[3]
                  @cache << cache_entry track_url
                end
            end
          @cache << cache_entry album_url
        end
    end
  end

  class ConversionParams
    getter bitrate : Int16
    getter samplerate : Int16
    getter stereo : Bool

    def initialize(@bitrate, @samplerate, @stereo)
    end
  end

  class Downloader
    @thumbnails_cache = {} of URI => File

    def initialize(@bitrate : Int16?,
                   @conversion_params : ConversionParams?,
                   @thumbnail_side_size : Int16,
                   @audio_proxy : URI?,
                   @thumbnail_proxy : URI?)
      at_exit { finalize }
    end

    def audio(item : Item)
      format = @bitrate ? "ba[abr<=#{@bitrate}]/wa[abr>=#{@bitrate}]" : "mp3"
      Log.info { "<-- #{item.url}" }
      downloaded = File.tempfile ".mp3"
      Command.new("yt-dlp", ["--proxy", @audio_proxy.to_s, "--force-overwrites", "-f", format,
                             "-o", downloaded.path, item.url.to_s]).result
      return downloaded if !@conversion_params
      cp = @conversion_params.not_nil!
      converted = File.tempfile ".mp3"
      Command.new("ffmpeg", ["-i", downloaded.path, "-vn",
                             "-ar", cp.samplerate.to_s,
                             "-ac", cp.stereo ? "2" : "1",
                             "-b:a", "#{cp.bitrate}k", converted.path]).result
      downloaded.delete
      converted
    end

    def thumbnail(item : Item)
      if !@thumbnails_cache.has_key? item.thumbnail
        downloaded_path = File.tempname
        Command.new("yt-dlp", ["--proxy", @thumbnail_proxy.to_s,
                               item.thumbnail.to_s, "--force-overwrites",
                               "-o", downloaded_path]).result

        converted = File.tempfile ".png"
        Command.new("ffmpeg", ["-y", "-i", downloaded_path, converted.path]).result
        File.delete downloaded_path

        resized = File.tempfile ".png"
        s = @thumbnail_side_size
        Command.new("ffmpeg", ["-y", "-i", converted.path, "-vf",
                               "scale=#{s}:#{s}:force_original_aspect_ratio=increase,crop=#{s}:#{s}", resized.path]).result
        converted.delete
        @thumbnails_cache[item.thumbnail] = resized
      end
      @thumbnails_cache[item.thumbnail]
    end

    def finalize
      @thumbnails_cache.each_value &.delete
    end
  end
end

proxy = URI.parse "http://127.0.0.1:2080"

bandcamp = Podcaster::Bandcamp.new "archeannights", proxy
downloader = Podcaster::Downloader.new bitrate: 128,
  conversion_params: nil,
  thumbnail_side_size: 200,
  audio_proxy: nil, thumbnail_proxy: proxy

bandcamp.items start_after_album_id: "long-forgotten-cities-ii" do |item|
  puts downloader.audio(item).path
  puts downloader.thumbnail(item).path
end
