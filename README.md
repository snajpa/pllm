pllm
====

## Overview

This is a Ruby program that achieves user stated mission in terminal.

It does so using locally running llama.cpp at port 8081 (so start it there or change the source)

## Usage

```
Usage: pllm.rb [options]
    -a, --accumulate                 Accumulate responses for subsequent prompts
    -e, --edit[=SECONDS]             Allow editing of LLM response before use, with optional timeout in seconds (default 5)
    -l, --history-limit=LIMIT        Limit the number of entries in the scratchpad history (default 10)
    -m, --mission=MISSION_FILE       Load mission from a file
    -r, --reeval-times=TIMES         Number of times to reevaluate a response (default 3)
    -c, --critic                     Enable critic evaluation of responses
    -h, --help                       Prints this help
```
