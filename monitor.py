"""
This script monitors docker stats and generates plots of memory and/or cpu usage.

Once executed, the script will continue monitoring stats until interrupted.
Once interrupted (ctrl+c), the stats will be saved as a .csv file and plots
will be generated if the `-p` flag was provided. Plots can also be generated
later from the .csv file by providing the `-P` flag.

Note that this script currently cannot handle situations where containers are
started or stopped while monitoring is ongoing.
"""

import argparse
import os

import docker
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd


data = []


def parse_arguments():
    """
    Parse command line arguments.
    """
    parser = argparse.ArgumentParser(description='Docker Stats Monitoring Script')

    parser.add_argument('container', metavar='CONTAINER', type=str, nargs='*', help='containers to monitor')

    parser.add_argument('-o', '--output-directory', type=str, nargs=1, default='stats',
                        metavar='DIR', help='use DIR as output directory')

    parser.add_argument('-p', '--plot', action='store_true', help='generate plots')

    parser.add_argument('-P', '--post-process', action='store_true', help='generate plots from existing data')

    parser.add_argument('-f', '--filename', type=str, nargs=1, default='stats.csv',
                        metavar='FILE', help='data file for post-processing')

    args = parser.parse_args()

    return args


def calculate_cpu_percent(d):
    """
    Given a dictionary of stats from docker, compute the cpu usage as a percent.

    Code sources:
    - https://github.com/docker/cli/blob/2bfac7fcdafeafbd2f450abb6d1bb3106e4f3ccb/cli/command/container/stats_helpers.go#L168
    - https://github.com/TomasTomecek/sen/blob/67794e176e70fa77d01e2acae381b92e501c0e17/sen/util.py#L176
    """
    cpu_count = len(d["cpu_stats"]["cpu_usage"]["percpu_usage"])
    cpu_percent = 0.0
    cpu_delta = float(d["cpu_stats"]["cpu_usage"]["total_usage"]) - float(d["precpu_stats"]["cpu_usage"]["total_usage"])
    system_delta = float(d["cpu_stats"]["system_cpu_usage"]) - float(d["precpu_stats"]["system_cpu_usage"])
    if system_delta > 0.0:
        cpu_percent = cpu_delta / system_delta * 100.0 * cpu_count
    return cpu_percent


def get_cpu(stats):
    """
    For a list of stats dictionaries, retrieve and calculate cpu usage.

    Returns a list of cpu usages in %.
    """
    cpu = []
    for item in stats:
        try:
            cpu_percent = calculate_cpu_percent(item)
        except KeyError:
            continue
        else:
            cpu.append(cpu_percent)

    return cpu


def get_mem(stats):
    """
    For a list of stats dictionaries, retrieve memory usage.

    Returns a list of memory usages in MiB.
    """
    mem = []
    for item in stats:
        try:
            mem_usage = item['memory_stats']['usage'] / 1024 / 1024
        except KeyError:
            continue
        else:
            mem.append(mem_usage)

    return mem


def get_time(stats):
    """
    For a list of stats dictionaries, retrieve the time from the FIRST entry.

    Returns a single matplotlib timestamp as a float.
    """
    t = mdates.datestr2num(stats[0]['read'])
    return t


def monitor(client, names):
    """
    Monitor container stats using Docker SDK. Will continue until interrupted.
    """

    global data

    containers = [client.containers.get(name) for name in names]
    print('{0:<30}{1:<40}{2:<20}{3:<20}'.format('Time', 'Name', 'CPU', 'Memory(MiB)'))
    print('{0:<30}{1:<40}{2:<20}{3:<20}'.format('----', '----', '---', '-----------'))
    for items in zip(*[c.stats(stream=True, decode=True) for c in containers]):
        cpu = get_cpu(items)
        mem = get_mem(items)
        t = get_time(items)

        if cpu:
            # cpu is the only one which might be empty, so this keeps rows in sync
            data.append([t] + cpu + mem)

            for i, name in enumerate(names):
                t_str = mdates.num2date(t).isoformat(' ', timespec='seconds')
                print('{0:<30}{1:<40}{2:<20.2f}{3:<20.2f}'.format(t_str, name, cpu[i], mem[i]))


def main():
    """
    Monitor Docker container stats and generate plots if requested.
    """

    args = parse_arguments()

    wd = os.path.join(os.getcwd(), args.output_directory)

    if args.post_process:
        data_df = pd.read_csv(os.path.join(wd, args.filename))
        plot(data_df, wd, containers=args.container)
        return

    if not os.path.isdir(wd):
        os.mkdir(wd)

    client = docker.from_env()

    if args.container:
        names = args.container
    else:
        names = [c.name for c in client.containers.list(filters={'status': 'running'})]

    try:
        monitor(client, names)
    except KeyboardInterrupt:
        print('')
        print('Stopping monitoring...')

    print('Saving data...')

    headers = ['Time'] + [name + '_cpu' for name in names] + [name + '_mem' for name in names]

    global data
    data_df = pd.DataFrame(data, columns=headers)

    data_df.to_csv(os.path.join(wd, 'stats.csv'), index=False)

    if args.plot:
        plot(data_df, wd)


def plot(data_df, wd, containers=None):
    """
    Generate all plots
    """
    print('Generating plots...')
    plot_mem(data_df, wd, containers=containers)
    plot_cpu(data_df, wd, containers=containers)


def plot_mem(data_df, wd, containers=None):
    """
    Generate plot of memory usage and save it to the specified directory.
    """
    fig, ax = plt.subplots()
    x = data_df['Time']
    if containers:
        columns = [c + '_mem' for c in containers]
    else:
        columns = [c for c in data_df.columns if c.endswith('mem')]
    y = data_df[columns]
    plt.plot(x, y)

    locator = mdates.AutoDateLocator()
    formatter = mdates.DateFormatter('%H:%M:%S')
    ax.xaxis.set_major_locator(locator)
    ax.xaxis.set_major_formatter(formatter)

    plt.legend([c[:-4] for c in columns], bbox_to_anchor=(1.02, 1), loc=2, borderaxespad=0.)
    plt.xlabel('Time')
    plt.ylabel('Memory (MiB)')
    plt.savefig(os.path.join(wd, 'mem.png'), bbox_inches="tight", dpi=150)


def plot_cpu(data_df, wd, containers=None):
    """
    Generate plot of cpu usage and save it to the specified directory.
    """
    fig, ax = plt.subplots()
    x = data_df['Time']
    if containers:
        columns = [c + '_cpu' for c in containers]
    else:
        columns = [c for c in data_df.columns if c.endswith('cpu')]
    y = data_df[columns]
    plt.plot(x, y)

    locator = mdates.AutoDateLocator()
    formatter = mdates.DateFormatter('%H:%M:%S')
    ax.xaxis.set_major_locator(locator)
    ax.xaxis.set_major_formatter(formatter)

    plt.legend([c[:-4] for c in columns], bbox_to_anchor=(1.05, 1), loc=2, borderaxespad=0.)
    plt.xlabel('Time')
    plt.ylabel('CPU (%)')
    plt.savefig(os.path.join(wd, 'cpu.png'), bbox_inches="tight", dpi=150)


if __name__ == '__main__':
    main()
