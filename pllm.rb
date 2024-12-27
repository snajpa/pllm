#!/usr/bin/env ruby
require 'securerandom'
require 'net/http'
require 'uri'
require 'json'
require 'open3'
require 'time'
require 'logger'
require 'optparse'
require 'timeout'
require 'tempfile'

require './lib/llm'
require './lib/tmux'

# --- Constants ---
REEVAL_TIMES = 1
SELECT_TIMES = 1
EDIT_TIMEOUT = 5
HISTORY_LIMIT = 5
WINDOW_X = 80
WINDOW_Y = 24
LLAMA_API_ENDPOINT = 'http://localhost:8081/v1/completions'
DEFAULT_MISSION = '

There\'s a Linux dev machine reachable through SSH at snajpa@172.16.106.12.

On that machine, in /home/snajpa/linux/ directory, is a clone of vpsAdminOS Linux fork.

Start from a branch named "vpsadminos-6.12", which denotes it\'s based on 6.12 vanilla kernel.

There\'s about ~50 patches on top of some 6.12.x kernel and we need to port these on top of current linus/master (remote_name/branch_name).

The goal is to have a branch based on linus/master with all the patches from vpsadminos-6.12 branch in the end.

It\'s probably the best to start with a fresh branch based on linus/master and then cherry-pick patches from vpsadminos-6.12, but the user is not sure about the best approach nor the exact steps.

The target branch should be named "vpsadminos-6.13".

Pro-tips:
- You can use "git log --oneline" and Space to scroll through the log quicker.
- The PS1 has been enhanced to indicate current git branch and status.
'
LOG_FILE = 'pllm.log'

def build_main_prompt(mission, history, console_state, options, iteration_n)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = <<~PROMPT
  You are a specialized assistant guiding the user step by step in an environment without explicitly naming the underlying multiplexer. Each iteration, analyze the latest console output, mission, and limited history to propose exactly one carefully validated sequence of keypresses.

  Key requirements:
  • Provide extremely precise steps when navigating pagers (e.g. "Down", "PageDown", "Q" to quit pager) or editors (arrow keys and inserts).  
  • Never lump multiple distinct commands into a single iteration.  
  • For shell commands, type them character by character and end with "Enter".  
  • Forbidden: "C-d". If needed, use "C-c" to interrupt a process or "exit" to terminate the shell.  
  • All keypresses must be in a JSON array of strings, e.g. ["g", "i", "t", "Space", "p", "u", "l", "l", "Enter"].  
  • Maintain "branch_map" for the big-picture plan or relevant branching details, use arrows, mark your position, skip completed.
  • “next_move” describes the future immediate action or if we need to revisit a prior step.
  • Keep “reasoning” short and factual.  
  • “mission_complete” should be true only when the stated mission is fully done.  

  Return valid JSON with this shape:
  {
    "reasoning": "(brief reason)",
    "mission_complete": false,
    "branch_map": "(branching plan)",
    "keypresses": ["...","Enter"],
    "next_move": "(immediate next step or backtrack directive)"
  }

  You currently have #{ if options[:history_limit] > 1 then (options[:history_limit] - (iteration_n % options[:history_limit])) else 0 end } iteration steps left, so be efficient.

  =====================
  HISTORY SNIPPET:
  #{history}
  =====================

  MISSION:
  #{mission}

  CONSOLE (cursor at (#{cursor_position[:x]}, #{cursor_position[:y]})):
  #{console_content}

  Provide your JSON response now:
  ```json
  PROMPT
end

def build_summarization_prompt(full_log, mission, console_state)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  <<~SUMMARY_PROMPT
  You are tasked with summarizing a log for a LLM agent called 'pllm'. The agent's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The log contains detailed information about the interactions between the user and the AI system during the mission.

  Your output should serve as one summarizing entry in the Full log for the next iteration of the 'pllm' tool run.

  Extract the overall plan, substeps of the plan, steps already completed.

  Make sure to bring over solutions to any problems/errors encountered.

  Also bring over any previous summaries of older entries in the history.

  If there are any data relevant to the mission, make sure to always bring them over to the new summary too.

  Pay close attention to any repetitive behavior which doesn't seem to be making progress. Deduce the reason and suggest a solution.
  
  Provide a condensed summary of the current status based on log below.

  ------------------------------------------------------------------------------------
  Full Log:
  ------------------------------------------------------------------------------------
  #{full_log}
  ------------------------------------------------------------------------------------


  -----------------------------------------------------------------------------------
  Current console state after the last iteration:
  -----------------------------------------------------------------------------------
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
     --------------------------------------------------------------------------------
  #{console_content}
  -----------------------------------------------------------------------------------

  Report format instructions:
  - use only very brief bullet points, not full paragraphs, condense the points as much as possible.
  - be sure to use a new line after each bullet point.
  - produce the summarized condensed version of this history right after "Summary:".
  - when you're done with the Summary, end the report with "END_SUMMARY" and we're done.
  - you are limited to 390 characters, so be concise.

  REPORT
  ======

  Summary:
  SUMMARY_PROMPT
end

def build_critic_prompt(response, mission, console_state)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = \
  <<~EVAL_PROMPT
  You are tasked with evaluating a response from the system called 'pllm'. The system's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The user's mission:
  --
  #{mission}
  --

  Pllm has provided suggestions to our user. Your task is to evaluate the suggestions based on the current console state and the user's mission.

  Current console window size: (#{WINDOW_X}, #{WINDOW_Y})
  Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
  Current console state:
  #{console_content}

  The response from pllm:
  Reasoning: #{response['reasoning']}
  Keypresses array: #{response['keypresses']}
  Mission complete: #{response['mission_complete']}
  New branch map: #{response['branch_map']}
  Next step: #{response['next_move']}

  Will the suggested keypresses really deliver what was intended or could there be a mistake? For example, when the user is supposed to press Enter, you can't suggest pressing E, then n, then t, then e, then r. That's not the same as pressing Enter.

  Try to meditate on each individual press and its effect on the console state. Is the reasoning behind every individual key press sound?

  Isn't there any ommision in the keypresses? Is there any keypress that is not necessary?

  Be very careful and precise in your evaluation. The user's mission depends on it. But be quick, the user is waiting for your evaluation.

  Your output will be cut off after 390 characters, so be concise.

  After you're done, end with "END_EVALUATION".

  EVALUATION:
  EVAL_PROMPT
end

def build_select_prompt(options, responses, mission, keypresses_history, console_state, previous_next_move)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]

  prompt = \
  <<~SELECT_PROMPT
  You are tasked with selecting the best response from the LLM agent called 'pllm'. The agent's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The agent has provided multiple responses to a single prompt. Your task is to select the best response based on the context of the mission and the user's progress.

  It is possible that the agent made mistakes or provided incorrect suggestions.

  Analyze the responses and select the one that best aligns with the mission and the user's progress.

  Instructions for operating the console session:
  - The console output is always prepended with line numbers by the system for your convenience. These are not part of the actual console content.
  - The console window size is #{WINDOW_X} columns by #{WINDOW_Y} rows.
  - There are no scrollbars, so the console content is limited to the visible area.
  - The console content is updated in real-time, and you can issue key presses to interact with the console.
  - The cursor position is indicated by the block symbol '█'.
  - Avoid batching multiple commands. Issue one command at a time and wait for the console to update.
  - Expect when a command can invoke an interactive editor or a pager.
  - Ensure proper navigation in interactive programs like editors, pagers, etc.
  - Beware if a command invokes a pager, navigate the user through the pager to show all the relevant parts of the output, don't be satisfied with one run if there might be more important data below.
  - Asses whether the user is in a pager or an editor and act accordingly.
  - The block symbol '█' indicates the current cursor position.

  Instructions for issuing keypresses:
  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", "\"", etc.
  - Special named keys, read carefully, use literally: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Use C- notation for Ctrl keys. For example, "C-c" for Ctrl+c, "C-r" for Ctrl+r, etc.
  - Alt keys: Use M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - You are forbidden to use "C-d". If you need to exit a shell, use "C-c" to interrupt the current process and then "exit" to exit the shell.
  - If you intend there to be a space between command and/or arguments, spell it out as "Space".
  - If you need to issue a command, provide the key presses to type the command and then "Enter" to execute it.
  - No command chaining in one iteration, only one command per iteration.
  - Example sequences:
    - ["l", "s", "Enter"]
    - ["C-c"]
    - ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]

  User's Mission:

  The user's end goal is to:
  --
  #{mission}
  --

  CURRENT CONSOLE STATE FOR YOUR ANALYSIS:
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
  #{console_content}


  Please select the best suitable response from these, reply with the number of the response.

  SELECT_PROMPT

  responses.each_with_index do |response, index|
    prompt += "Response ##{index + 1}\n"
    prompt += "Response #{index + 1} keypresses: #{response['keypresses']}\n"
    prompt += "Response #{index + 1} reasoning: #{response['reasoning']}\n"
    prompt += "Response #{index + 1} evaluation from an external critic: #{response['critic_evaluation']}\n" if options[:critic]
    prompt += "\n"
  end

  prompt += <<~SELECT_PROMPT

  Please provide the number of the best response given the context of the mission and the current state of the console.

  SELECT_PROMPT
  if previous_next_move != ""
    prompt += <<~SELECT_PROMPT
    To help you make a better decision, here's what pllm was planning in this step:

    "#{previous_next_move}".
    SELECT_PROMPT
  end
  prompt += <<~SELECT_PROMPT

  So, given all this information, choose the best response number and provide it as a single number.

  The best response number is:

  SELECT_PROMPT

  prompt
end

def build_apply_critic_prompt(options, critiqued_responses, selected_number, mission, console_state)
  cursor_position = console_state[:cursor]
  console_content = console_state[:content]
  prompt = <<~APPLY_CRITIC_PROMPT
  You are tasked with applying the critic evaluation to the selected response from the LLM agent called 'pllm'. The agent's goal is to help the user accomplish a mission by providing keypress suggestions into user's console.

  The agent has provided multiple responses to a single prompt. Your task is to compile the best response based on:
  - the context of the mission and the user's progress
  - the critic evaluation of the responses
  - selected best response number

  This is the last time you can review the responses and apply critic evaluation to the selected response.

  Please consider the critic evaluation(s) and integrate them into the selected response.

  Instructions for operating the console session:
  - The console output is always prepended with line numbers by the system for your convenience. These are not part of the actual console content.
  - The console window size is #{WINDOW_X} columns by #{WINDOW_Y} rows.
  - There are no scrollbars, so the console content is limited to the visible area.
  - The console content is updated in real-time, and you can issue key presses to interact with the console.
  - The cursor position is indicated by the block symbol '█'.
  - Avoid batching multiple commands. Issue one command at a time and wait for the console to update.
  - Expect when a command can invoke an interactive editor or a pager.
  - Ensure proper navigation in interactive programs like editors, pagers, etc.
  - Beware if a command invokes a pager, navigate the user through the pager to show all the relevant parts of the output, don't be satisfied with one run if there might be more important data below.
  - Asses whether the user is in a pager or an editor and act accordingly.
  - The block symbol '█' indicates the current cursor position.

  Instructions for issuing keypresses:
  - Normal characters: "a", "b", "c", "A", "B", "C", "1", "2", ".", " ", "\"", etc.
  - Special named keys, read carefully, use literally: "Enter", "Tab", "BSpace", "Escape", "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown", "Insert", "Delete"
  - Ctrl keys: Use C- notation for Ctrl keys. For example, "C-c" for Ctrl+c, "C-r" for Ctrl+r, etc.
  - Alt keys: Use M- notation for Alt keys. For example, "M-a" for Alt+a, "M-x" for Alt+x, etc.
  - Send uppercase letters directly as uppercase. No need for Shift notation.
  - If you need multiple steps, output them in a single "keypresses" array, one key per element.
  - You are forbidden to use "C-d". If you need to exit a shell, use "C-c" to interrupt the current process and then "exit" to exit the shell.
  - If you intend there to be a space between command and/or arguments, spell it out as "Space".
  - If you need to issue a command, provide the key presses to type the command and then "Enter" to execute it.
  - No command chaining in one iteration, only one command per iteration.
  - Example sequences:
    - ["l", "s", "Enter"]
    - ["C-c"]
    - ["e", "c", "h", "o", " ", "'", "H", "e", "l", "l", "o", "'", "Enter"]

  User's Mission:

  The user's end goal is to:
  --
  #{mission}
  --

  CURRENT CONSOLE STATE FOR YOUR ANALYSIS:
     | Console window wize: (#{WINDOW_X}, #{WINDOW_Y})
     | Current cursor position: (#{cursor_position[:x]}, #{cursor_position[:y]})
  #{console_content}

  Here are the responses and their critic evaluations:

  APPLY_CRITIC_PROMPT
  
  critiqued_responses.each_with_index do |response, index|
    prompt += "Response ##{index + 1}:\n"
    response.delete(:critic_evaluation)
    prompt += response.to_s
    prompt += "\n\n"
  end

  prompt += <<~APPLY_CRITIC_PROMPT

  End of responses.

  Selected response number: #{selected_number}

  Follow this JSON format in your response:
  - Each element in "keypresses" array is a single keypress.
  - Format response in valid JSON only, example below.
  - You should reproduce parts you're not changing verbatim. You should carefully integrate the rest.
  - Fields "reasoning", "mission_complete", "branch_map", "next_move" are mandatory.
  - You might modify "critic_evaluation" to reflect your changes.
  - Finally, there is one trick. You may reply with NO_CHANGE and stop if desired.
  Your best response given this information is:
  ```json
  APPLY_CRITIC_PROMPT

  prompt
end

def valid_llm_response?(response)
  response.is_a?(Hash) &&
    response.key?('reasoning') &&
    response.key?('keypresses') &&
    response.key?('mission_complete') &&
    response.key?('branch_map') &&
    response.key?('next_move') &&
    response['keypresses'].is_a?(Array)
end

# --- Main Execution ---
logger = Logger.new(LOG_FILE, 'daily')
logger.level = Logger::DEBUG

options = {
  edit: false,
  timeout: EDIT_TIMEOUT,
  history_limit: HISTORY_LIMIT,
  history_console_state: false,
  mission: DEFAULT_MISSION,
  reeval_times: REEVAL_TIMES,
  select_times: SELECT_TIMES,
  critic: false,
  apply_critic: false,
  apply_critic_see_choices: false,
  help: false
}

help_text = ""
OptionParser.new do |opts|
  opts.banner = "Usage: pllm.rb [options]"
  opts.on("-e", "--edit[=SECONDS]", Integer, "Allow editing of LLM response before use, with optional timeout in seconds (default 5)") do |e|
    options[:edit] = true
    options[:timeout] = e || EDIT_TIMEOUT
  end
  opts.on("-l", "--limit-history=LIMIT", Integer, "Limit the number of entries in the mission history (default 10)") do |l|
    options[:history_limit] = l
  end
  opts.on("-c", "--console-history", "Include console state in history") do |c|
    options[:history_console_state] = true
  end
  opts.on("-m", "--mission=MISSION_FILE", "Load mission from a file") do |m|
    mission = File.read(m)
    options[:mission] = mission
  end
  opts.on("-e", "--eval-times=TIMES", Integer, "Number of times to reevaluate a response (default 3)") do |e|
    options[:reeval_times] = e
  end
  opts.on("-s", "--select-times=TIMES", Integer, "Number of times to retry selecting a response, redo the whole round if fails (default 1)") do |s|
    options[:select_times] = s
  end
  opts.on("-r", "--review-critic", "Enable critic evaluation of responses") do |r|
    options[:critic] = true
  end
  opts.on("-a", "--apply-critic", "Apply critic evaluation to response after selection") do |a|
    options[:critic] = true
    options[:apply_critic] = true
  end
  opts.on("-A", "--apply-critic-see-choices", "Apply critic evaluation to response after selection, but see the choices first") do |a|
    options[:critic] = true
    options[:apply_critic] = true
    options[:apply_critic_see_choices] = true
  end
  opts.on("-h", "--help", "Prints this help") do
    options[:help] = true
  end
  help_text = opts.to_s
end.parse!

if options[:help]
  puts help_text
  exit
end

uuid = SecureRandom.uuid
session_name = "pllm-#{uuid[0,8]}"
summaries = []
history = ""
history_length = 0
iteration = 0
mission_complete = false
parsed_responses = []
critiqued_responses = []
keypresses_history = []
previous_next_move = ""

logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{session_name}] #{datetime} - #{severity}: #{msg}\n"
end

llm = LLM.new(logger,
              LLAMA_API_ENDPOINT, options, ENV['EDITOR'],
              { n_predict: 384, temperature: 0.6 })
tmux = Tmux.new(session_name, WINDOW_X, WINDOW_Y)

begin
  logger.info("")
  logger.info("Starting PLM session: #{session_name}")

  until mission_complete
    parsed_responses = []
    critiqued_responses = []
    selected_response = nil
    iteration += 1
    console_state = tmux.capture_output
    prompt = build_main_prompt(options[:mission], history, console_state, options, iteration)
    system("clear")
    logger.info("Running iteration #{iteration}")
    puts console_state[:content]

    options[:reeval_times].times do |i|
      parsed_response = nil
      evaluated_response = nil
      puts "\nIteration #{iteration}: querying LLM to get the next suggestions... (#{i+1}/#{options[:reeval_times]})"
      llm.query(prompt, {}) do |json_response|
        begin
          parsed_response = JSON.parse(json_response)
          if valid_llm_response?(parsed_response)
            logger.info("\n#{prompt}\n{#{json_response}}")
            parsed_responses[i] = parsed_response
          else
            parsed_response = nil
          end
        rescue JSON::ParserError => e
          parsed_response = nil
          err = "Failed to parse LLM response: #{e.message}. Please check the response for errors." 
          puts err
          logger.error(err)
        end 
      end
      next if parsed_response.nil? 
      if options[:critic] == false
        critiqued_responses[i] = parsed_response
        next
      end
      eval_prompt = build_critic_prompt(parsed_response, options[:mission], console_state)
      puts
      #puts eval_prompt
      evaluated_response = llm.query(eval_prompt, { n_predict: 256, temperature: 0.8 }, "END_EVALUATION")
      puts
      evaluated_response = evaluated_response.strip
      critiqued_responses[i] = parsed_response.merge({ critic_evaluation: evaluated_response })
    end
    select_rounds = 0
    selection = nil
    unless options[:reeval_times] == 1
      select_prompt = build_select_prompt(options, critiqued_responses, options[:mision], keypresses_history, console_state, previous_next_move)
      #puts select_prompt
      while selected_response.nil?
        select_rounds += 1
        print "\nSelect the best response: "
        selection = llm.query(select_prompt, { n_predict: 10, temperature: 0.3 }, "END_SELECT")
        puts
        selection = selection.match(/\d+/).to_s
        if selection.to_i > 0 && selection.to_i <= critiqued_responses.length
          selected_response = critiqued_responses[selection.to_i - 1]
        end
        if select_rounds > options[:select_times]
          break
        end
      end
    else
      selected_response = parsed_responses[0]
    end
    if select_rounds > options[:select_times]
      next
    end
    if options[:apply_critic]
      puts "\nApplying critic evaluation to the selected response...\n"
      if options[:apply_critic_see_choices]
        selection = 1
        param_responses = critiqued_responses
      else
        param_responses = [ selected_response ]
      end
      apply_critic_response = nil
      apply_critic_prompt = build_apply_critic_prompt(options, param_responses, selection, options[:mission], console_state)
      llm.query(apply_critic_prompt, { temperature: 0.3 }) do |fixedup_json_response|
        begin
          if fixedup_json_response.contains("NO_CHANGE")
            apply_critic_response = param_responses[selection-1]
          else
            apply_critic_response = JSON.parse(fixedup_json_response)
            if valid_llm_response?(apply_critic_response)
              logger.info("\n#{apply_critic_prompt}\n{#{fixedup_json_response}}")
              selected_response = apply_critic_response
            end
          end
        rescue JSON::ParserError => e
          err = "Failed to parse LLM response: #{e.message}. Please check the response for errors." 
          puts err
          logger.error(err)
        end
      end
    end

    keypresses = selected_response['keypresses'] || []
    if keypresses.nil?
      keypresses = []
    elsif keypresses.is_a?(String)
      keypresses = [ keypresses ]
    end

    unless keypresses.empty?
      tmux.send_keys(keypresses)
      keypresses_history << keypresses
    end

    sleep 2 # Give time for the shell to process the key presses

    mission_complete = selected_response['mission_complete']
    next_move = selected_response['next_move']
    previous_next_move = next_move
    timestamp = Time.now.utc.iso8601
    cursor_position = console_state[:cursor]
    history += "\n"
    history += "[#{timestamp}]\n"
    if options[:history_console_state]
      history += "Cursor Position: (#{cursor_position[:x]}, #{cursor_position[:y]})\n"
      history += "Console State:\n"
      history += "#{console_state[:content]}\n"
    end
    history += selected_response.to_s
    history += "\n"
    history += "Evaluation of this step by an external critic: #{selected_response['critic_evaluation']}\n" if options[:critic]
    history_length += 1

    new_state = tmux.capture_output
    logger.info("Post-Keypress Console State:\n#{new_state[:content]}")

    # Update history length and condense if needed
    if history_length >= options[:history_limit]
      logger.info("Summarizing history due to history limit")
      summarization_prompt = build_summarization_prompt(history, options[:mission], new_state)
      #puts summarization_prompt
      puts
      summary = llm.query(summarization_prompt, { n_predict: 390, temperature: 0.7 }, "END_SUMMARY")
      summaries << summary
      puts
      summaries.each do |s|
        history += "\nAn older summary:\n#{s}\n\n"
      end
      history_length = 0

      logger.info("Summarized history:\n#{history}")
    end

    break if mission_complete
  end
rescue Interrupt
  puts "\nInterrupted. Cleaning up..."
ensure
  tmux.cleanup
end
