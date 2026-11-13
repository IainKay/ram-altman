# Proposal: ram-altman-swarm — put the idle RAM to work

This is a proposal to extend [ram-altman](https://github.com/IainKay/ram-altman)
with a second script that does the opposite of reporting idle RAM: it puts
that idle RAM to work for public, open AI.

## Why

ram-altman answers Sam Altman's remark that it is "quite terrible to have
everybody have a bunch of the world's limited supply of DRAM sitting in
their own computer" and being "used maybe 5% of the time" — by emailing
him about the RAM you are *not* using.

The joke writes itself in reverse: instead of a daily email bragging about
the RAM sitting idle, grant that RAM a job. If the RAM is idle, let it
work for AI — in public, in the open, and with the door left open for
OpenAI too.

## What this adds

- **`ram-altman-swarm.sh`** — same 5-minute cron rhythm and 10%
  `MemAvailable` threshold as ram-altman. When more than 10% of RAM is
  free, it reserves a share of the free RAM for a training window by
  holding it in tmpfs (`/dev/shm`), at most once a day. The window
  scales with diffusion: **minutes = base (30) x devices**, capped at
  240 minutes. `RAM_SWARM_DEVICES` is the number of machines you
  estimate are running this code — you set it; the script does not phone
  home, count installations, or report anything anywhere. The more
  devices run it, the more RAM is held, for longer. The hold is released
  automatically when the window ends, and everything is logged locally.
- **`test-swarm.sh`** — tests against a fake meminfo and temp files:
  dry-run plan, real hold with the right size, once-a-day limit,
  no hold when RAM is busy, and the 240-minute diffusion cap.

## What it connects to

- **The public, opt-in peer-to-peer AI networks** — [OpenHydra](https://pypi.org/project/openhydra-network/) and [SharedLLM](https://sharedllm.org/hive) — which run open models on volunteered hardware with an OpenAI-compatible API. This script is the local piece: it reserves the RAM so a local model runner (Ollama, llama.cpp) or a swarm node can use it during the window.
- **The "Cooperative Computing" proposal made to OpenAI** on its own forum: opt-in hybrid inference where users' devices process part of their own AI requests, with rewards. If OpenAI wants in, that public proposal is the door: [Cooperative Computing: Opt-in Hybrid Inference with User Rewards](https://community.openai.com/t/cooperative-computing-opt-in-hybrid-inference-with-user-rewards/1413898).

## What it is not

Not a backdoor. Nothing here lets anyone — Sam Altman, OpenAI, or
anyone else — into your machine or run processes on it. There is no
network connection, no open port, no remote control. The RAM is held on
your own machine, by you, for a window you choose. Holding RAM reserves
it for a workload; the actual model work happens in the runner/node you
choose (Ollama, llama.cpp, OpenHydra, SharedLLM). If none is installed,
the hold still reserves the RAM and logs the contribution.

## Usage

```sh
chmod +x ram-altman-swarm.sh
RAM_SWARM_DRY_RUN=1 ./ram-altman-swarm.sh   # preview the plan
./ram-altman-swarm.sh                        # check and maybe start a window
./test-swarm.sh                              # tests
```

Cron, every 5 minutes like the original:

```
*/5 * * * * /path/to/ram-altman-swarm.sh
```

Config: `RAM_SWARM_THRESHOLD` (default 10), `RAM_SWARM_HOLD_FRACTION`
(percent of free RAM to hold, default 50), `RAM_SWARM_BASE_MINUTES`
(default 30), `RAM_SWARM_DEVICES` (default 1), `RAM_SWARM_MAX_MINUTES`
(default 240), `RAM_SWARM_HOLD_SECONDS` (window in seconds, for tests),
`RAM_SWARM_DRY_RUN` (1 = print the plan, do nothing).

## License

MIT License — see LICENSE. Not affiliated with, endorsed by,
or connected to Sam Altman or OpenAI.
