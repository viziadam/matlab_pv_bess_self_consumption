function plotResult = plot_selected_industrial_profiles(result, ratioLimit)
% PLOT_SELECTED_INDUSTRIAL_PROFILES
%
% Kivalasztja es kirajzolja azokat az ipari jellegu atlagos napi
% fogyasztasi profilokat, amelyeknel:
%
%   Category == "industry"
%   MeanPower_kW <= 1500
%   P_10_12_peak <= ratioLimit * P_daily_avg_profile_peak
%
% Hasznalat:
%
%   plotResult = plot_selected_industrial_profiles(result, 0.70);
%   plotResult = plot_selected_industrial_profiles(result, 0.60);

    if nargin < 2 || isempty(ratioLimit)
        ratioLimit = 0.70;
    end

    if ratioLimit <= 0 || ratioLimit > 1
        error('A ratioLimit 0 es 1 kozotti ertek legyen, pl. 0.60 vagy 0.70.');
    end

    maxMeanPower_kW = 1500;
    windowHours = [10 12];
    maxProfilesPerFigure = 12;

    if ~isstruct(result)
        error('A bemenetnek a processElectricityLoadDiagrams() result strukturajanak kell lennie.');
    end

    if isfield(result, 'dailyProfiles')
        dailyProfiles = result.dailyProfiles;
    elseif isfield(result, 'dailyProfiles_kW')
        dailyProfiles = result.dailyProfiles_kW;
    else
        error('A result nem tartalmaz dailyProfiles vagy dailyProfiles_kW mezot.');
    end

    if isfield(result, 'timeOfDay')
        timeOfDay = result.timeOfDay;
    elseif isfield(result, 'timeOfDayOriginal')
        timeOfDay = result.timeOfDayOriginal;
    else
        error('A result nem tartalmaz timeOfDay vagy timeOfDayOriginal mezot.');
    end

    if isfield(result, 'summaryTable')
        summaryTable = result.summaryTable;
    elseif isfield(result, 'candidateTable')
        summaryTable = result.candidateTable;
    else
        error('A result nem tartalmaz summaryTable vagy candidateTable mezot.');
    end

    if height(summaryTable) ~= size(dailyProfiles, 2)
        error('A summaryTable sorainak szama nem egyezik a dailyProfiles oszlopainak szamaval.');
    end

    customerNames = string(summaryTable.Customer(:));
    category = string(summaryTable.Category(:));

    if ismember('MeanPower_kW', summaryTable.Properties.VariableNames)
        meanPower_kW = double(summaryTable.MeanPower_kW(:));
    else
        error('A summaryTable nem tartalmaz MeanPower_kW oszlopot.');
    end

    if isduration(timeOfDay)
        time_h = hours(timeOfDay(:));
    elseif isdatetime(timeOfDay)
        time_h = hour(timeOfDay(:)) + minute(timeOfDay(:)) / 60 + second(timeOfDay(:)) / 3600;
    else
        time_h = double(timeOfDay(:));
    end

    windowMask = time_h >= windowHours(1) & time_h < windowHours(2);

    if ~any(windowMask)
        error('A 10-12 ora kozotti vizsgalt idoszakhoz nem tartozik minta.');
    end

    nProfiles = size(dailyProfiles, 2);

    dailyAvgProfilePeak_kW = nan(nProfiles, 1);
    windowPeak_kW = nan(nProfiles, 1);
    windowMean_kW = nan(nProfiles, 1);
    windowPeakToDailyPeakRatio = nan(nProfiles, 1);

    for i = 1:nProfiles

        prof = dailyProfiles(:, i);

        if all(~isfinite(prof))
            continue;
        end

        dailyAvgProfilePeak_kW(i) = max(prof, [], 'omitnan');
        windowPeak_kW(i) = max(prof(windowMask), [], 'omitnan');
        windowMean_kW(i) = mean(prof(windowMask), 'omitnan');

        if dailyAvgProfilePeak_kW(i) > 0
            windowPeakToDailyPeakRatio(i) = ...
                windowPeak_kW(i) / dailyAvgProfilePeak_kW(i);
        end
    end

    selectedMask = ...
        category == "industry" & ...
        isfinite(meanPower_kW) & ...
        meanPower_kW <= maxMeanPower_kW & ...
        isfinite(windowPeakToDailyPeakRatio) & ...
        windowPeakToDailyPeakRatio <= ratioLimit;

    selectedIdx = find(selectedMask);

    selectedTable = table();

    if isempty(selectedIdx)
        warning('Nincs olyan ipari profil, amely teljesiti a megadott %.0f %% limitet.', ratioLimit * 100);

        plotResult = struct();
        plotResult.selectedIdx = [];
        plotResult.selectedTable = selectedTable;
        plotResult.figures = gobjects(0);
        return;
    end

    selectedTable.Customer = customerNames(selectedIdx);
    selectedTable.Category = category(selectedIdx);
    selectedTable.MeanPower_kW = meanPower_kW(selectedIdx);
    selectedTable.DailyAvgProfilePeak_kW = dailyAvgProfilePeak_kW(selectedIdx);
    selectedTable.Window10_12Peak_kW = windowPeak_kW(selectedIdx);
    selectedTable.Window10_12Mean_kW = windowMean_kW(selectedIdx);
    selectedTable.Window10_12PeakToDailyPeakRatio = windowPeakToDailyPeakRatio(selectedIdx);

    selectedTable = sortrows(selectedTable, ...
        {'Window10_12PeakToDailyPeakRatio', 'MeanPower_kW'}, ...
        {'ascend', 'ascend'});

    selectedIdxSorted = zeros(height(selectedTable), 1);

    for i = 1:height(selectedTable)
        selectedIdxSorted(i) = find(customerNames == selectedTable.Customer(i), 1, 'first');
    end

    selectedIdx = selectedIdxSorted;

    fprintf('\nKirajzolasra kivalasztott ipari profilok:\n');
    fprintf('Feltetel: industry, MeanPower <= %.0f kW, P_10_12_peak <= %.0f %% * P_daily_peak\n\n', ...
        maxMeanPower_kW, ratioLimit * 100);

    disp(selectedTable);

    nSelected = numel(selectedIdx);
    nFigures = ceil(nSelected / maxProfilesPerFigure);

    figures = gobjects(nFigures, 1);

    for figIdx = 1:nFigures

        iStart = (figIdx - 1) * maxProfilesPerFigure + 1;
        iEnd = min(figIdx * maxProfilesPerFigure, nSelected);

        idxThis = selectedIdx(iStart:iEnd);

        profilesThis = dailyProfiles(:, idxThis);
        namesThis = customerNames(idxThis);

        validVals = profilesThis(isfinite(profilesThis));

        if isempty(validVals)
            yMax = 1;
        else
            yMax = max(validVals);
        end

        figures(figIdx) = figure('Color', 'w', ...
            'Name', sprintf('Kivalasztott ipari profilok %d/%d', figIdx, nFigures), ...
            'Position', [100, 100, 1500, 800]);

        hold on;
        grid on;
        box on;

        patch( ...
            [windowHours(1), windowHours(2), windowHours(2), windowHours(1)], ...
            [0, 0, 1.12 * yMax, 1.12 * yMax], ...
            [0.90, 0.90, 0.90], ...
            'EdgeColor', 'none', ...
            'FaceAlpha', 0.35, ...
            'DisplayName', '10-12 vizsgalt idoszak');

        for k = 1:numel(idxThis)

            idx = idxThis(k);

            labelText = sprintf('%s | atlag %.0f kW | napi csucs %.0f kW | 10-12 csucs %.0f kW | arany %.1f%%', ...
                customerNames(idx), ...
                meanPower_kW(idx), ...
                dailyAvgProfilePeak_kW(idx), ...
                windowPeak_kW(idx), ...
                100 * windowPeakToDailyPeakRatio(idx));

            plot(time_h, dailyProfiles(:, idx), ...
                'LineWidth', 1.4, ...
                'DisplayName', labelText);

            [peakVal, peakIdx] = max(dailyProfiles(:, idx), [], 'omitnan');

            if isfinite(peakVal)
                text(time_h(peakIdx), peakVal, ['  ', char(customerNames(idx))], ...
                    'FontSize', 9, ...
                    'FontWeight', 'bold', ...
                    'VerticalAlignment', 'middle', ...
                    'HorizontalAlignment', 'left');
            end
        end

        groupAverage = mean(profilesThis, 2, 'omitnan');

        plot(time_h, groupAverage, ...
            'k', ...
            'LineWidth', 3.0, ...
            'DisplayName', 'A kijelolt profilok atlaga');

        xlabel('Napon beluli ido [h]');
        ylabel('Atlagos teljesitmeny [kW]');

        title(sprintf('Ipari profilok: P_{10-12,csucs} <= %.0f%% * P_{napi,csucs}, MeanPower <= %.0f kW - %d/%d. abra', ...
            ratioLimit * 100, maxMeanPower_kW, figIdx, nFigures));

        xlim([0 24]);
        ylim([0 1.12 * yMax]);
        xticks(0:2:24);

        legend('Location', 'eastoutside', 'Interpreter', 'none');

        hold off;
    end

    plotResult = struct();

    plotResult.selectedIdx = selectedIdx;
    plotResult.selectedTable = selectedTable;
    plotResult.selectedProfiles = dailyProfiles(:, selectedIdx);
    plotResult.selectedCustomerNames = customerNames(selectedIdx);
    plotResult.figures = figures;

    plotResult.settings = struct();
    plotResult.settings.ratioLimit = ratioLimit;
    plotResult.settings.maxMeanPower_kW = maxMeanPower_kW;
    plotResult.settings.windowHours = windowHours;
end