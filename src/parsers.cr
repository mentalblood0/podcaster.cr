require "yaml"
require "uri/yaml"
require "uri"

require "./cache.cr"
require "./common.cr"
require "./command.cr"

module Podcaster
  abstract class Parser
    include YAML::Serializable

    @proxy : URI?

    use_yaml_discriminator "source", {bandcamp: Bandcamp, youtube: Youtube}

    abstract def items(task : Task, & : Item ->)
  end

  class Bandcamp < Parser
    protected def cache_entry(url : URI)
      JSON::Any.new url.path
    end

    def items(task : Task, &)
      artist_url = URI.parse "http://#{task.artist}.bandcamp.com"
      cache = Cache.new task.artist
      Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                             "--print", "url", artist_url.to_s])
        .result.lines.reverse!
        .map { |line| URI.parse line }
        .skip_while { |url| task.start_after && (Path.new(url.path).basename != task.start_after) }.skip(1)
        .select { |url| !cache.includes? cache_entry url }
        .each do |album_url|
          Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                 "--print", "url", album_url.to_s])
            .result.lines
            .map { |line| URI.parse line }
            .select { |url| !cache.includes? cache_entry url }
            .each do |track_url|
              Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                     "--print", "uploader",
                                     "--print", "title",
                                     "--print", "duration",
                                     "--print", "thumbnail", track_url.to_s])
                .result.lines
                .each_slice 4 do |track_info|
                  yield Item.new track_url, track_info[0], track_info[1], track_info[2].to_f.seconds, URI.parse track_info[3]
                  cache << cache_entry track_url
                end
            end
          cache << cache_entry album_url
        end
    end
  end

  class Youtube < Parser
    getter performers_cache = {} of String => String

    protected def cache_entry(title : String, duration : Time::Span)
      JSON::Any.new Hash{"title" => JSON::Any.new(title), "duration" => JSON::Any.new(duration.total_seconds)}
    end

    protected def artist_url(task : Task)
      artist_url = URI.parse "http://www.youtube.com/#{task.artist}"
    end

    protected def performer(task : Task)
      if !performers_cache.includes? task.artist
        performers_cache[task.artist] = Command.new("yt-dlp", ["--proxy", @proxy.to_s, "--flat-playlist", "--playlist-items", "1",
                                                               "--print", "playlist_uploader", artist_url(task).to_s]).result.strip
      end
      performers_cache[task.artist]
    end

    def items(task : Task, &)
      cache = Cache.new task.artist.gsub /\W/, ""
      Command.new("yt-dlp", ["--proxy", @proxy.to_s, "--flat-playlist", "--playlist-items", "::-1",
                             "--print", "url",
                             "--print", "title",
                             "--print", "duration",
                             "--print", "thumbnail", artist_url(task).to_s])
        .result.lines
        .each_slice 4 do |track_info|
          url = URI.parse track_info[0]
          title = track_info[1]
          next if track_info[2] == "NA"
          duration = track_info[2].to_f.seconds
          next if cache.includes? cache_entry title, duration
          thumbnail = URI.parse Command.new("yt-dlp", ["--proxy", @proxy.to_s, "--playlist-items", "1",
                                                       "--print", "thumbnail", url.to_s]).result.strip
          yield Item.new url, performer(task), title, duration, thumbnail
        end
    end
  end
end
