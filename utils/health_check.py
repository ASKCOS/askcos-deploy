"""
Health check script for ASKCOS celery workers.

This script checks the status of each celery worker by submitting a simple task
using the web API. If the task fails, the script can automatically restart
the docker container which hosts the worker. If the task succeeds or times out,
no further action is taken, since timeouts could be caused by the presence of
other tasks in the queue.

Usage:

    # Basic case, execute from root askcos-deploy directory
    python util/health_check.py

    # Specify host url for askcos deployment (default is https://localhost)
    python util/health_check.py --host https://mysite.com

    # Execute from another directory (must provide path to askcos-deploy)
    python /path/to/health_check.py --project-directory /path/to/askcos-deploy

    # Only perform health check and do not restart containers
    python util/health_check.py --no-restart

    # Specify particular service to check and restart
    python util/health_check.py tb_coordinator_mcts

    # Specify scale for particular service when restarting
    python util/health_check.py --scale tb_coordinator_mcts=2
"""

import argparse
import os
import requests
import subprocess
import time
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)


celery_workers = [
    {
        'name': 'cr_network_worker',
        'endpoint': '/context/',
        'test': {'reactants': 'c1ccccc1', 'products': 'Brc1ccccc1'},
    },
    {
        'name': 'tb_coordinator_mcts',
        'endpoint': '/tree-builder/',
        'test': {'smiles': 'Brc1ccccc1'},
    },
    {
        'name': 'tb_c_worker',
        'endpoint': '/retro/',
        'test': {'target': 'Brc1ccccc1'},
    },
    {
        'name': 'tb_c_worker',
        'endpoint': '/fast-filter/',
        'test': {'reactants': 'BrBr.c1ccccc1', 'products': 'Brc1ccccc1'},
    },
    {
        'name': 'sites_worker',
        'endpoint': '/selectivity/',
        'test': {'smiles': 'Cc1ccccc1'},
    },
    {
        'name': 'impurity_worker',
        'endpoint': '/impurity/',
        'test': {'reactants': 'BrBr.c1ccccc1', 'products': 'Brc1ccccc1'},
    },
    {
        'name': 'atom_mapping_worker',
        'endpoint': '/atom-mapper/',
        'test': {'rxnsmiles': 'BrBr.c1ccccc1>>Brc1ccccc1'},
    },
    {
        'name': 'tffp_worker',
        'endpoint': '/forward/',
        'test': {'reactants': 'BrBr.c1ccccc1'},
    },
]


class APIClient:

    def __init__(self, host):
        self.client = requests.Session()
        self.client.verify = False

        if host.startswith('http'):
            self.url = '{0}/api/v2'.format(host)
        else:
            self.url = 'https://{0}/api/v2'.format(host)

    def get(self, endpoint, **kwargs):
        """Process a GET request"""
        return self.client.get(self.url + endpoint, **kwargs)

    def post(self, endpoint, **kwargs):
        """Process a POST request"""
        return self.client.post(self.url + endpoint, **kwargs)

    def get_result(self, task_id):
        """Retrieve celery task output"""
        # Try to get result 5 times in 2 sec intervals
        for _ in range(5):
            response = self.get('/celery/task/{0}/'.format(task_id))
            result = response.json()
            if result.get('complete'):
                return 0
            else:
                if result.get('failed'):
                    return 1
                else:
                    time.sleep(2)
        return 2  # timeout


def health_check(client, endpoint, test):
    """Attempt to submit task to endpoint."""
    result = client.post(endpoint, data=test)
    assert result.status_code == 200, result.json()

    status = client.get_result(result.json()['task_id'])
    return status


def main():
    """Check health of all celery workers and restart if necessary."""
    parser = argparse.ArgumentParser()
    parser.add_argument('workers', nargs='*', help='names of specific workers to check and restart')

    parser.add_argument('--host', nargs=1, help='hostname for deployment, e.g. askcos.mit.edu')
    parser.add_argument('-n', '--no-restart', action='store_false', help='do not restart containers, only check health')
    parser.add_argument('-v', '--version', nargs=1, help='docker image version to use when restarting')
    parser.add_argument('-d', '--project-directory', nargs=1, help='askcos-deploy directory (Compose file location)')
    parser.add_argument('-s', '--scale', metavar='NAME=SCALE', action='append', type=lambda x: x.split('=', 1),
                        dest='scales', default=[], help='worker scales, as name=scale pairs like docker-compose')

    args = parser.parse_args()
    workers = args.workers
    host = args.host[0] if args.host is not None else 'localhost'
    restart = args.no_restart
    version = args.version
    wd = args.project_directory[0] if args.project_directory else None
    scales = dict(args.scales)

    env = os.environ.copy()
    if version is not None:
        env['VERSION_NUMBER'] = version[0]

    client = APIClient(host=host)

    results = {}
    for worker in celery_workers:
        if workers and worker['name'] not in workers:
            continue
        status = health_check(client, worker['endpoint'], worker['test'])
        # Some workers have multiple tests (e.g. tb_c_worker)
        # Store as failed if any of the tests failed
        results[worker['name']] = max(results.get(worker['name'], 0), status)

    states = {
        0: '\033[92m{}\033[00m'.format('is ok'),
        1: '\033[91m{}\033[00m'.format('is not ok'),
        2: '\033[93m{}\033[00m'.format('timed out'),
    }
    for worker, status in results.items():
        print('Worker {0} {1}.'.format(worker, states[status]))

    if results.get('tb_coordinator_mcts') == 2:
        print('\nTree builder coordinator timed out. Checking queue...')
        result = subprocess.run(
            ['docker-compose', 'exec', 'rabbit', 'rabbitmqctl', 'list_queues', '--online', 'name', 'messages_ready'],
            env=env, cwd=wd, capture_output=True,
        )
        output = result.stdout.decode('utf-8')
        for line in output.splitlines():
            parts = line.split()
            if parts[0] == 'tb_coordinator_mcts':
                print('There are {0} tasks waiting in the tree builder queue.\n'.format(parts[1]))
                response = input('Do you want to clear the queue and restart the worker? (y/N) ')
                if response.lower() in ['y', 'yes']:
                    result = subprocess.run(
                        ['docker-compose', 'exec', 'app', 'celery', '-A', 'askcos_site', '-Q', 'tb_coordinator_mcts', 'purge', '-f'],
                        env=env, cwd=wd,
                    )
                    if result.returncode == 0:
                        results['tb_coordinator_mcts'] = 1
                    else:
                        print('Unable to clear queue. Not restarting worker.')
                break

    if restart:
        restart_list = [worker for worker, status in results.items() if status == 1]
        if restart_list:
            print('\nRestarting workers...')
            command = ['docker-compose', 'up', '--detach', '--force-recreate']

            for worker in restart_list:
                scale = scales.get(worker)
                if scale is not None:
                    command.extend(['--scale', '{0}={1}'.format(worker, scale)])

            command.extend(restart_list)

            result = subprocess.run(command, env=env, cwd=wd)
            if result.returncode == 0:
                print('Done.')
            else:
                print('Unable to restart workers.')


if __name__ == '__main__':
    main()
