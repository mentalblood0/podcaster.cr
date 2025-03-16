require "http/client"
require "yaml"

module Podcaster
  class Uploader
    @@max_size = 48 * 1024 * 1024

    include YAML::Serializable

    @token : String

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
      File.delete? downloaded.audio
    end
  end
end
