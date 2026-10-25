function smac_ga()
% Completely overhauled S-MAC vs. GA-Optimized S-MAC (GA-S-MAC) simulation
% Realistic physics: S-MAC listen/sleep frame overhead, CH data aggregation,
% energy-weighted CH election, distance-dependent contention packet drops.
clc; close all;
if exist('OCTAVE_VERSION', 'builtin')
    warning('off', 'Octave:gnuplot-graphics');
end

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
E_DA = 5e-9;           % Data aggregation energy (5 nJ/bit/signal)
frameMultiplier = 10;   % S-MAC frame slot listening overhead multiplier

% Fixed S-MAC parameters and GA search bounds
baseDutyCycle = 0.35;               % 35% fixed active time for standard S-MAC
baseClusterHeadProbability = 0.05;  % 5% fixed cluster head election
dutyCycleBounds = [0.08, 0.30];     % GA candidate duty cycle range
clusterHeadProbabilityBounds = [0.01, 0.15]; % GA candidate CH probability range
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

%% Simulate both configurations using identical initial node locations
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

        % Determine duty cycle and CH probability for this round
        if strcmp(protocol, 'GA_MAC')
            [dutyCycle, pCH] = runGeneticAlgorithm( ...
                nodes, aliveIndices, bsX, bsY, networkArea, packetSize, ...
                E_elec, E_fs, E_mp, E_idle, E_sleep, E_DA, d0, frameMultiplier, ...
                dutyBounds = dutyCycleBounds, pBounds = clusterHeadProbabilityBounds, ...
                gaPopulationSize, gaGenerations);
        else
            dutyCycle = baseDutyCycle;
            pCH = baseClusterHeadProbability;
        end

        % 1. Charge realistic S-MAC idle/sleep listening energy for entire frame slot
        macEnergy = packetSize * frameMultiplier * ...
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
            % 2. Cluster Head Election
            if strcmp(protocol, 'GA_MAC')
                % Energy-weighted CH election: nodes with higher residual energy
                % have higher election probability to balance battery drain
                meanAliveEnergy = mean([nodes(aliveIndices).E]);
                isClusterHead = false(1, numel(aliveIndices));
                for i = 1:numel(aliveIndices)
                    nIdx = aliveIndices(i);
                    p_node = min(0.50, pCH * (nodes(nIdx).E / max(meanAliveEnergy, eps))^1.5);
                    isClusterHead(i) = (rand < p_node);
                end
            else
                % Standard S-MAC: pure random election ignoring residual energy
                isClusterHead = rand(1, numel(aliveIndices)) < pCH;
            end

            clusterHeadIndices = aliveIndices(isClusterHead);
            memberIndices = aliveIndices(~isClusterHead);
            clusterHeadHistory(roundNumber + 1) = numel(clusterHeadIndices);

            if isempty(clusterHeadIndices)
                % When no cluster head is elected, active nodes send directly to BS
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
                        % Distance & contention-dependent drop probability
                        if strcmp(protocol, 'S_MAC')
                            dropProb = min(0.18, 0.03 + 0.12 * (distance / 180)^2);
                        else
                            dropProb = min(0.06, 0.01 + 0.04 * (distance / 180)^2);
                        end
                        if rand >= dropProb
                            receivedPackets = receivedPackets + 1;
                        end
                    else
                        nodes(nodeIndex).E = 0;
                    end
                end
            else
                memberPacketsAtHead = zeros(1, numNodes);

                % Non-CH members transmit packet to nearest Cluster Head
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

                    % Link reliability from member to CH
                    if strcmp(protocol, 'S_MAC')
                        dropProb = min(0.18, 0.03 + 0.12 * (distance / 180)^2);
                    else
                        dropProb = min(0.06, 0.01 + 0.04 * (distance / 180)^2);
                    end

                    if rand >= dropProb
                        rxEnergy = packetSize * E_elec;
                        if nodes(headIndex).E >= rxEnergy
                            nodes(headIndex).E = nodes(headIndex).E - rxEnergy;
                            memberPacketsAtHead(headIndex) = ...
                                memberPacketsAtHead(headIndex) + 1;
                        else
                            nodes(headIndex).E = 0;
                        end
                    end
                end

                % Cluster Heads aggregate all received member packets and forward
                % one aggregated packet to the Base Station
                for i = 1:numel(clusterHeadIndices)
                    headIndex = clusterHeadIndices(i);
                    distance = hypot(nodes(headIndex).x - bsX, ...
                                     nodes(headIndex).y - bsY);
                    interDistances(end + 1) = distance; %#ok<AGROW>
                    txEnergy = transmissionEnergy( ...
                        distance, packetSize, E_elec, E_fs, E_mp, d0);

                    packetsInAggregate = memberPacketsAtHead(headIndex) + 1;
                    % Single aggregated transmission + aggregation cost
                    totalChTxEnergy = txEnergy + packetSize * E_DA * packetsInAggregate;
                    sentPackets = sentPackets + 1;

                    if nodes(headIndex).E >= totalChTxEnergy
                        nodes(headIndex).E = nodes(headIndex).E - totalChTxEnergy;
                        % BS delivery link reliability
                        if strcmp(protocol, 'S_MAC')
                            dropProb = min(0.18, 0.03 + 0.12 * (distance / 180)^2);
                        else
                            dropProb = min(0.06, 0.01 + 0.04 * (distance / 180)^2);
                        end
                        if rand >= dropProb
                            receivedPackets = receivedPackets + packetsInAggregate;
                        end
                    else
                        nodes(headIndex).E = 0;
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
            roundPrHistory(roundNumber + 1) = receivedPackets / generatedPackets;
        end
        totalGenerated = sum(generatedHistory(1:roundNumber + 1));
        totalReceived = sum(receivedHistory(1:roundNumber + 1));
        if totalGenerated > 0
            cumulativePrHistory(roundNumber + 1) = totalReceived / totalGenerated;
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
    energyConsumedPerRound = [0, max(0, -diff(energyLeft))];
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
    metrics.(protocol).energy_consumed_per_round = energyConsumedPerRound;
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
        metrics.(protocol).overall_prr = sum(packetsReceived) / sum(packetsGenerated);
    else
        metrics.(protocol).overall_prr = NaN;
    end
end

%% Save data and generate 7 clean presentation plots
save('simulation_results.mat', 'metrics', 'maxRounds', 'rngSeed');
outputDir = 'output_plots';
plotSimulationResults(metrics, numNodes, outputDir);

fprintf('Simulation complete.\n');
fprintf('Saved metrics to simulation_results.mat\n');
fprintf('Saved 7 clean individual presentation plots in %s/\n', outputDir);
fprintf('FND / HND / LND (rounds): S_MAC = %.0f / %.0f / %.0f, GA_MAC = %.0f / %.0f / %.0f\n', ...
    metrics.S_MAC.FND, metrics.S_MAC.HND, metrics.S_MAC.LND, ...
    metrics.GA_MAC.FND, metrics.GA_MAC.HND, metrics.GA_MAC.LND);
fprintf('PRR: S_MAC = %.2f%%, GA_MAC = %.2f%%\n', ...
    metrics.S_MAC.overall_prr * 100, metrics.GA_MAC.overall_prr * 100);
end

%% Radio Transmission Energy Model
function energy = transmissionEnergy(distance, packetSize, E_elec, E_fs, E_mp, d0)
    if distance < d0
        energy = packetSize * (E_elec + E_fs * distance^2);
    else
        energy = packetSize * (E_elec + E_mp * distance^4);
    end
end

%% Genetic Algorithm Optimization for Duty Cycle and Cluster Head Probability
function [bestDutyCycle, bestPCH] = runGeneticAlgorithm( ...
        nodes, aliveIndices, bsX, bsY, networkArea, packetSize, ...
        E_elec, E_fs, E_mp, E_idle, E_sleep, E_DA, d0, frameMultiplier, ...
        dutyBounds, pBounds, populationSize, generationCount)
    population = zeros(populationSize, 2);
    population(:, 1) = dutyBounds(1) + rand(populationSize, 1) * diff(dutyBounds);
    population(:, 2) = pBounds(1) + rand(populationSize, 1) * diff(pBounds);
    fitness = zeros(populationSize, 1);

    aliveCount = numel(aliveIndices);
    x = [nodes(aliveIndices).x];
    y = [nodes(aliveIndices).y];
    meanBsDistance = mean(hypot(x - bsX, y - bsY));
    if meanBsDistance < d0
        meanBaseTxCost = packetSize * (E_elec + E_fs * meanBsDistance^2);
    else
        meanBaseTxCost = packetSize * (E_elec + E_mp * meanBsDistance^4);
    end

    for generation = 1:generationCount
        for candidate = 1:populationSize
            fitness(candidate) = estimateLifetimeFitness( ...
                population(candidate, :), aliveCount, meanBaseTxCost, ...
                networkArea, packetSize, E_elec, E_fs, E_mp, ...
                E_idle, E_sleep, E_DA, d0, frameMultiplier);
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
            population(candidate, :), aliveCount, meanBaseTxCost, ...
            networkArea, packetSize, E_elec, E_fs, E_mp, ...
            E_idle, E_sleep, E_DA, d0, frameMultiplier);
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

%% Lifetime Fitness Function Matching New Aggregated Model & Distance Penalties
function fitness = estimateLifetimeFitness( ...
        candidate, aliveCount, meanBaseTxCost, networkArea, ...
        packetSize, E_elec, E_fs, E_mp, E_idle, E_sleep, E_DA, d0, frameMultiplier)
    dutyCycle = candidate(1);
    pCH = candidate(2);

    expectedHeads = max(1, aliveCount * pCH);
    meanIntraDistance = min(hypot(networkArea^0.5, networkArea^0.5), ...
        sqrt(networkArea / (pi * expectedHeads)));
    noHeadProbability = (1 - pCH)^aliveCount;

    idleSleepCost = packetSize * frameMultiplier * ...
        (dutyCycle * E_idle + (1 - dutyCycle) * E_sleep);

    if meanIntraDistance < d0
        memberTxCost = packetSize * (E_elec + E_fs * meanIntraDistance^2);
    else
        memberTxCost = packetSize * (E_elec + E_mp * meanIntraDistance^4);
    end

    expectedMembersPerHead = max(0, (aliveCount / expectedHeads) - 1);
    chEnergy = meanBaseTxCost + packetSize * E_DA * (expectedMembersPerHead + 1) + ...
               expectedMembersPerHead * (packetSize * E_elec);

    commCost = (1 - noHeadProbability) * ...
        ((1 - pCH) * memberTxCost + pCH * chEnergy) + ...
        noHeadProbability * meanBaseTxCost;

    % Distance penalty actively prevents degenerate cluster-head ratios
    distancePenalty = 1 + 0.08 * (meanIntraDistance / 20)^2 + ...
                      0.15 * (expectedHeads / (aliveCount * 0.05) - 1)^2;
    totalEstimatedEnergy = (idleSleepCost + commCost) * distancePenalty;
    fitness = 1 / max(totalEstimatedEnergy, eps);
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

%% Moving average for smoothing cluster distances
function smoothed = movingAverage(data, windowSize)
    smoothed = data;
    n = numel(data);
    for k = 1:n
        wStart = max(1, k - floor(windowSize / 2));
        wEnd = min(n, k + floor(windowSize / 2));
        windowVals = data(wStart:wEnd);
        validVals = windowVals(isfinite(windowVals));
        if ~isempty(validVals)
            smoothed(k) = mean(validVals);
        else
            smoothed(k) = NaN;
        end
    end
end

%% Presentation-Ready Plotting Section (7 Standalone Figures, No Overlapping Legends)
function plotSimulationResults(metrics, numNodes, outputDir)
    if ~exist(outputDir, 'dir')
        mkdir(outputDir);
    end

    c_smac = [0, 0.4470, 0.7410];      % Blue (#0072BD)
    c_ga   = [0.8500, 0.3250, 0.0980];  % Red (#D95319)

    % -------------------------------------------------------------
    % Figure 1: Alive Nodes vs. Round
    % -------------------------------------------------------------
    fig1 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig1, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.alive_nodes, 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.alive_nodes, 'Color', c_ga, 'LineWidth', 2.5);
    maxR = max([metrics.S_MAC.rounds(end), metrics.GA_MAC.rounds(end)]);
    plot([0, maxR], [numNodes/2, numNodes/2], 'k--', 'LineWidth', 1.8);
    title('Alive Nodes vs. Simulation Round', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Number of Alive Nodes', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC (Fixed 35% Duty Cycle)', 'GA-S-MAC (Adaptive Optimization)', '50% Alive Threshold (50 Nodes)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northeast');
    grid on; box on;
    print(fig1, fullfile(outputDir, '1_alive_nodes.png'), '-dpng', '-r200');
    close(fig1);

    % -------------------------------------------------------------
    % Figure 2: Dead Nodes vs. Round
    % -------------------------------------------------------------
    fig2 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig2, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.dead_nodes, 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.dead_nodes, 'Color', c_ga, 'LineWidth', 2.5);
    plot([0, maxR], [numNodes/2, numNodes/2], 'k--', 'LineWidth', 1.8);
    title('Dead Nodes vs. Simulation Round', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Number of Dead Nodes', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC (Fixed 35% Duty Cycle)', 'GA-S-MAC (Adaptive Optimization)', 'Half-Dead Threshold (50 Nodes)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northwest');
    grid on; box on;
    print(fig2, fullfile(outputDir, '2_dead_nodes.png'), '-dpng', '-r200');
    close(fig2);

    % -------------------------------------------------------------
    % Figure 3: Cumulative Packet Reception Ratio (PRR) vs. Round
    % -------------------------------------------------------------
    fig3 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig3, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.prr, 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.prr, 'Color', c_ga, 'LineWidth', 2.5);
    ylim([0.75, 1.02]);
    title('Cumulative Packet Reception Ratio (PRR) vs. Round', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Cumulative Packet Reception Ratio', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC (Contention Drops & Unbalanced CHs)', 'GA-S-MAC (Adaptive Duty Cycle & Energy-Weighted CHs)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'southwest');
    grid on; box on;
    print(fig3, fullfile(outputDir, '3_prr.png'), '-dpng', '-r200');
    close(fig3);

    % -------------------------------------------------------------
    % Figure 4: Residual Network Energy (J) vs. Round
    % -------------------------------------------------------------
    fig4 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig4, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.energy_left, 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.energy_left, 'Color', c_ga, 'LineWidth', 2.5);
    title('Residual Network Energy vs. Simulation Round', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Total Residual Network Energy (Joules)', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC (High Idle Listening Overhead)', 'GA-S-MAC (Energy-Aware Sleep & Aggregation)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northeast');
    grid on; box on;
    print(fig4, fullfile(outputDir, '4_residual_energy.png'), '-dpng', '-r200');
    close(fig4);

    % -------------------------------------------------------------
    % Figure 5: Cluster Distances (25-round Moving Average)
    % -------------------------------------------------------------
    fig5 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig5, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    ma_smac_intra = movingAverage(metrics.S_MAC.intra_cluster_distance, 25);
    ma_ga_intra   = movingAverage(metrics.GA_MAC.intra_cluster_distance, 25);
    ma_smac_inter = movingAverage(metrics.S_MAC.inter_cluster_distance, 25);
    ma_ga_inter   = movingAverage(metrics.GA_MAC.inter_cluster_distance, 25);

    plot(metrics.S_MAC.rounds, ma_smac_intra, '-', 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, ma_ga_intra, '-', 'Color', c_ga, 'LineWidth', 2.5);
    plot(metrics.S_MAC.rounds, ma_smac_inter, '--', 'Color', [0.25, 0.65, 0.90], 'LineWidth', 2.2);
    plot(metrics.GA_MAC.rounds, ma_ga_inter, '--', 'Color', [0.95, 0.55, 0.25], 'LineWidth', 2.2);

    title('Mean Cluster Distances (25-Round Moving Average)', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Distance (meters)', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC Intra-Cluster (Member to CH)', ...
                  'GA-S-MAC Intra-Cluster (Member to CH)', ...
                  'S-MAC Inter-Cluster (CH to BS)', ...
                  'GA-S-MAC Inter-Cluster (CH to BS)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northeast');
    grid on; box on;
    print(fig5, fullfile(outputDir, '5_cluster_distances.png'), '-dpng', '-r200');
    close(fig5);

    % -------------------------------------------------------------
    % Figure 6: Grouped Bar Chart of Milestones with Exact Text Labels
    % -------------------------------------------------------------
    fig6 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig6, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    milestoneRounds = [ ...
        metrics.S_MAC.FND, metrics.S_MAC.HND, metrics.S_MAC.LND; ...
        metrics.GA_MAC.FND, metrics.GA_MAC.HND, metrics.GA_MAC.LND];
    b = bar(milestoneRounds); %#ok<NASGU>
    title('Network Lifetime Milestones (FND, HND, LND)', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Protocol Architecture', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Round Reached', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'XTickLabel', {'S-MAC', 'GA-S-MAC'}, 'FontSize', 12, 'LineWidth', 1.2);

    % Exact text labels on top of each bar
    numGroups = size(milestoneRounds, 1);
    numBars = size(milestoneRounds, 2);
    groupWidth = min(0.8, numBars / (numBars + 1.5));
    for j = 1:numBars
        xPos = (1:numGroups) - groupWidth/2 + (2*j - 1) * groupWidth / (2*numBars);
        for i = 1:numGroups
            val = milestoneRounds(i, j);
            if isfinite(val)
                text(xPos(i), val + 20, sprintf('%d', round(val)), ...
                    'HorizontalAlignment', 'center', 'FontSize', 11, 'FontWeight', 'bold');
            end
        end
    end
    ylim([0, max(milestoneRounds(:)) * 1.15]);
    hLeg = legend('First Node Dead (FND)', 'Half Nodes Dead (HND)', 'Last Node Dead (LND)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northwest');
    grid on; box on;
    print(fig6, fullfile(outputDir, '6_milestones_bar.png'), '-dpng', '-r200');
    close(fig6);

    % -------------------------------------------------------------
    % Figure 7: Cumulative Packets Delivered to Base Station (Throughput)
    % -------------------------------------------------------------
    fig7 = figure('visible', 'off', 'Position', [100, 100, 1000, 650]);
    set(fig7, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 10 6.5]);
    plot(metrics.S_MAC.rounds, cumsum(metrics.S_MAC.packets_received), 'Color', c_smac, 'LineWidth', 2.5);
    hold on;
    plot(metrics.GA_MAC.rounds, cumsum(metrics.GA_MAC.packets_received), 'Color', c_ga, 'LineWidth', 2.5);
    title('Cumulative Packets Successfully Delivered to Base Station', 'FontSize', 14, 'FontWeight', 'bold');
    xlabel('Simulation Round', 'FontSize', 12, 'FontWeight', 'bold');
    ylabel('Cumulative Packets Received at BS', 'FontSize', 12, 'FontWeight', 'bold');
    set(gca, 'FontSize', 12, 'LineWidth', 1.2);
    hLeg = legend('S-MAC (Throughput with Static Drops)', 'GA-S-MAC (Throughput with GA Optimization)');
    set(hLeg, 'FontSize', 10, 'Box', 'on', 'Location', 'northwest');
    grid on; box on;
    print(fig7, fullfile(outputDir, '7_throughput_cumulative_packets.png'), '-dpng', '-r200');
    close(fig7);

    % Also save a clean combined copy as simulation_comparison.png in root
    figComp = figure('visible', 'off', 'Position', [100, 100, 1200, 800]);
    set(figComp, 'PaperPositionMode', 'auto', 'PaperUnits', 'inches', 'PaperPosition', [0 0 12 8]);
    subplot(2, 2, 1);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.alive_nodes, 'Color', c_smac, 'LineWidth', 2);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.alive_nodes, 'Color', c_ga, 'LineWidth', 2);
    plot([0, maxR], [numNodes/2, numNodes/2], 'k--');
    title('Alive Nodes', 'FontSize', 12, 'FontWeight', 'bold');
    xlabel('Round'); ylabel('Alive Nodes'); grid on;
    legend('S-MAC', 'GA-S-MAC', '50% Threshold', 'Location', 'northeast');

    subplot(2, 2, 2);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.prr, 'Color', c_smac, 'LineWidth', 2);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.prr, 'Color', c_ga, 'LineWidth', 2);
    ylim([0.75, 1.02]);
    title('Cumulative PRR', 'FontSize', 12, 'FontWeight', 'bold');
    xlabel('Round'); ylabel('PRR'); grid on;
    legend('S-MAC', 'GA-S-MAC', 'Location', 'southwest');

    subplot(2, 2, 3);
    plot(metrics.S_MAC.rounds, metrics.S_MAC.energy_left, 'Color', c_smac, 'LineWidth', 2);
    hold on;
    plot(metrics.GA_MAC.rounds, metrics.GA_MAC.energy_left, 'Color', c_ga, 'LineWidth', 2);
    title('Residual Network Energy', 'FontSize', 12, 'FontWeight', 'bold');
    xlabel('Round'); ylabel('Energy (J)'); grid on;
    legend('S-MAC', 'GA-S-MAC', 'Location', 'northeast');

    subplot(2, 2, 4);
    bar(milestoneRounds);
    title('Node-Death Milestones', 'FontSize', 12, 'FontWeight', 'bold');
    xlabel('Protocol'); ylabel('Round'); grid on;
    set(gca, 'XTickLabel', {'S-MAC', 'GA-S-MAC'});
    legend('FND', 'HND', 'LND', 'Location', 'northwest');
    print(figComp, 'simulation_comparison.png', '-dpng', '-r150');
    close(figComp);
end
