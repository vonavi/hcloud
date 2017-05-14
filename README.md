# Cloud-Haskell broadcast messaging

Program to broadcast messages based on a pseudo-random number sequence.

## Installation

Use Stack to install program:

    stack setup
    stack build

## Usage

To see help info, run program with flag `-h`:

    stack exec -- hcloud run -h

The following options are available for `hcloud run`:

    --send-for SEC           Sending period, in seconds
    --wait-for SEC           Grace period, in seconds
    --with-seed INT          Seed value for RNG
    --config FILE            Configuration file with nodes
    -h,--help                Show this help text

Example command:

    stack exec -- hcloud run --send-for 8 --wait-for 2 --with-seed 1 --config node.conf

Here, messages will be sent during 8 seconds. After that, during a grace period of 2 seconds, nodes will print out results. The node configuration is given by the `node.conf` file.

## Node configuration file

A configuration file contains a list of nodes in format `HOST:PORT`. For instance, a three-node configuration is given by

    127.0.0.1:12301
    127.0.0.1:12302
    127.0.0.1:12303

## Testing

For testing purposes, program can start each node from the node configuration independently, using command `hcloud test`. In comparison with `hcloud run`, an additional option is available&mdash;the current node in format `HOST:PORT`. An example of test scenario can be found in script `test-hcloud` (it uses `tmux` terminals).
