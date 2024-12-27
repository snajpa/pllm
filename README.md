pllm
====

## Overview

This is a Ruby program that achieves user stated mission in terminal.

It does so using locally running llama.cpp at port 8081 (so start it there or change the source)

## Usage

```
Usage: pllm.rb [options]
        --edit[=SECONDS]             Allow editing of LLM response before use, with optional timeout in seconds (default 5)
    -l, --limit-history=LIMIT        Limit the number of entries in the mission history (default 10)
    -c, --console-history            Include console state in history
    -m, --mission=MISSION_FILE       Load mission from a file
    -e, --eval-times=TIMES           Number of times to reevaluate a response (default 3)
    -s, --select-times=TIMES         Number of times to retry selecting a response, redo the whole round if fails (default 1)
    -r, --review-critic              Enable critic evaluation of responses
    -a, --apply-critic               Apply critic evaluation to response after selection
    -A, --apply-critic-see-choices   Apply critic evaluation to response after selection, but see the choices first
    -h, --help                       Prints this help
```
