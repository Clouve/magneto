#!/usr/bin/env python3
"""Start one magneto app or bundle the way a cluster starts a new install, and judge it as the platform does.

tests/new-disk-start.test.sh calls this once per target. It runs the target's docker-compose.yml under its own Compose
project with an override that drops published ports and fixed container names (so it never collides with a local
stack) and gives each container the CPU and memory of its smallest plan (cpuBase and memoryBase in the target's
clv-docker-compose.yml). Every volume is made by lib/new-disk-volumes.sh, the shape a cluster gives a new install: a top
folder of root's, lost+found, none of the image's files.

Each container is judged by its own probe from x-clouve-healthcheck, run as Kubernetes runs it: HTTP passes on a first
answer of 200 to 399 (a redirect is not followed), TCP on a connection, Command on exit status 0 of
`docker exec <container> /bin/sh -c "<path>"`. A container whose probe is off, or that has none, must be running. The
deadline is the probe's liveness budget, initialDelay + failureThreshold x interval seconds from the container's own
start, and never more than the 600 s the platform's launch job waits for every pod. An exit or a restart fails at once.
Once every container has passed, a settle period follows in which each probe must keep passing and nothing may exit
or restart.

With --upgrade-from TAG the target first installs with its images at TAG (those this machine has) and must pass; the
current images then start on the same volumes and must pass too, and no volume's top folder may change its owner or
mode. That is how a fix shows that it leaves existing installs alone.

Exit status: 0 when the target passes, 1 when it fails, 2 when it can't be run (no image, no configuration).
NEW_DISK_PROBE_EVERY (seconds, default 5) sets how often it probes; ND_SHAPER_IMAGE the small image it probes from.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

try:
    import yaml
except ImportError:
    print("This test needs python3 with PyYAML.", file=sys.stderr)
    sys.exit(2)

AGENT = "magneto-agent"
CAP = 600  # seconds the platform's launch job waits for every pod
SHAPER = os.environ.get("ND_SHAPER_IMAGE", "mirror.gcr.io/library/alpine:3.20")
PROBE_EVERY = float(os.environ.get("NEW_DISK_PROBE_EVERY", "5"))
PERMISSION = re.compile(r"Permission denied|Operation not permitted|cannot create|Read-only file system|EACCES|EPERM")


class SetupError(Exception):
    """The target can't be run at all (exit status 2)."""


def run(cmd, timeout=None, cwd=None, stdout_only=False):
    """Runs a command; returns (status, its stdout and stderr together, or its stdout alone when it is to be parsed:
    a warning on stderr would break the JSON). A timeout gives status 124."""
    try:
        done = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out after %s s" % timeout
    if stdout_only:
        return done.returncode, done.stdout or ""
    return done.returncode, (done.stdout or "") + (done.stderr or "")


def parse_time(text):
    """Docker's RFC 3339 time as seconds since the epoch, or None for Docker's zero time. Docker writes nanoseconds and
    either Z (container times) or an offset such as -07:00 (the time of a local build)."""
    match = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", (text or "").strip())
    if not match or match.group(1).startswith("0001-"):
        return None
    stamp = datetime.datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    seconds = stamp.timestamp() + (float("0" + match.group(2)) if match.group(2) else 0)
    zone = match.group(3)
    if zone and zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        seconds -= sign * (int(zone[1:3]) * 3600 + int(zone[4:6]) * 60)
    return seconds


def last_line(text, limit=160):
    lines = [l.strip() for l in (text or "").strip().splitlines() if l.strip()]
    return (lines[-1] if lines else "no output")[:limit]


def judge_http(output, target):
    """The kubelet's verdict on busybox `wget -S` output for a probe of TARGET (ip:port): it follows redirects to the
    same host, up to 10, and judges the last answer (200 to 399 passes); a redirect to another host passes at once.
    Returns (passed, what the probe saw)."""
    answers = []
    for line in output.splitlines():
        line = line.strip()
        status = re.match(r"HTTP/\S+\s+(\d{3})", line)
        if status:
            answers.append([int(status.group(1)), None])
        elif answers and line.lower().startswith("location:"):
            answers[-1][1] = line.split(":", 1)[1].strip()
    if not answers:
        return False, "no answer (%s)" % last_line(output)
    for hop, (code, location) in enumerate(answers):
        if 300 <= code < 400 and location:
            host = urllib.parse.urlsplit(location).netloc
            if host and host != target:
                return True, "HTTP %d to another host" % code
            if hop >= 10:
                return False, "more than 10 redirects"
            if hop == len(answers) - 1:
                return False, "HTTP %d to %s, and no answer from there (%s)" % (code, location, last_line(output))
            continue
        seen = "HTTP %d" % code if hop == 0 else "HTTP %d after %d redirect(s)" % (code, hop)
        return 200 <= code < 400, seen
    return False, "no answer"


def image_repo(ref):
    """The image reference without its tag: r.clv.zone/e2eorg/nextcloud:latest -> r.clv.zone/e2eorg/nextcloud."""
    ref = ref.split("@", 1)[0]
    head, _, last = ref.rpartition("/")
    return (head + "/" if head else "") + last.split(":", 1)[0]


class Target:
    def __init__(self, args):
        self.dir = os.path.abspath(args.dir)
        self.project = args.project
        self.label = args.label or os.path.basename(self.dir)
        self.repo = args.repo
        self.with_agent = args.with_agent
        self.settle = args.settle
        self.upgrade_from = args.upgrade_from
        self.keep = args.keep
        self.compose_file = os.path.join(self.dir, "docker-compose.yml")
        self.compose = ["docker", "compose"] if run(["docker", "compose", "version"])[0] == 0 else ["docker-compose"]
        self.tmp = tempfile.mkdtemp(prefix="new-disk-")
        self.override = os.path.join(self.tmp, "override.yml")
        manifest_file = os.path.join(self.dir, "clv-docker-compose.yml")
        manifest = {}
        if os.path.exists(manifest_file):
            with open(manifest_file) as fh:
                manifest = yaml.safe_load(fh) or {}
        self.manifest = manifest.get("services") or {}
        self.prober = "%s-ndprobe" % self.project
        self.prober_networks = []
        self.failures = []
        self.up_error = None

    # --- Compose -----------------------------------------------------------------------------------------------------

    def dc(self, *args, timeout=None, stdout_only=False):
        return run(self.compose + ["-p", self.project, "-f", self.compose_file, "-f", self.override] + list(args),
                   timeout=timeout, cwd=self.dir, stdout_only=stdout_only)

    def config(self):
        status, out = self.dc("config", "--format", "json", stdout_only=True)
        if status != 0:
            raise SetupError("Compose can't read %s: %s" % (self.compose_file, last_line(self.dc("config")[1], 400)))
        return json.loads(out)

    def write_override(self, services, images=None):
        """Ports and fixed names dropped, the smallest plan's CPU and memory, and (phase 1 of an upgrade) older images."""
        lines = ["services:"]
        for name in services:
            lines.append("  %s:" % json.dumps(name))
            lines.append("    ports: !reset []")
            lines.append("    container_name: !reset null")
            meta = (self.manifest.get(name) or {}).get("x-clouve-metadata") or {}
            if meta.get("cpuBase"):
                lines.append("    cpus: %s" % float(meta["cpuBase"]))
            if meta.get("memoryBase"):
                limit = int(float(meta["memoryBase"]) * 1024 ** 3)
                lines.append("    mem_limit: %d" % limit)
                lines.append("    memswap_limit: %d" % limit)  # GKE has no swap: nothing beyond the memory limit
            if images and name in images:
                lines.append("    image: %s" % json.dumps(images[name]))
        if len(lines) == 1:
            lines = ["services: {}"]  # Compose wants a mapping, even an empty one
        with open(self.override, "w") as fh:
            fh.write("\n".join(lines) + "\n")

    # --- what the target is made of ------------------------------------------------------------------------------

    def probe_spec(self, service):
        hc = (self.manifest.get(service) or {}).get("x-clouve-healthcheck")
        if not isinstance(hc, dict) or hc.get("enabled") is not True:
            return None
        spec = {k: hc.get(k) for k in ("type", "path", "port", "initialDelay", "interval", "timeout",
                                        "failureThreshold")}
        spec["type"] = str(spec["type"] or "").upper()
        for key, default in (("initialDelay", 0), ("interval", 10), ("timeout", 1), ("failureThreshold", 3)):
            spec[key] = int(spec[key] if spec[key] is not None else default)
        return spec

    def deadline(self, spec):
        if spec is None:
            return CAP
        return min(spec["initialDelay"] + spec["failureThreshold"] * spec["interval"], CAP)

    def describe(self, spec):
        if spec is None:
            return "no probe: running"
        if spec["type"] == "HTTP":
            return "HTTP :%s%s" % (spec["port"], spec["path"] or "/")
        if spec["type"] == "TCP":
            return "TCP :%s" % spec["port"]
        return "command: %s" % spec["path"]

    def volumes(self, config):
        """{volume name: the first service that mounts it} for the project's own named volumes."""
        declared = config.get("volumes") or {}
        found = {}
        for service, body in (config.get("services") or {}).items():
            for mount in body.get("volumes") or []:
                key = mount.get("source")
                if mount.get("type") != "volume" or not key or (declared.get(key) or {}).get("external"):
                    continue
                name = (declared.get(key) or {}).get("name") or "%s_%s" % (config.get("name"), key)
                found.setdefault(name, service)
        return found

    def check_images(self, config, services):
        for service in services:
            ref = config["services"][service].get("image")
            if not ref:
                raise SetupError("%s has no image" % service)
            status, out = run(["docker", "image", "inspect", "-f", "{{.Created}}", ref])
            if status != 0:
                raise SetupError("the image %s isn't on this machine (build it first)" % ref)
            created = parse_time(out.strip())
            age = (time.time() - created) / 3600 if created else 0
            when = "%.0f h" % age if age < 48 else "%.0f days" % (age / 24)
            print("  image %s: built %s (%s ago)" % (ref, out.strip()[:19].replace("T", " "), when))

    def older_images(self, config, services):
        images = {}
        for service in services:
            candidate = "%s:%s" % (image_repo(config["services"][service]["image"]), self.upgrade_from)
            if run(["docker", "image", "inspect", candidate])[0] == 0:
                images[service] = candidate
        if not images:
            raise SetupError("no image of %s has the tag %s on this machine" % (self.label, self.upgrade_from))
        for service, ref in images.items():
            print("  phase 1 runs %s as %s" % (service, ref))
        return images

    # --- running and judging -------------------------------------------------------------------------------------

    def prepare_volumes(self):
        status, out = run(["bash", "-c", '. "$1/lib/new-disk-volumes.sh" && shift && prepare_new_disk_volumes "$@"', "_",
                           self.repo, "-p", self.project, "-f", self.compose_file, "-f", self.override], cwd=self.dir)
        for line in out.splitlines():
            if line.strip():
                print("  " + line.strip())
        if status != 0:
            raise SetupError("the volumes could not be made as new disks")

    def containers(self):
        status, out = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=%s" % self.project,
                           "--format", '{{.ID}} {{.Label "com.docker.compose.service"}}'], stdout_only=True)
        found = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 2:
                found[parts[1]] = parts[0]
        return found

    def inspect(self, cid):
        status, out = run(["docker", "inspect", cid], stdout_only=True)
        if status != 0:
            return None
        return json.loads(out)[0]

    def start_prober(self, cids):
        networks = []
        for cid in cids:
            info = self.inspect(cid) or {}
            for net in ((info.get("NetworkSettings") or {}).get("Networks") or {}):
                if net not in networks:
                    networks.append(net)
        if not networks:
            return
        self.prober_networks = networks
        run(["docker", "rm", "-f", self.prober])
        status, out = run(["docker", "run", "-d", "--rm", "--name", self.prober, "--network", networks[0], SHAPER,
                           "sleep", "3600"])
        if status != 0:
            raise SetupError("the prober can't start: %s" % last_line(out))
        for net in networks[1:]:
            run(["docker", "network", "connect", net, self.prober])

    def container_ip(self, cid):
        """The container's address on a network the prober shares with it: the kubelet probes the pod's IP."""
        nets = ((self.inspect(cid) or {}).get("NetworkSettings") or {}).get("Networks") or {}
        for net in self.prober_networks:
            address = (nets.get(net) or {}).get("IPAddress")
            if address:
                return address
        return None

    def probe(self, service, cid, spec):
        """(passed, what the probe saw)"""
        if spec is None:
            return True, "running"
        timeout = max(spec["timeout"], 1)
        if spec["type"] in ("HTTP", "TCP"):
            address = self.container_ip(cid)
            if not address:
                return False, "no address on the prober's network"
        if spec["type"] == "HTTP":
            target = "%s:%s" % (address, spec["port"])
            status, out = run(["docker", "exec", self.prober, "wget", "-S", "-O", "/dev/null", "-T", str(timeout),
                               "http://%s%s" % (target, spec["path"] or "/")], timeout=timeout + 10)
            return judge_http(out, target)
        if spec["type"] == "TCP":
            status, out = run(["docker", "exec", self.prober, "nc", "-z", "-w", str(timeout), address,
                               str(spec["port"])], timeout=timeout + 10)
            return status == 0, "TCP :%s %s" % (spec["port"], "open" if status == 0 else "closed")
        status, out = run(["docker", "exec", cid, "/bin/sh", "-c", str(spec["path"])], timeout=timeout)
        if status == 124:
            return False, "timed out after %d s" % timeout
        return status == 0, "exit %d (%s)" % (status, last_line(out)) if status else "exit 0"

    def state(self, cid):
        """('running'|'created'|'exited'|'restarted', detail, started_at)"""
        info = self.inspect(cid)
        if info is None:
            return "exited", "the container is gone", None
        st = info.get("State") or {}
        started = parse_time(st.get("StartedAt"))
        restarts = int(info.get("RestartCount") or 0)
        if restarts > 0 or st.get("Status") == "restarting":
            return "restarted", "restarted %d time(s) (last exit code %s)" % (max(restarts, 1), st.get("ExitCode")), started
        if st.get("Status") in ("exited", "dead"):
            ended = parse_time(st.get("FinishedAt"))
            took = int(round(ended - started)) if ended and started else 0
            return "exited", "exited with code %s after %d s" % (st.get("ExitCode"), took), started
        if st.get("Status") == "created":
            return "created", "not started", None
        return "running", "", started

    def fail(self, service, reason):
        self.failures.append((service, reason))
        print("  FAIL %s: %s" % (service, reason))

    def wait_until_healthy(self, services):
        """Probes every container until each has passed or failed. Returns the services that passed."""
        begun = time.time()
        pending = list(services)
        first_start = {}
        passed = []
        last = {}
        while pending:
            cids = self.containers()
            for service in list(pending):
                cid = cids.get(service)
                spec = self.probe_spec(service)
                limit = self.deadline(spec)
                if not cid:
                    if self.up_error:
                        self.fail(service, "never created (docker compose up: %s)" % self.up_error)
                        pending.remove(service)
                    elif time.time() - begun > CAP:
                        self.fail(service, "never started within %d s" % CAP)
                        pending.remove(service)
                    continue
                kind, detail, started = self.state(cid)
                if kind in ("exited", "restarted"):
                    self.fail(service, detail)
                    pending.remove(service)
                    continue
                if kind == "created":
                    if self.up_error:
                        self.fail(service, "never started (docker compose up: %s)" % self.up_error)
                        pending.remove(service)
                    elif time.time() - begun > CAP:
                        self.fail(service, "never started within %d s" % CAP)
                        pending.remove(service)
                    continue
                first_start.setdefault(service, started or time.time())
                ok, seen = self.probe(service, cid, spec)
                last[service] = seen
                elapsed = time.time() - first_start[service]
                if ok and elapsed > limit:
                    self.fail(service, "passed its probe only after %d s, past its %d s deadline (Kubernetes would "
                                       "have restarted it by then)" % (elapsed, limit))
                    pending.remove(service)
                elif ok:
                    print("  PASS %s: healthy after %d s (deadline %d s, %s)" % (service, elapsed, limit,
                                                                               self.describe(spec)))
                    passed.append(service)
                    pending.remove(service)
                elif elapsed > limit:
                    self.fail(service, "not healthy within %d s (last probe: %s)" % (limit, seen))
                    pending.remove(service)
            if pending:
                time.sleep(PROBE_EVERY)
        return passed

    def settle_period(self, services):
        """After every container passed: none may exit or restart, and a probe may fail only as long as the platform
        lets it, failureThreshold x interval seconds in a row (Kubernetes marks a pod not ready, or restarts it, after
        failureThreshold failed probes). A shorter failure gets a note. The last probe of each container must pass."""
        if not services or self.failures:
            return
        print("  settle: %d s in which nothing may exit or restart, or fail its probe for longer than the platform "
              "allows" % self.settle)
        end = time.time() + self.settle
        watching = list(services)
        failing = {}  # service -> (when its probe started failing, what the probe saw)
        while watching and time.time() < end:
            time.sleep(min(PROBE_EVERY, max(end - time.time(), 0)))
            cids = self.containers()
            for service in list(watching):
                cid = cids.get(service)
                kind, detail, _ = self.state(cid) if cid else ("exited", "the container is gone", None)
                if kind != "running":
                    self.fail(service, detail)
                    watching.remove(service)
                    continue
                spec = self.probe_spec(service)
                ok, seen = self.probe(service, cid, spec)
                if ok:
                    if service in failing:
                        began, what = failing.pop(service)
                        print("  note: %s failed its probe for %d s during the settle period, then passed again (%s)"
                              % (service, time.time() - began, what))
                    continue
                began = failing.get(service, (time.time(), seen))[0]
                failing[service] = (began, seen)
                allowed = spec["failureThreshold"] * spec["interval"] if spec else 0
                if time.time() - began > allowed:
                    self.fail(service, "kept failing its probe for %d s during the settle period, past the %d s the "
                                       "platform tolerates (%s)" % (time.time() - began, allowed, seen))
                    watching.remove(service)
                    failing.pop(service, None)
        # The period is over. A probe still failing gets the rest of what the platform tolerates, as it would there.
        for service in watching:
            if service not in failing:
                continue
            spec = self.probe_spec(service)
            allowed = spec["failureThreshold"] * spec["interval"] if spec else 0
            began, seen = failing[service]
            while True:
                if time.time() - began > allowed:
                    self.fail(service, "kept failing its probe for %d s at the end of the settle period, past the %d s "
                                       "the platform tolerates (%s)" % (time.time() - began, allowed, seen))
                    break
                time.sleep(PROBE_EVERY)
                cid = self.containers().get(service)
                kind, detail, _ = self.state(cid) if cid else ("exited", "the container is gone", None)
                if kind != "running":
                    self.fail(service, detail)
                    break
                ok, seen = self.probe(service, cid, spec)
                if ok:
                    print("  note: %s failed its probe for %d s at the end of the settle period, then passed again (%s)"
                          % (service, time.time() - began, seen))
                    break

    def report_logs(self):
        cids = self.containers()
        for service, _ in self.failures:
            cid = cids.get(service)
            if not cid:
                continue
            _, logs = run(["docker", "logs", cid], timeout=60)
            lines = logs.splitlines()
            for line in lines[-30:]:
                print("    log: " + line)
            for line in [l for l in lines if PERMISSION.search(l)][:20]:
                print("    permission: " + line)

    def top_folders(self, volumes):
        tops = {}
        for name in volumes:
            status, out = run(["docker", "run", "--rm", "--network", "none", "-v", "%s:/v:ro" % name, SHAPER,
                               "stat", "-c", "%u:%g %a", "/v"])
            tops[name] = out.strip() if status == 0 else "unreadable"
        return tops

    def phase(self, config, services, images=None):
        """One start: override, volumes, up, judge. Returns True when every container passed."""
        self.write_override(list((config.get("services") or {}).keys()), images)
        self.prepare_volumes()
        self.up_error = None
        status, out = self.dc("up", "-d", *services, timeout=CAP + 120)
        if status != 0:
            self.up_error = last_line(out, 400)
            print("  docker compose up failed: %s" % self.up_error)
        cids = self.containers()
        self.start_prober([cids[s] for s in services if s in cids])
        passed = self.wait_until_healthy(services)
        self.settle_period(passed)
        if self.failures:
            self.report_logs()
            return False
        return True

    def cleanup(self):
        run(["docker", "rm", "-f", self.prober])
        if self.keep:
            print("  kept the stack: docker compose -p %s -f %s down -v removes it" % (self.project, self.compose_file))
        else:
            self.dc("down", "-v", "--remove-orphans", timeout=300)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def main(self):
        print("== %s (project %s)" % (self.label, self.project))
        if not os.path.exists(self.compose_file):
            raise SetupError("%s has no docker-compose.yml" % self.dir)
        self.write_override([])
        config = self.config()
        services = list((config.get("services") or {}).keys())
        if AGENT in services and not self.with_agent:
            services.remove(AGENT)
            print("  skipped %s (--with-agent includes it)" % AGENT)
        if not services:
            raise SetupError("no services to start")
        self.check_images(config, services)
        if self.upgrade_from:
            images = self.older_images(config, services)
            if not self.phase(config, services, images):
                print("  phase 1 (the images at %s) failed, so the upgrade wasn't tried" % self.upgrade_from)
                return False
            volumes = self.volumes(config)
            before = self.top_folders(volumes)
            run(["docker", "rm", "-f", self.prober])
            self.dc("down", timeout=300)
            print("  phase 2: the current images on the same volumes")
            ok = self.phase(config, services)
            after = self.top_folders(volumes)
            for name, service in volumes.items():
                if before.get(name) != after.get(name):
                    self.fail(service, "top folder of %s changed from %s to %s" % (name, before.get(name),
                                                                                  after.get(name)))
            return ok and not self.failures
        return self.phase(config, services)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--dir", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--label")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--with-agent", action="store_true")
    parser.add_argument("--upgrade-from")
    parser.add_argument("--settle", type=int, default=90)
    parser.add_argument("--keep", action="store_true")
    target = Target(parser.parse_args())
    try:
        ok = target.main()
    except SetupError as err:
        print("  ✗ %s" % err)
        print("ERROR %s" % target.label)
        target.cleanup()
        return 2
    except KeyboardInterrupt:
        target.cleanup()
        return 130
    target.cleanup()
    print("%s %s" % ("PASS" if ok else "FAIL", target.label))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
