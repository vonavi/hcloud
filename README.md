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
    --with-seed INT          Seed value for PRNG
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

## Workflow

The model of communication follows that of [Raft Consensus Algorithm](https://raft.github.io/). At any given time each server is in one of three states: _leader_, _follower_, or _candidate_. In normal operation there is exactly one leader and all of the other servers are followers. Followers are passive: they issue no requests on their own but simply respond to requests from leaders and candidates. The leader handles all client requests. The third state, candidate, is used to elect a new leader.

The key safety property for Raft is the State Machine Safety Property: if a server has applied a log entry at a given index to its state machine, no other server will ever apply a different log entry for the same index.

Messages are produced by client using the Xorshift32 pseudo-random number generator (PRNG), which gives us a smooth process of message creation: it is enough to know the seed of the last message to generate a new one. Then, a deterministic random number from range `(0, 1]` is given by the division of seed value by the maximum 32-bit number. It should be noticed that such a random sequence, starting from a non-zero seed value, will never become zero.

After sending period expires, we ask all nodes to send their results in the form of the following tuple:

           |m|
    ( |m|,  Σ  i * m(i) )
           i=1

where `m(i)` is the `i`-th message received by a node. _To demonstrate the State Machine Safety Property, the node's result contains messages applied to state machine only (in the terminology of Raft)_. Then, in normal situation, a majority of servers gives the same result.

## Fault tolerance

Raft consensus algorithm is fully functional (_available_) as long as any majority of the servers are operational and can communicate with each other and with clients. Thus, a typical cluster of five servers can tolerate the failure of any two servers. Servers are assumed to fail by stopping; they may later recover from state on stable storage and rejoin the cluster.

## Testing

There is the `hcloud test` command which realizes a testing scenario with multiple server failures and recovers from state on stable storage. It uses the same options as `hcloud run` does.
