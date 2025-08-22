require "yaml"
require "uri/yaml"
require "uri"

require "./cache.cr"
require "./common.cr"
require "./command.cr"

module Podcaster
  abstract class Parser
    include YAML::Serializable

    getter proxy : URI?
    getter? only_cache : Bool = false

    use_yaml_discriminator "source", {bandcamp: Bandcamp, youtube: Youtube}

    abstract def items(task : Task, & : Item ->)
  end

  class Bandcamp < Parser
    protected def cache_entry(url : URI)
      JSON::Any.new url.path
    end

    def items(task : Task, &)
      artist_url = URI.parse "http://#{task.artist}.bandcamp.com/music"
      cache = Cache.new task.artist
      Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                             "--print", "url", artist_url.to_s])
        .result.lines.reverse!
        .map { |line| URI.parse line }
        .skip_while do |url|
          cache << cache_entry url if only_cache?
          only_cache?
        end
        .select { |url| !cache.includes? cache_entry url }
        .each do |album_url|
          tracks_urls_output = Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                                      "--print", "webpage_url", album_url.to_s]).result rescue nil
          next if !tracks_urls_output
          tracks_urls_output.lines
            .map { |line| URI.parse line }
            .select { |url| !cache.includes? cache_entry url }
            .each do |track_url|
              track_info_output =
                Command.new("yt-dlp", ["--flat-playlist", "--proxy", @proxy.to_s,
                                       "--print", "uploader",
                                       "--print", "title",
                                       "--print", "duration",
                                       "--print", "thumbnail", track_url.to_s]).result rescue nil
              next if !track_info_output
              track_info_output.lines.in_slices_of(4)
                .select { |track_info| track_info[2] != "NA" }
                .map { |track_info| Item.new track_url, track_info[0], track_info[1], track_info[2].to_f.seconds, URI.parse track_info[3] }
                .each do |item|
                  cache << cache_entry track_url if yield item
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
      skipping = true
      Command.new("yt-dlp", ["--proxy", @proxy.to_s, "--flat-playlist", "--playlist-items", "::-1",
                             "--print", "url",
                             "--print", "title",
                             "--print", "duration", artist_url(task).to_s])
        .result.lines.in_slices_of(3)
        .map { |track_info| {url: URI.parse(track_info[0]), title: track_info[1], duration: track_info[2]} }
        .select { |track_info| track_info[:duration] != "NA" }
        .map { |track_info| {url: track_info[:url], title: track_info[:title], duration: track_info[:duration].to_f.seconds} }
        .skip_while do |track_info|
          cache << cache_entry track_info[:title], track_info[:duration] if only_cache?
          only_cache?
        end
        .select { |track_info| !cache.includes? cache_entry track_info[:title], track_info[:duration] }
        .each do |track_info|
          thumbnail = URI.parse Command.new("yt-dlp", ["--proxy", @proxy.to_s, "--playlist-items", "1",
                                                       "--print", "thumbnail", track_info[:url].to_s]).result.strip rescue next
          cache << cache_entry track_info[:title], track_info[:duration] if yield Item.new track_info[:url], performer(task), track_info[:title], track_info[:duration], thumbnail
        end
    end
  end
end
