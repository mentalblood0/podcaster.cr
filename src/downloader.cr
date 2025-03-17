require "yaml"
require "uri/yaml"

module Podcaster
  class Downloader
    class Audio
      class Conversion
        include YAML::Serializable

        getter bitrate : UInt16
        getter samplerate : UInt32
        getter? stereo : Bool
      end

      include YAML::Serializable

      getter bitrate : UInt16?
      getter proxy : URI?
      getter conversion : Conversion?
    end

    class Thumbnail
      include YAML::Serializable

      getter side_size : UInt16
      getter proxy : URI?
    end

    include YAML::Serializable

    @[YAML::Field(ignore: true)]
    @thumbnails_cache = {} of URI => Path

    getter audio : Audio
    getter thumbnail : Thumbnail

    def after_initialize
      at_exit { @thumbnails_cache.each_value { |path| File.delete? path } }
    end

    protected def audio(item : Item)
      format = @audio.bitrate ? "ba[abr<=#{@audio.bitrate}]/wa[abr>=#{@audio.bitrate}]" : "mp3"
      Log.info { "<-- #{item}" }
      downloaded = File.tempname
      Command.new("yt-dlp", ["--proxy", @audio.proxy.to_s, "--force-overwrites", "-f", format,
                             "-o", downloaded, item.url.to_s]).result
      return Path.new(downloaded) if !@audio.conversion
      cp = @audio.conversion.not_nil!
      converted = File.tempname ".mp3"
      Command.new("ffmpeg", ["-i", downloaded, "-vn",
                             "-ar", cp.samplerate.to_s,
                             "-ac", cp.stereo? ? "2" : "1",
                             "-b:a", "#{cp.bitrate}k", converted]).result
      File.delete? downloaded
      Path.new converted
    end

    protected def thumbnail(item : Item)
      if !@thumbnails_cache.has_key? item.thumbnail
        downloaded = File.tempname
        Command.new("yt-dlp", ["--proxy", @thumbnail.proxy.to_s,
                               item.thumbnail.to_s, "-o", downloaded]).result

        converted = File.tempname ".png"
        Command.new("ffmpeg", ["-y", "-i", downloaded, converted]).result
        File.delete? downloaded

        resized = File.tempname ".png"
        s = @thumbnail.side_size
        Command.new("ffmpeg", ["-y", "-i", converted, "-vf",
                               "scale=#{s}:#{s}:force_original_aspect_ratio=increase,crop=#{s}:#{s}", resized]).result
        File.delete? converted
        @thumbnails_cache[item.thumbnail] = Path.new resized
      end
      @thumbnails_cache[item.thumbnail]
    end

    def download(item : Item)
      Downloaded.new item, audio(item), thumbnail(item)
    end
  end
end
