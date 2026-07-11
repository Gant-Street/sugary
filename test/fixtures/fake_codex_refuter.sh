#!/bin/sh

output=""

while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    shift
    output="$1"
  fi
  shift
done

if [ -z "$output" ]; then
  exit 2
fi

printf '%s' '{"verdict":"refute","confidence":0.91,"introduced_by_pr":false,"proof_type":"history","failure_reproduced":false,"evidence":[{"path":"src/example.ex","line":1,"command":"git show HEAD^:src/example.ex","observation":"The behavior already existed at the base commit."}],"strongest_counterargument":"The changed line makes the issue look new.","reason":"The same behavior exists at the base commit.","residual_uncertainty":"None."}' > "$output"
