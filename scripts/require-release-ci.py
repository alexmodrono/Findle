#!/usr/bin/env python3
"""Require completed trusted CI runs for the exact commit being signed."""
import argparse
import json
import re
import subprocess


def check(runs, revision):
    runs = [run for run in runs if run['head_sha'] == revision and run['event'] in ('push', 'workflow_dispatch')]
    if not runs:
        raise ValueError('No trusted CI run for this exact revision; run CI before staging')
    latest = max(runs, key=lambda run: (run['run_number'], run.get('run_attempt', 1)))
    if latest['status'] != 'completed' or latest['conclusion'] != 'success':
        raise ValueError('Latest exact-revision CI is not successful: ' + latest['html_url'])
    return latest['html_url']


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('revision')
    parser.add_argument('--repo', default='alexmodrono/Findle')
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9a-f]{40}', args.revision) or args.repo != 'alexmodrono/Findle':
        raise SystemExit('Invalid release source')
    for workflow in ('ci.yml', 'codeql.yml'):
        result = subprocess.run(['gh', 'api', '--method', 'GET',
            f'repos/{args.repo}/actions/workflows/{workflow}/runs', '-f', 'head_sha=' + args.revision,
            '-f', 'per_page=100'], check=True, capture_output=True, text=True)
        print(workflow + ': ' + check(json.loads(result.stdout)['workflow_runs'], args.revision))


if __name__ == '__main__':
    try:
        main()
    except ValueError as error:
        raise SystemExit(str(error)) from error
