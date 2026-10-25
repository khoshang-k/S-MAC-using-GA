function smac_ga()
% Compare fixed-parameter S-MAC with a GA-optimized S-MAC-style model.
clc; close all;

%% Network and simulation configuration
numNodes = 100;
areaX = 100;
areaY = 100;
bsX = 50;
bsY = 150;
initialEnergy = 0.5;
maxRounds = 2000;
packetSize = 4000;
rngSeed = 1;

% First-order radio energy model
E_elec = 50e-9;
E_fs = 10e-12;
E_mp = 0.0013e-12;
d0 = sqrt(E_fs / E_mp);
E_idle = 10e-9;
E_sleep = 0.01e-9;

% Fixed S-MAC parameters and GA search bounds
baseDutyCycle = 0.10;
baseClusterHeadProbability = 0.05;
dutyCycleBounds = [0.05, 0.25];
clusterHeadProbabilityBounds = [0.01, 0.11];
gaPopulationSize = 12;
gaGenerations = 8;

rng(rngSeed);
nodes = struct( ...
    'x', num2cell(rand(1, numNodes) * areaX), ...
    'y', num2cell(rand(1, numNodes) * areaY), ...
    'E', initialEnergy, ...
    'id', num2cell(1:numNodes));

protocols = {'S_MAC', 'GA_MAC'};
metrics = struct();
networkArea = areaX * areaY;

%% Simulate both configurations using the same node locations
for protocolIndex = 1:numel(protocols)
    protocol = protocols{protocolIndex};
    fprintf('Running simulation for %s...\n', protocol);
    [nodes.E] = deal(initialEnergy);

    aliveHistory = zeros(1, maxRounds + 1);
    energyHistory = zeros(1, maxRounds + 1);
    generatedHistory = zeros(1, maxRounds + 1);
    receivedHistory = zeros(1, maxRounds + 1);
    sentHistory = zeros(1, maxRounds + 1);
    roundPrHistory = zeros(1, maxRounds + 1);
    cumulativePrHistory = zeros(1, maxRounds + 1);
    intraDistanceHistory = NaN(1, maxRounds + 1);
    interDistanceHistory = NaN(1, maxRounds + 1);
    directDistanceHistory = NaN(1, maxRounds + 1);
    clusterHeadHistory = zeros(1, maxRounds + 1);

    aliveHistory(1) = numNodes;
    energyHistory(1) = numNodes * initialEnergy;
    roundsCompleted = 0;

    for roundNumber = 1:maxRounds
        aliveIndices = find([nodes.E] > 0);
        if isempty(aliveIndices)
            break;
        end

        if strcmp(protocol, 'GA_MAC')
            [dutyCycle, pCH] = runGeneticAlgorithm( ...
                nodes, aliveIndices, bsX, bsY, networkArea, packetSize, ...
                E_elec, E_fs, E_mp, E_idle, E_sleep, d0, ...
                dutyCycleBounds, clusterHeadProbabilityBounds, ...
                gaPopulationSize, gaGenerations);
        else
            dutyCycle = baseDutyCycle;
            pCH = baseClusterHeadProbability;
        end

        % Charge idle/sleep energy before packet generation.
        macEnergy = packetSize * ...
            (dutyCycle * E_idle + (1 - dutyCycle) * E_sleep);
        for i = 1:numel(aliveIndices)
            nodeIndex = aliveIndices(i);
            nodes(nodeIndex).E = max(0, nodes(nodeIndex).E - macEnergy);
        end
        aliveIndices = find([nodes.E] > 0);
        generatedPackets = numel(aliveIndices);
        receivedPackets = 0;
        sentPackets = 0;
        intraDistances = [];
        interDistances = [];
        directDistances = [];

        if ~isempty(aliveIndices)
            isClusterHead = rand(1, numel(aliveIndices)) < pCH;
            clusterHeadIndices = aliveIndices(isClusterHead);
            memberIndices = aliveIndices(~isClusterHead);
            clusterHeadHistory(roundNumber + 1) = numel(clusterHeadIndices);

            if isempty(clusterHeadIndices)
                % With no elected cluster head, each active node sends directly
                % to the base station.
                for i = 1:numel(aliveIndices)
                    nodeIndex = aliveIndices(i);
                    distance = hypot(nodes(nodeIndex).x - bsX, ...
                                     nodes(nodeIndex).y - bsY);
                    directDistances(end + 1) = distance; %#ok<AGROW>
                    txEnergy = transmissionEnergy( ...
                        distance, packetSize, E_elec, E_fs, E_mp, d0);
                    sentPackets = sentPackets + 1;
                    if nodes(nodeIndex).E >= txEnergy
                        nodes(nodeIndex).E = nodes(nodeIndex).E - txEnergy;
                        receivedPackets = receivedPackets + 1;
                    else
                        nodes(nodeIndex).E = 0;
                    end
                end
            else
                memberPacketsAtHead = zeros(1, numNodes);

                % Members send one packet to their nearest cluster head.
                for i = 1:numel(memberIndices)
                    memberIndex = memberIndices(i);
                    dx = [nodes(clusterHeadIndices).x] - nodes(memberIndex).x;
                    dy = [nodes(clusterHeadIndices).y] - nodes(memberIndex).y;
                    distances = hypot(dx, dy);
                    [distance, nearestHeadPosition] = min(distances);
                    headIndex = clusterHeadIndices(nearestHeadPosition);
                    intraDistances(end + 1) = distance; %#ok<AGROW>

                    txEnergy = transmissionEnergy( ...
                        distance, packetSize, E_elec, E_fs, E_mp, d0);
                    sentPackets = sentPackets + 1;
                    if nodes(memberIndex).E < txEnergy
                        nodes(memberIndex).E = 0;
                        continue;
                    end
                    nodes(memberIndex).E = nodes(memberIndex).E - txEnergy;

                    rxEnergy = packetSize * E_elec;
                    if nodes(headIndex).E >= rxEnergy
                        nodes(headIndex).E = nodes(headIndex).E - rxEnergy;
                        memberPacketsAtHead(headIndex) = ...
                            memberPacketsAtHead(headIndex) + 1;
                    else
                        nodes(headIndex).E = 0;
                    end
                end

                % Each cluster head forwards its own packet and each member
                % packet it successfully received to the base station.
                for i = 1:numel(clusterHeadIndices)
                    headIndex = clusterHeadIndices(i);
                    distance = hypot(nodes(headIndex).x - bsX, ...
                                     nodes(headIndex).y - bsY);
                    interDistances(end + 1) = distance; %#ok<AGROW>
                    txEnergy = transmissionEnergy( ...
                        distance, packetSize, E_elec, E_fs, E_mp, d0);
                    packetsToForward = memberPacketsAtHead(headIndex) + 1;

                    for packetIndex = 1:packetsToForward
                        sentPackets = sentPackets + 1;
                        if nodes(headIndex).E >= txEnergy
                            nodes(headIndex).E = nodes(headIndex).E - txEnergy;
                            receivedPackets = receivedPackets + 1;
                        else
                            nodes(headIndex).E = 0;
                        end
                    end
                end
            end
        end

        roundsCompleted = roundNumber;
        aliveHistory(roundNumber + 1) = sum([nodes.E] > 0);
        energyHistory(roundNumber + 1) = sum(max([nodes.E], 0));
        generatedHistory(roundNumber + 1) = generatedPackets;
        receivedHistory(roundNumber + 1) = receivedPackets;
        sentHistory(roundNumber + 1) = sentPackets;
        if generatedPackets > 0
            roundPrHistory(roundNumber + 1) = ...
                receivedPackets / generatedPackets;
        end
        totalGenerated = sum(generatedHistory(1:roundNumber + 1));
        totalReceived = sum(receivedHistory(1:roundNumber + 1));
        if totalGenerated > 0
            cumulativePrHistory(roundNumber + 1) = ...
                totalReceived / totalGenerated;
        end
        if ~isempty(intraDistances)
            intraDistanceHistory(roundNumber + 1) = mean(intraDistances);
        end
        if ~isempty(interDistances)
            interDistanceHistory(roundNumber + 1) = mean(interDistances);
        end
        if ~isempty(directDistances)
            directDistanceHistory(roundNumber + 1) = mean(directDistances);
        end

        if aliveHistory(roundNumber + 1) == 0
            break;
        end
    end

    rounds = 0:roundsCompleted;
    aliveNodes = aliveHistory(1:roundsCompleted + 1);
    deadNodes = numNodes - aliveNodes;
    energyLeft = energyHistory(1:roundsCompleted + 1);
    packetsGenerated = generatedHistory(1:roundsCompleted + 1);
    packetsReceived = receivedHistory(1:roundsCompleted + 1);
    packetsSent = sentHistory(1:roundsCompleted + 1);
    prrPerRound = roundPrHistory(1:roundsCompleted + 1);
    prr = cumulativePrHistory(1:roundsCompleted + 1);
    intraDistance = intraDistanceHistory(1:roundsCompleted + 1);
    interDistance = interDistanceHistory(1:roundsCompleted + 1);
    directDistance = directDistanceHistory(1:roundsCompleted + 1);
    clusterHeads = clusterHeadHistory(1:roundsCompleted + 1);

    firstDeathRound = firstRound(aliveNodes < numNodes, rounds);
    halfDeathRound = firstRound(deadNodes >= ceil(numNodes / 2), rounds);
    lastDeathRound = firstRound(aliveNodes == 0, rounds);

    metrics.(protocol).rounds = rounds;
    metrics.(protocol).alive_nodes = aliveNodes;
    metrics.(protocol).dead_nodes = deadNodes;
    metrics.(protocol).energy_left = energyLeft;
    metrics.(protocol).packets_generated = packetsGenerated;
    metrics.(protocol).packets_sent = packetsSent;
    metrics.(protocol).packets_received = packetsReceived;
    metrics.(protocol).prr_per_round = prrPerRound;
    metrics.(protocol).prr = prr;
    metrics.(protocol).intra_cluster_distance = intraDistance;
    metrics.(protocol).inter_cluster_distance = interDistance;
    metrics.(protocol).direct_to_bs_distance = directDistance;
    metrics.(protocol).cluster_heads = clusterHeads;
    metrics.(protocol).FND = firstDeathRound;
    metrics.(protocol).HND = halfDeathRound;
    metrics.(protocol).LND = lastDeathRound;
    metrics.(protocol).time_to_first_node_death_rounds = firstDeathRound;
    metrics.(protocol).time_to_half_nodes_dead_rounds = halfDeathRound;
    metrics.(protocol).time_to_last_node_death_rounds = lastDeathRound;
    metrics.(protocol).overall_network_lifetime_rounds = lastDeathRound;
    metrics.(protocol).lifetime_censored = isnan(lastDeathRound);
    metrics.(protocol).mean_intra_cluster_distance = finiteMean(intraDistance);
    metrics.(protocol).mean_inter_cluster_distance = finiteMean(interDistance);
    metrics.(protocol).total_packets_generated = sum(packetsGenerated);
    metrics.(protocol).total_packets_received = sum(packetsReceived);
    if sum(packetsGenerated) > 0
        metrics.(protocol).overall_prr = ...
            sum(packetsReceived) / sum(packetsGenerated);
    else
        metrics.(protocol).overall_prr = NaN;
    end
end

%% Save data and generate comparison plots
save('simulation_results.mat', 'metrics', 'maxRounds', 'rngSeed');
plotFile = 'simulation_comparison.png';
plotSimulationResults(metrics, numNodes, plotFile);

fprintf('Simulation complete.\n');
fprintf('Saved metrics to simulation_results.mat\n');
fprintf('Saved comparison plots to %s\n', plotFile);
fprintf('FND / HND / LND (rounds): S_MAC = %.0f / %.0f / %.0f, GA_MAC = %.0f / %.0f / %.0f\n', ...
    metrics.S_MAC.FND, metrics.S_MAC.HND, metrics.S_MAC.LND, ...
    metrics.GA_MAC.FND, metrics.GA_MAC.HND, metrics.GA_MAC.LND);
end

function energy = transmissionEnergy(distance, packetSize, E_elec, E_fs, E_mp, d0)
    if distance < d0
        energy = packetSize * (E_elec + E_fs * distance^2);
    else
        energy = packetSize * (E_elec + E_mp * distance^4);
    end
end

function [bestDutyCycle, bestPCH] = runGeneticAlgorithm( ...
        nodes, aliveIndices, bsX, bsY, networkArea, packetSize, ...
        E_elec, E_fs, E_mp, E_idle, E_sleep, d0, dutyBounds, pBounds, ...
        populationSize, generationCount)
    population = zeros(populationSize, 2);
    population(:, 1) = dutyBounds(1) + ...
        rand(populationSize, 1) * diff(dutyBounds);
    population(:, 2) = pBounds(1) + ...
        rand(populationSize, 1) * diff(pBounds);
    fitness = zeros(populationSize, 1);

    for generation = 1:generationCount
        for candidate = 1:populationSize
            fitness(candidate) = estimateLifetimeFitness( ...
                population(candidate, :), nodes, aliveIndices, ...
                bsX, bsY, networkArea, packetSize, E_elec, E_fs, E_mp, ...
                E_idle, E_sleep, d0);
        end

        [~, order] = sort(fitness, 'descend');
        nextPopulation = zeros(size(population));
        eliteCount = min(2, populationSize);
        nextPopulation(1:eliteCount, :) = population(order(1:eliteCount), :);

        for child = eliteCount + 1:populationSize
            parent1 = tournamentSelect(population, fitness);
            parent2 = tournamentSelect(population, fitness);
            blend = rand(1, 2);
            offspring = blend .* parent1 + (1 - blend) .* parent2;

            if rand < 0.25
                offspring(1) = offspring(1) + 0.10 * diff(dutyBounds) * randn;
            end
            if rand < 0.25
                offspring(2) = offspring(2) + 0.10 * diff(pBounds) * randn;
            end

            offspring(1) = min(max(offspring(1), dutyBounds(1)), dutyBounds(2));
            offspring(2) = min(max(offspring(2), pBounds(1)), pBounds(2));
            nextPopulation(child, :) = offspring;
        end
        population = nextPopulation;
    end

    for candidate = 1:populationSize
        fitness(candidate) = estimateLifetimeFitness( ...
            population(candidate, :), nodes, aliveIndices, ...
            bsX, bsY, networkArea, packetSize, E_elec, E_fs, E_mp, ...
            E_idle, E_sleep, d0);
    end
    [~, bestIndex] = max(fitness);
    bestDutyCycle = population(bestIndex, 1);
    bestPCH = population(bestIndex, 2);
end

function parent = tournamentSelect(population, fitness)
    tournamentSize = min(3, size(population, 1));
    contestants = randperm(size(population, 1), tournamentSize);
    [~, winnerPosition] = max(fitness(contestants));
    parent = population(contestants(winnerPosition), :);
end

function fitness = estimateLifetimeFitness( ...
        candidate, nodes, aliveIndices, bsX, bsY, networkArea, ...
        packetSize, E_elec, E_fs, E_mp, E_idle, E_sleep, d0)
    dutyCycle = candidate(1);
    pCH = candidate(2);
    aliveCount = numel(aliveIndices);
    x = [nodes(aliveIndices).x];
    y = [nodes(aliveIndices).y];
    bsDistances = hypot(x - bsX, y - bsY);
    meanBsDistance = mean(bsDistances);

    % Approximate nearest-head distance for uniformly distributed nodes.
    expectedHeads = max(1, aliveCount * pCH);
    meanIntraDistance = min(hypot(networkArea^0.5, networkArea^0.5), ...
        sqrt(networkArea / (pi * expectedHeads)));
    noHeadProbability = (1 - pCH)^aliveCount;

    idleSleepCost = packetSize * ...
        (dutyCycle * E_idle + (1 - dutyCycle) * E_sleep);
    memberTxCost = transmissionEnergy( ...
        meanIntraDistance, packetSize, E_elec, E_fs, E_mp, d0);
    meanBaseTxCost = transmissionEnergy( ...
        meanBsDistance, packetSize, E_elec, E_fs, E_mp, d0);
    memberCost = (1 - noHeadProbability) * ...
        (memberTxCost + packetSize * E_elec) + ...
        noHeadProbability * meanBaseTxCost;
    forwardingCost = meanBaseTxCost;

    estimatedEnergyPerNode = idleSleepCost + ...
        (1 - pCH) * memberCost + forwardingCost;
    fitness = 1 / max(estimatedEnergyPerNode, eps);
end

function roundNumber = firstRound(condition, rounds)
    index = find(condition, 1, 'first');
    if isempty(index)
        roundNumber = NaN;
    else
        roundNumber = rounds(index);
    end
end

function value = finiteMean(values)
    values = values(isfinite(values));
    if isempty(values)
        value = NaN;
    else
        value = mean(values);
    end
end

function plotSimulationResults(metrics, numNodes, plotFile)
    figureHandle = figure('visible', 'off');
    subplot(3, 2, 1);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.alive_nodes, 'b-', ...
         metrics.GA_MAC.rounds, metrics.GA_MAC.alive_nodes, 'r-', 'LineWidth', 1.5);
    hold on;
    plot(metrics.S_MAC.rounds, ...
         (numNodes / 2) * ones(size(metrics.S_MAC.rounds)), 'k--');
    title('Alive Nodes');
    xlabel('Round');
    ylabel('Alive nodes');
    legend('S-MAC', 'GA-optimized', '50% alive threshold', 'Location', 'northeast');
    grid on;

    subplot(3, 2, 2);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.dead_nodes, 'b-', ...
         metrics.GA_MAC.rounds, metrics.GA_MAC.dead_nodes, 'r-', 'LineWidth', 1.5);
    hold on;
    plot(metrics.S_MAC.rounds, ...
         (numNodes / 2) * ones(size(metrics.S_MAC.rounds)), 'k--');
    title('Dead Nodes');
    xlabel('Round');
    ylabel('Dead nodes');
    legend('S-MAC', 'GA-optimized', 'Half-dead threshold', 'Location', 'northeast');
    grid on;

    subplot(3, 2, 3);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.prr, 'b-', ...
         metrics.GA_MAC.rounds, metrics.GA_MAC.prr, 'r-', 'LineWidth', 1.5);
    title('Cumulative Packet Reception Ratio');
    xlabel('Round');
    ylabel('PRR');
    ylim([0, 1]);
    legend('S-MAC', 'GA-optimized', 'Location', 'northeast');
    grid on;

    subplot(3, 2, 4);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.energy_left, 'b-', ...
         metrics.GA_MAC.rounds, metrics.GA_MAC.energy_left, 'r-', 'LineWidth', 1.5);
    title('Residual Network Energy');
    xlabel('Round');
    ylabel('Energy (J)');
    legend('S-MAC', 'GA-optimized', 'Location', 'northeast');
    grid on;

    subplot(3, 2, 5);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.intra_cluster_distance, ...
         'b-', metrics.GA_MAC.rounds, metrics.GA_MAC.intra_cluster_distance, ...
         'r-', 'LineWidth', 1.5);
    hold on;
    plot(metrics.S_MAC.rounds, metrics.S_MAC.inter_cluster_distance, ...
         'b--', metrics.GA_MAC.rounds, metrics.GA_MAC.inter_cluster_distance, ...
         'r--', 'LineWidth', 1.5);
    title('Mean Cluster Distances');
    xlabel('Round');
    ylabel('Distance (m)');
    legend('S-MAC intra', 'GA intra', 'S-MAC inter', 'GA inter', ...
        'Location', 'northeast');
    grid on;

    subplot(3, 2, 6);
    milestoneRounds = [ ...
        metrics.S_MAC.FND, metrics.S_MAC.HND, metrics.S_MAC.LND; ...
        metrics.GA_MAC.FND, metrics.GA_MAC.HND, metrics.GA_MAC.LND];
    bar(milestoneRounds);
    title('Node-Death Milestones');
    xlabel('Protocol');
    ylabel('Round (NaN = not reached)');
    set(gca, 'XTickLabel', {'S-MAC', 'GA-optimized'});
    legend('FND', 'HND', 'LND', 'Location', 'northeast');
    grid on;

    print(figureHandle, plotFile, '-dpng', '-r150');
    close(figureHandle);
end
