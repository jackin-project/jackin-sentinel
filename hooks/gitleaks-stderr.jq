# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
def envelope:
    try (capture("^(?:[1-9]|1[0-2]):[0-5][0-9](?:AM|PM) (?<level>INF|WRN|ERR) (?<message>.*)$") // null) catch null;
def size_pattern:
    "(?:0|[1-9][0-9]{0,2} bytes|[1-9][0-9]*(?:\\.[0-9]{2})? (?:KB|MB|GB))";
def duration_pattern:
    "(?:0s|[1-9][0-9]*ns|[1-9][0-9]*(?:\\.[0-9]{1,3})?µs|[1-9][0-9]*(?:\\.[0-9]{1,6})?ms|[1-9][0-9]*(?:\\.[0-9]{1,9})?s|[1-9][0-9]*m[0-9]+(?:\\.[0-9]{1,9})?s|[1-9][0-9]*h[0-9]+m[0-9]+(?:\\.[0-9]{1,9})?s)";
def progress_message:
    (try (capture("^scanned ~(?<raw>0|[1-9][0-9]*) bytes \\((?<size>" + size_pattern + ")\\) in " + duration_pattern + "$") // null) catch null) as $progress
    | if $progress == null then false
      elif $progress.raw == "0" then $progress.size == "0"
      elif ($progress.raw | test("^[1-9][0-9]{0,2}$")) then $progress.size == ($progress.raw + " bytes")
      else ($progress.size | test("^[1-9][0-9]*(?:\\.[0-9]{2})? (?:KB|MB|GB)$")) end;
reduce inputs as $line
    ({lines: 0, invalid: false, errors: 0, unknown: 0, partials: 0,
      progress: 0, commits: 0, complete: 0, clean: false, finding_count: 0};
     .lines += 1
     | ($line | envelope) as $entry
     | if $entry == null then .unknown += 1 | .invalid = true
       elif $entry.level == "ERR" then .errors += 1 | .invalid = true
       elif ($entry.message | test("partial scan|in partial scan$")) then
           .partials += 1 | .invalid = true
       elif $entry.level == "INF" and ($entry.message | test("^[0-9]+ commits scanned\\.$")) then
           .commits += 1
           | if .commits > 1 or .progress != 0 or .complete != 0 then .invalid = true else . end
       elif $entry.level == "INF" and ($entry.message | progress_message) then
           .progress += 1
           | if .progress > 1 or .complete != 0 then .invalid = true else . end
       elif $entry.level == "INF" and $entry.message == "no leaks found" then
           .complete += 1 | .clean = true
           | if .complete != 1 or .progress != 1 then .invalid = true else . end
       elif $entry.level == "WRN" and ($entry.message | test("^leaks found: [1-9][0-9]{0,14}$")) then
           .complete += 1
           | .finding_count = ($entry.message | ltrimstr("leaks found: ") | tonumber)
           | if .complete != 1 or .progress != 1 then .invalid = true else . end
       else .unknown += 1 | .invalid = true end)
| {valid: ((.invalid | not) and .progress == 1 and .complete == 1
           and (($mode == "git" and .commits == 1) or ($mode == "dir" and .commits == 0))
           and ((.clean and .finding_count == 0) or ((.clean | not) and .finding_count > 0))),
   lines, errors, unknown, partials, progress, commits, complete, clean, finding_count}
