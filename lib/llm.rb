class LLM
  def initialize(logger, endpoint, options, editor = nil, default_params = {})
    @logger = logger
    @uri = URI.parse(endpoint)
    @options = options
    @editor = editor
    @default_params = default_params
  end
  def query(prompt, params = {}, stop_at = nil, &block)
    params = @default_params.merge(params)
    uri = @uri.dup
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = {
      prompt: prompt,
      stream: true,
    }.to_json

    json_found = false
    full_response = ""

    begin
      bracket_count = 0
      current_json = ""

      Net::HTTP.start(uri.hostname, uri.port) do |http|
        http.request(request) do |response|
          response.read_body do |chunk|
            begin
              chunk.strip!
              if chunk.start_with?('data: ')
                content = JSON.parse(chunk[6..-1])["content"]
                if content && !content.strip.empty?
                  print content
                  $stdout.flush
                  full_response += content
                  if stop_at && full_response.include?(stop_at)
                    return full_response
                  end
                  # Track brackets for JSON extraction
                  content.each_char do |char|
                    case char
                    when '{'
                      bracket_count += 1
                      current_json += char
                    when '}'
                      bracket_count -= 1
                      current_json += char
                      if bracket_count == 0 && !current_json.strip.empty?
                        # Found a complete JSON
                        json_found = true
                        if @options[:edit]
                          edited_json = edit_response_with_timeout(current_json, @options[:timeout])
                          block.call(edited_json)
                        else
                          block.call(current_json)
                        end
                        return
                      end
                    else
                      current_json += char unless (bracket_count == 0 && char.strip.empty?)
                    end
                  end
                end
              end
            rescue JSON::ParserError => e
              @logger.error("Error parsing chunk: #{e}")
              return full_response
            end
          end
        end
      end

      # If we reach here, no complete JSON was found
      if !json_found
        # Optionally edit the full_response before returning
        if @options[:edit]
          edited = edit_response_with_timeout(full_response)
          return edited
        else
          return full_response
        end
      end

    rescue StandardError => e
      @logger.error("Error: #{e}")
      # Return whatever was accumulated so far
      if @options[:edit]
        edited = edit_response_with_timeout(full_response)
        return edited
      else
        return full_response
      end
    end
  end
  def edit_response_with_timeout(json_response)
    return json_response if !@editor

    puts "\nPress any key to open the editor for response editing..."

    IO.select([$stdin], nil, nil, @options[:timeout]) do
      c = $stdin.getc
      if c
        temp_file = Tempfile.new('llm_response')
        temp_file.write(JSON.pretty_generate(JSON.parse(json_response), array_nl: '', indent: ''))
        temp_file.close
        
        puts "\nOpening editor for response editing..."
        status = system("#{@editor} #{temp_file.path}")

        if !status
          puts "Editor exited with an error. Using original response."
          return json_response
        end

        if File.exist?(temp_file.path) && File.size(temp_file.path) > 0
          edited_content = File.read(temp_file.path)
          begin
            JSON.parse(edited_content)
            return edited_content
          rescue JSON::ParserError => e
            puts "Warning: The edited response is not valid JSON. Using original response."
            return json_response
          ensure
            temp_file.unlink
          end
        else
          puts "File not found. Using original response."
          return json_response
        end
      end
    end
    json_response
  end
end