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

    @process : Process

    def initialize(@command : String, @args : Enumerable(String))
      @process = run
    end

    def run
      Process.new @command, @args, output: :pipe, error: :pipe
    end

    def result
      loop do
        output = @process.output.gets_to_end
        error = @process.error.gets_to_end
        ec = @process.wait.exit_code
        raise Exception.new "No exit code for process #{@command} #{@args}" if ec == nil
        if ec != 0
          puts "error executing #{@command} #{@args}: #{error}" if error.size > 1
          raise FatalError.new "#{@command} #{@args}" if FatalError.substrings.any? { |sub| error.includes? sub }
          if RecoverableError.substrings.any? { |sub| error.includes? sub }
            @process = run
            next
          end
        end
        return output
      end
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

    def to_s(io : IO)
      io.print "#{performer} - #{title} (#{url})"
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

  class Downloaded
    getter item : Item
    getter audio : Path
    getter thumbnail : Path

    def initialize(@item, @audio, @thumbnail)
    end

    def to_s(io : IO)
      io.print "#{item.performer} - #{item.title} (#{audio}, #{thumbnail})"
    end
  end

  class Downloader
    @thumbnails_cache = {} of URI => Path

    def initialize(@bitrate : Int16?,
                   @conversion_params : ConversionParams?,
                   @thumbnail_side_size : Int16,
                   @audio_proxy : URI?,
                   @thumbnail_proxy : URI?)
      at_exit { finalize }
    end

    protected def audio(item : Item)
      format = @bitrate ? "ba[abr<=#{@bitrate}]/wa[abr>=#{@bitrate}]" : "mp3"
      Log.info { "<-- #{item}" }
      downloaded = File.tempname ".mp3"
      Command.new("yt-dlp", ["--proxy", @audio_proxy.to_s, "--force-overwrites", "-f", format,
                             "-o", downloaded, item.url.to_s]).result
      return Path.new(downloaded) if !@conversion_params
      cp = @conversion_params.not_nil!
      converted = File.tempname ".mp3"
      Command.new("ffmpeg", ["-i", downloaded, "-vn",
                             "-ar", cp.samplerate.to_s,
                             "-ac", cp.stereo ? "2" : "1",
                             "-b:a", "#{cp.bitrate}k", converted]).result
      File.delete downloaded
      Path.new converted
    end

    protected def thumbnail(item : Item)
      if !@thumbnails_cache.has_key? item.thumbnail
        downloaded = File.tempname
        Command.new("yt-dlp", ["--proxy", @thumbnail_proxy.to_s,
                               item.thumbnail.to_s, "-o", downloaded]).result

        converted = File.tempname ".png"
        Command.new("ffmpeg", ["-y", "-i", downloaded, converted]).result
        File.delete downloaded

        resized = File.tempname ".png"
        s = @thumbnail_side_size
        Command.new("ffmpeg", ["-y", "-i", converted, "-vf",
                               "scale=#{s}:#{s}:force_original_aspect_ratio=increase,crop=#{s}:#{s}", resized]).result
        File.delete converted
        @thumbnails_cache[item.thumbnail] = Path.new resized
      end
      @thumbnails_cache[item.thumbnail]
    end

    def download(item : Item)
      Downloaded.new item, audio(item), thumbnail(item)
    end

    def finalize
      @thumbnails_cache.each_value { |path| File.delete path }
    end
  end

  class Uploader
    @@max_size = 48 * 1024 * 1024

    def initialize(@token : String)
    end

    protected def split(input : Downloaded, &)
      parts = (File.size(input.audio) / @@max_size).ceil
      output_duration = input.item.duration / parts
      workers = [] of NamedTuple(command: Command, output: Downloaded)
      (0..parts - 1).each do |i|
        output = Downloaded.new(
          item: Item.new(input.item.url, input.item.performer.to_s, "#{input.item.title} - #{i + 1}", output_duration, input.item.thumbnail),
          audio: Path.new(File.tempname(".mp3")),
          thumbnail: input.thumbnail)
        command = Command.new "ffmpeg", ["-y", "-hide_banner", "-loglevel", "error",
                                         "-ss", (output_duration * i).total_seconds.to_s,
                                         "-i", input.audio.to_s,
                                         "-t", output_duration.total_seconds.to_s, "-acodec", "copy", output.audio.to_s]
        workers << {command: command, output: output}
      end
      workers.each do |worker|
        worker[:command].result
        yield worker[:output]
      end
    end

    def upload(downloaded : Downloaded, chat_id : String)
      size = File.size downloaded.audio
      if size > @@max_size
        split(downloaded) { |part| upload part, chat_id }
      else
        io = IO::Memory.new
        builder = HTTP::FormData::Builder.new io
        builder.field "chat_id", chat_id
        builder.field "title", downloaded.item.title
        builder.field "performer", downloaded.item.performer
        builder.field "duration", downloaded.item.duration.total_seconds
        builder.field "disable_notification", true
        builder.file "audio",
          File.new(downloaded.audio),
          HTTP::FormData::FileMetadata.new(filename: "audio"),
          HTTP::Headers{"Content-Type" => "audio/mpeg"}
        builder.file "thumbnail",
          File.new(downloaded.thumbnail),
          HTTP::FormData::FileMetadata.new(filename: "thumbnail"),
          HTTP::Headers{"Content-Type" => "image/png"}
        builder.finish
        body = io.to_s
        headers = HTTP::Headers{"Content-Type" => builder.content_type}

        Log.info { "--> #{downloaded}" }
        loop do
          response = begin
            HTTP::Client.post("https://api.telegram.org/bot#{@token}/sendAudio", headers: headers, body: body)
          rescue ex
            Log.warn { "Exception when sending: '#{ex.message}', retrying in 0.2 seconds" }
            sleep 0.2.seconds
            next
          end
          break if response.success?
          Log.warn { "Non-success response with status code #{response.status_code}: #{response.body?}" }
          sleep 1.seconds
        end
      end
      File.delete downloaded.audio
    end
  end
end

proxy = URI.parse "http://127.0.0.1:2080"

bandcamp = Podcaster::Bandcamp.new "weltlandschaft", proxy
downloader = Podcaster::Downloader.new bitrate: 128,
  conversion_params: nil,
  thumbnail_side_size: 200,
  audio_proxy: nil, thumbnail_proxy: proxy
uploader = Podcaster::Uploader.new "token here"
chat_id = "-1002328331030"

bandcamp.items start_after_album_id: "bin-tepe" do |item|
  downloaded = downloader.download(item)
  uploader.upload downloaded, chat_id
end
