# SPDX-FileCopyrightText: 2026 Alexey Zhokhov
# SPDX-License-Identifier: Apache-2.0
def code:
    if type == "number" then . >= 0 and . <= 255 and floor == . else false end;
def expected_argv:
    if type != "array" then false
    elif length != 8 or (all(.[]; type == "string") | not) then false
    else .[0] == "git" and .[1] == "-C" and (.[2] | startswith("/"))
         and .[3:] == ["diff", "-U0", "--no-ext-diff", "--staged", "."] end;
def known_event:
    IN("version", "start", "exit", "atexit", "cmd_ancestry", "cmd_name", "cmd_mode",
       "def_repo", "region_enter", "region_leave", "data", "data_json", "error",
       "def_param", "child_start", "child_exit", "child_ready", "exec", "exec_result",
       "signal", "thread_start", "thread_exit", "alias");
reduce inputs as $line
    ({events: 0, invalid: false, first_sid: null, foreign_sid: false, phase: 0,
      versions: 0, starts: 0, matching_starts: 0, exits: 0, exit_code: null,
      atexits: 0, atexit_code: null};
     .events += 1
     | (try ($line | fromjson) catch null) as $event
     | if ($event | type) != "object" then .invalid = true
       elif ($event.sid | type) != "string" or ($event.event | type) != "string" then .invalid = true
       elif ($event.sid | length) == 0 then .invalid = true
       else
           if .first_sid == null then .first_sid = $event.sid
           elif .first_sid != $event.sid then .foreign_sid = true else . end
           | if ($event.event | known_event | not) then .invalid = true
             elif $event.event == "error" or $event.event == "signal" then .invalid = true
             elif $event.event == "version" then
                 .versions += 1
                 | if .phase != 0 or .versions > 1 then .invalid = true else . end
             elif $event.event == "start" then
                 .starts += 1
                 | if .phase != 0 then .invalid = true else . end
                 | .phase = 1
                 | if $event.argv == $expected then .matching_starts += 1 else .invalid = true end
             elif $event.event == "exit" then
                 .exits += 1
                 | if .phase != 1 or ($event.code | code | not) then .invalid = true
                   else .exit_code = $event.code end
                 | .phase = 2
             elif $event.event == "atexit" then
                 .atexits += 1
                 | if .phase != 2 or ($event.code | code | not) then .invalid = true
                   else .atexit_code = $event.code end
                 | .phase = 3
             elif $event.event == "data_json" and .phase == 2 then .
             elif .phase != 1 then .invalid = true
             else . end
       end)
| {valid: (($expected | expected_argv) and (.invalid | not) and (.foreign_sid | not)
           and .first_sid != null and .phase == 3 and .starts == 1 and .matching_starts == 1
           and .exits == 1 and .exit_code == 0 and .atexits == 1 and .atexit_code == 0),
   events, starts, matching_starts, exits, exit_code, atexits, atexit_code,
   sid_count: (if .first_sid == null then 0 elif .foreign_sid then 2 else 1 end)}
