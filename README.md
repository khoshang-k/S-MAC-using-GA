# S-MAC vs. GA-Optimized S-MAC

This project is a MATLAB/Octave prototype for a Network Design and Optimization course. It simulates a wireless sensor network using a simplified S-MAC-style energy model and compares fixed S-MAC parameters with parameters selected by a custom genetic algorithm (GA).

The goal is to explore whether optimizing duty cycle and cluster-head probability affects network lifetime, node survival, distances, residual energy, and packet delivery. This is an educational model, not a complete implementation of the S-MAC protocol or a detailed physical/network-layer simulator.

## Requirements

Choose either:

- MATLAB; or
- GNU Octave, a free MATLAB-compatible environment.

No MATLAB toolboxes are required. The GA uses in-script tournament selection, crossover, mutation, and elitism rather than MATLAB's Genetic Algorithm Toolbox.

## Run the simulation

The script is [smac_ga.m](./smac_ga.m). It is a MATLAB script, so run it from MATLAB or Octave with the working directory set to the repository folder.

### GNU Octave

From a terminal in the repository folder:

```bash
octave --no-gui --quiet --eval "smac_ga"
```

On Ubuntu or Debian, if Octave is not installed:

```bash
sudo apt update
sudo apt install octave
```

### MATLAB

Open the repository folder in MATLAB, then run:

```matlab
smac_ga
```

### VS Code

Open this repository in VS Code and run the Octave command in the integrated terminal (**Terminal → New Terminal**). A MATLAB or Octave language extension can provide editing support, but an installed MATLAB or Octave runtime is still needed to execute the script.

The script sets `rngSeed = 1` for repeatable results. Change that value in `smac_ga.m` to run another randomized scenario. Each run writes `simulation_results.mat` and `simulation_comparison.png` in the current working directory, replacing existing files with those names.

## Simulation setup

The current default configuration in `smac_ga.m` is:

| Setting | Value |
|---|---:|
| Sensor nodes | 100 |
| Deployment area | 100 m × 100 m |
| Base station location | (50 m, 150 m) |
| Initial energy per node | 0.5 J |
| Maximum rounds | 2,000 |
| Packet size | 4,000 bits |
| S-MAC duty cycle | Fixed at 0.10 |
| S-MAC cluster-head probability | 0.05 |
| GA_MAC candidate duty-cycle range | 0.05–0.25 |
| GA_MAC candidate cluster-head-probability range | 0.01–0.11 |
| GA population size | 12 |
| GA generations per round | 8 |

The script uses a first-order radio energy model, selecting the free-space or multipath transmission cost according to the distance threshold `d0`. Non-cluster-head nodes send to their nearest cluster head, or directly to the base station if no cluster head is selected. Cluster heads pay receive energy for member packets and forward their own and received packets to the base station. Each node that remains active after its S-MAC idle/sleep energy cost generates one packet per round.

## What the current script measures

For each protocol (`S_MAC` and `GA_MAC`), the `metrics` structure contains:

| Field | Meaning |
|---|---|
| `alive_nodes` | Number of living nodes recorded for each round |
| `energy_left` | Sum of the remaining energy of living nodes for each round |
| `prr` | Cumulative packets received at the base station divided by packets generated |
| `prr_per_round` | Per-round packets received at the base station divided by packets generated |
| `packets_generated`, `packets_sent`, `packets_received` | Per-round traffic counts |
| `intra_cluster_distance` | Mean member-to-nearest-cluster-head distance for that round (metres) |
| `inter_cluster_distance` | Mean cluster-head-to-base-station distance for that round (metres) |
| `direct_to_bs_distance` | Mean direct-node-to-base-station distance when no cluster head was elected (metres) |
| `mean_intra_cluster_distance`, `mean_inter_cluster_distance` | Mean of recorded per-round cluster distances |
| `FND` | Round when the first node dies |
| `HND` | Round when at least half the nodes have died |
| `LND` | Round when all nodes have died |
| `overall_network_lifetime_rounds` | LND round; `NaN` if the network remains alive at the simulation limit |
| `lifetime_censored` | True when all nodes did not die within `maxRounds` |

The time series start at round 0, before simulation energy is consumed. Milestone values are measured in completed rounds. When a milestone is not reached within `maxRounds`, its value is `NaN`.

## Output file

After a successful run, `simulation_results.mat` contains:

- `metrics`: results for both protocols
- `maxRounds`: the configured maximum number of rounds
- `rngSeed`: seed used for repeatable random numbers

Load and inspect the results in MATLAB or Octave:

```matlab
load('simulation_results.mat')
fieldnames(metrics)
metrics.S_MAC.FND
metrics.GA_MAC.LND
metrics.GA_MAC.mean_intra_cluster_distance
metrics.GA_MAC.overall_prr
```

The script also creates `simulation_comparison.png`, with plots for:

1. Alive nodes, including the 50%-alive threshold
2. Dead nodes, including the half-dead threshold
3. Cumulative packet reception ratio
4. Residual network energy
5. Mean intra- and inter-cluster distances
6. FND, HND, and LND milestones

## Important interpretation notes

- The GA is a custom, toolbox-free genetic algorithm. It optimizes a model-based estimate of per-node energy cost (a lifetime proxy), not a measured end-to-end lifetime. The GA is run each round using the current alive-node geometry and residual network state.
- The energy model is simplified. For example, it does not model synchronization, contention, retransmissions, collisions, or detailed S-MAC frame timing.
- PRR is the number of packets successfully forwarded to the base station divided by the number of packets generated by active nodes. A cluster-member packet is counted as received only if its cluster head can receive and forward it.
- Distance values are `NaN` on rounds without applicable clusters or members. Direct-to-base-station distances are reported separately.
- The fixed S-MAC and GA-optimized runs use the same initial node locations and the same configured random seed, but their later random choices differ.
- For stronger course conclusions, compare multiple seeds and report averages and variability in addition to the single-run plots.

## Course comparison goals

The broader comparison described for this project includes:

- Overall network lifetime
- Time/round until the first node dies (FND)
- Time/round until the last node dies (LND)
- Time/round until half the nodes die (HND)
- Inter- and intra-cluster distance
- Packet reception ratio
- Graphs of alive nodes, half-dead nodes, packet reception ratio, and remaining energy versus round

The script records the requested lifetime milestones, packet reception ratio, and cluster distances, and generates the corresponding comparison plots. Its simulation assumptions and fitness function should be described in any course report so results are interpreted as evidence from this simplified model rather than from a full S-MAC implementation.
