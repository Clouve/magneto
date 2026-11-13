#!/bin/bash

# ============================================================================
# New-disk runner: an image's stand-in is not the app
# ============================================================================
# The LimeSurvey and SuiteCRM images answer their health check through a
# stand-in while they install or upgrade: GET / gets 200 and the header
# X-Clouve-Standin: <app>, so that Kubernetes doesn't restart the container in
# the middle. The new-disk runner (tests/lib/new_disk_start.py) probes as
# Kubernetes does, so the stand-in passed its probe at once ("healthy after
# 0 s") and the run could end before the app had installed, or had failed to.
#
# This test checks the runner's own code, with made-up probe answers and a
# made-up clock. No container starts.
#   - judge_http says when the answer that passed came from a stand-in, and
#     which app's; an answer without the header reads as before;
#   - a container whose stand-in answers is not healthy yet. It is healthy
#     when the app itself answers, and the time printed is the app's;
#   - while the stand-in answers, the probe's own deadline doesn't apply (the
#     stand-in is what keeps the probe passing). The app has the 600 s the
#     platform's launch job waits;
#   - a container that only ever answers through its stand-in fails;
#   - a probe that fails for a moment between the stand-in and Apache is not
#     a failure;
#   - without a stand-in the deadline is the probe's own, as before.
#
# Needs python3 with PyYAML. Usage: bash tests/new-disk-standin.test.sh
# Exit status: 0 when every check passes, 1 when one fails, 2 when it can't run.
# ============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "This test needs python3 with PyYAML." >&2
  exit 2
fi

python3 -B - "$SCRIPT_DIR/lib/new_disk_start.py" <<'PY'
import contextlib
import importlib.util
import io
import sys

spec = importlib.util.spec_from_file_location("new_disk_start", sys.argv[1])
nd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nd)

GREEN, RED, RESET = "\033[0;32m", "\033[0;31m", "\033[0m"
failed = 0


def check(label, condition, detail=""):
    global failed
    if condition:
        print("  %sPASS%s %s" % (GREEN, RESET, label))
    else:
        failed += 1
        print("  %sFAIL%s %s" % (RED, RESET, label))
        if detail:
            print("       " + str(detail)[:400])


STANDIN = "  HTTP/1.1 200 OK\n  Host: 172.20.0.5:80\n  X-Clouve-Standin: suitecrm\n  Content-Type: text/html\n"
APP = "  HTTP/1.1 200 OK\n  Server: Apache\n  Content-Type: text/html\n"

print("judge_http")
ok, seen = nd.judge_http(STANDIN, "172.20.0.5:80")
check("a stand-in's 200 passes the probe, as it does on a cluster", ok is True, seen)
check("and the answer names the stand-in and its app", nd.standin_of(seen) == "suitecrm", seen)
ok, seen = nd.judge_http(APP, "172.20.0.5:80")
check("the app's own 200 reads as before", (ok, seen) == (True, "HTTP 200") and nd.standin_of(seen) is None, seen)
ok, seen = nd.judge_http("  HTTP/1.1 302 Found\n  Location: /install\n  HTTP/1.1 200 OK\n  X-Clouve-Standin: limesurvey\n", "172.20.0.5:8080")
check("after a redirect it is the last answer's header that counts", ok and nd.standin_of(seen) == "limesurvey", seen)
ok, seen = nd.judge_http("  HTTP/1.1 503 Service Unavailable\n  X-Clouve-Standin: suitecrm\n", "172.20.0.5:80")
check("a stand-in's 503 fails the probe", ok is False, seen)


class Clock:
    """A made-up clock: every sleep moves it on, and nothing really waits."""

    def __init__(self):
        self.now = 1000.0

    def time(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class Fake(nd.Target):
    """One service, 'app', whose probe answers come from a script: (seconds since the start, passed, what was seen)."""

    def __init__(self, clock, script, budget=10):
        self.clock, self.script, self.budget = clock, script, budget
        self.failures, self.up_error, self.started = [], None, clock.now

    def containers(self):
        return {"app": "cid"}

    def probe_spec(self, service):
        return {"type": "HTTP", "path": "/", "port": 80, "initialDelay": 0, "interval": self.budget, "timeout": 1,
                "failureThreshold": 1}

    def state(self, cid):
        return "running", "", self.started

    def probe(self, service, cid, spec):
        elapsed = self.clock.now - self.started
        answer = (False, "no answer")
        for since, ok, seen in self.script:
            if elapsed >= since:
                answer = (ok, seen)
        return answer


def run(script, budget=10):
    clock = Clock()
    nd.time.time, nd.time.sleep = clock.time, clock.sleep
    nd.PROBE_EVERY = 5  # whatever NEW_DISK_PROBE_EVERY says in this shell
    target = Fake(clock, script, budget)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        passed = target.wait_until_healthy(["app"])
    return passed, target.failures, out.getvalue()


S = "HTTP 200 from the suitecrm stand-in"
print("wait_until_healthy")
passed, failures, out = run([(0, True, S), (40, True, "HTTP 200")])
check("a container whose stand-in answers is healthy once the app itself answers", passed == ["app"] and not failures, out)
check("the time printed is the app's, not the stand-in's", "healthy after 40 s" in out, out)
check("and the run says that a stand-in answered first", "stand-in" in out and "after 0 s" in out, out)

passed, failures, out = run([(0, True, S), (200, True, "HTTP 200")], budget=10)
check("the app may take longer than the probe's deadline while its stand-in answers", passed == ["app"] and not failures,
      failures or out)

passed, failures, out = run([(0, True, S)])
check("a container that only ever answers through its stand-in fails", not passed and len(failures) == 1, out)
check("after the %d s the platform's launch job waits, and it says why" % nd.CAP,
      bool(failures) and "stand-in" in failures[0][1] and str(nd.CAP) in failures[0][1], failures)

passed, failures, out = run([(0, True, S), (30, False, "no answer"), (35, True, "HTTP 200")])
check("a probe that fails for a moment between the stand-in and the app is not a failure", passed == ["app"] and not failures,
      failures or out)

passed, failures, out = run([(5, True, "HTTP 200")])
check("without a stand-in, a pass inside the probe's deadline is a pass", passed == ["app"] and "healthy after 5 s" in out, out)
passed, failures, out = run([(12, True, "HTTP 200")], budget=10)
check("and a first pass after the deadline is still a failure", not passed and bool(failures) and "past its 10 s deadline" in failures[0][1],
      failures or out)
passed, failures, out = run([], budget=10)
check("as is a probe that never passes", not passed and bool(failures) and "not healthy within 10 s" in failures[0][1], failures or out)

print()
if failed:
    print("%sNew-disk stand-in checks failed.%s" % (RED, RESET))
    sys.exit(1)
print("%sNew-disk stand-in checks passed.%s" % (GREEN, RESET))
PY
