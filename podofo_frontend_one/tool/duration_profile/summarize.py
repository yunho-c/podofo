"""Summarize raw duration-profile reports without adding overlapping spans."""
import json
from collections import defaultdict
from pathlib import Path
from statistics import median
import sys


def main():
    for name in sys.argv[1:]:
        report = json.loads(Path(name).read_text())
        print(f'\n{name}: passed={report["passed"]}')
        groups = defaultdict(list)
        for run in report['runs']:
            groups[(run.get('mode', 'document'), run.get('group', 0))].append(run)
        for (mode, group), runs in groups.items():
            print(f'{mode:22s} group={group}: median {median(r["total_us"] for r in runs)/1000:.2f} ms '
                  f'({len(runs)} trials, {runs[0]["passages"]} passages)')
            if 'jobs' in runs[0]:
                parts = {key: median(sum(j[key] for j in r['jobs']) for r in runs)/1000
                         for key in ['admission_us', 'done_us', 'metadata_us', 'dispose_us']}
                print('  Sequential job phases (ms):', {k: round(v, 3) for k, v in parts.items()})
                # sdkTimeline is unique to duration jobs in this probe; speech observers
                # use only snapshot/wait/state-poll. These timings are nested in metadata_us.
                for operation in ['sdkTimeline', 'sdkDispose']:
                    values = defaultdict(list)
                    for run in runs:
                        events = [e for e in run['worker_events'] if e['operation'] == operation]
                        for field, a, b in [('queue', 'enqueued_us', 'started_us'),
                                            ('native', 'started_us', 'finished_us'),
                                            ('delivery', 'finished_us', 'delivered_us')]:
                            values[field].append(sum(e[b]-e[a] for e in events)/1000)
                    print(f'  {operation} nested worker sums (ms):', {k: round(median(v),3) for k,v in values.items()})
                print('  Model segments:', sorted({r['segments'] for r in runs}))
            else:
                stages = defaultdict(list)
                for run in runs:
                    sums = defaultdict(int)
                    for event in run['trace']['events']:
                        sums[event['stage']] += event['elapsed_us']
                    for stage, value in sums.items(): stages[stage].append(value/1000)
                print('  Stage sums, nested spans overlap (ms):', {k: round(median(v),3) for k,v in stages.items()})
        if 'matched_segments' in report:
            print('Identical model-segment text hashes:', report['matched_segments'])


if __name__ == '__main__':
    main()
