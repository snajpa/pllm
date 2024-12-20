class Tmux
  def initialize(session_name, window_x, window_y)
    @session_name = session_name
    @window_x = window_x
    @window_y = window_y

    system("tmux", "new-session", "-d", "-s", @session_name, "-n", "main")
    system("tmux", "set-option", "-t", @session_name, "status", "off")
    system("tmux", "resize-pane", "-t", @session_name, "-x", "#{@window_x}", "-y", "#{@window_y}")
    system("tmux", "send-keys", "-t", @session_name, "clear", "Enter")
    sleep(1) # Give time for the shell to initialize
  end

  def send_keys(keys)
    keys.each do |key|
      # Send keys to tmux exactly as provided by the LLM.
      # Using array form of system call to avoid shell parsing.
      if key == " "
        key = "Space"
      end
      system("tmux", "send-keys", "-t", @session_name, "--", key)
      sleep 0.05
      #puts "Sent key: #{key}"
      #sleep(0.5)  # Small delay between key presses
    end
  end

  def capture_output
    stdout, stderr, status = Open3.capture3("tmux capture-pane -pt #{@session_name}")
    raise "TMux capture error: #{stderr}" unless status.success?
  
    lines = stdout.lines.map(&:chomp)
    normalized_output = lines.map { |line| line.ljust(@window_x)[0,@window_x] }
    normalized_output += Array.new(@window_y - normalized_output.size, ' ' * @window_x) if normalized_output.size < @window_y
  
    cursor_position = get_cursor_position()

    content_lines = normalized_output.map.with_index do |line, idx|
      line_with_number = "#{idx.to_s.rjust(2)} |#{line}"
      if idx == cursor_position[:y]
        begin
          line_with_number[cursor_position[:x] + 4] = '█'
        rescue
          # In case the cursor position is out of range
        end
      end
      line_with_number
    end
  
    {
      content: content_lines.join("\n"),
      cursor: cursor_position
    }
  end

  def get_cursor_position
    stdout, stderr, status = Open3.capture3("tmux display-message -p -t #{@session_name}:0 '\#{cursor_x},\#{cursor_y}'")
    raise "Cursor position retrieval error: #{stderr}" unless status.success?
    x, y = stdout.split(',').map(&:to_i)
    { x: x, y: y }
  end

  def cleanup
    system("tmux", "kill-session", "-t", @session_name)
  end
end