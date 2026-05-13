function plotResult = plot_load_profile_details(txtFileName, profileNumber)
% PLOT_LOAD_PROFILE_DETAILS
%
% Egy adott fogyasztoi profil reszletes kirajzolasa.
%
% Fontos:
%   Ez a fuggveny NEM szur semmilyen 10-12 / peak arany alapjan.
%   Csak a megadott profil sorszamat vagy azonositojat rajzolja ki.
%
% Hasznalat:
%
%   plotResult = plot_load_profile_details('LD2011_2014.txt', 86);
%   plotResult = plot_load_profile_details('LD2011_2014.txt', "MT_086");

    if nargin < 1 || strlength(string(txtFileName)) == 0
        error('Meg kell adni a txt fajl nevet.');
    end

    if nargin < 2 || isempty(profileNumber)
        error('Meg kell adni a profil sorszamat vagy azonositojat, pl. 86 vagy "MT_086".');
    end

    txtFileName = char(txtFileName);

    if contains(txtFileName, filesep) || contains(txtFileName, '/')
        error('Csak a fajlnevet add meg, ne teljes eleresi utvonalat.');
    end

    functionFullPath = mfilename('fullpath');
    functionFolderPath = fileparts(functionFullPath);

    inputFolderPath = fullfile(functionFolderPath, 'consumption_csv');
    txtFilePath = fullfile(inputFolderPath, txtFileName);

    if ~isfile(txtFilePath)
        error('Nem talalhato a bemeneti fajl: %s', txtFilePath);
    end

    tempFilePath = local_create_decimal_dot_copy(txtFilePath);
    cleanupObj = onCleanup(@() local_delete_temp_file(tempFilePath)); %#ok<NASGU>

    opts = detectImportOptions(tempFilePath, ...
        'FileType', 'text', ...
        'Delimiter', ';');

    opts.VariableNamingRule = 'preserve';
    opts = setvartype(opts, opts.VariableNames{1}, 'char');

    for i = 2:numel(opts.VariableNames)
        opts = setvartype(opts, opts.VariableNames{i}, 'double');
    end

    T = readtable(tempFilePath, opts);

    timeRaw = string(T{:, 1});
    timeRaw = erase(timeRaw, '"');

    time = datetime(timeRaw, ...
        'InputFormat', 'yyyy-MM-dd HH:mm:ss');

    customerNames = string(T.Properties.VariableNames(2:end));
    customerNames = erase(customerNames, '"');

    P_kW = table2array(T(:, 2:end));
    P_kW(P_kW < 0) = NaN;

    selectedIdx = local_resolve_profile_index(profileNumber, customerNames);
    selectedCustomer = customerNames(selectedIdx);

    selectedPower_kW = P_kW(:, selectedIdx);

    dt_h = hours(median(diff(time), 'omitnan'));
    samplesPerDay = round(24 / dt_h);
    timeOfDay_h = (0:samplesPerDay-1).' * dt_h;

    [dayMatrix_kW, dayDates, dailyEnergy_kWh, dailyPeak_kW] = ...
        local_build_complete_day_matrix(time, selectedPower_kW, samplesPerDay, dt_h);

    if isempty(dayMatrix_kW)
        error('A kivalasztott profilhoz nem sikerult teljes napi matrixot epiteni.');
    end

    annualAverageProfile_kW = mean(dayMatrix_kW, 1, 'omitnan');

    monthNum = month(dayDates);
    monthlyAverageProfiles_kW = nan(12, samplesPerDay);

    for m = 1:12
        monthlyAverageProfiles_kW(m, :) = mean(dayMatrix_kW(monthNum == m, :), 1, 'omitnan');
    end

    meanPower_kW = mean(selectedPower_kW, 'omitnan');
    peakPower_kW = max(selectedPower_kW, [], 'omitnan');

    fig = figure('Color', 'w', ...
        'Name', sprintf('Profil reszletes elemzes - %s', selectedCustomer), ...
        'Position', [80, 80, 1550, 900]);

    tl = tiledlayout(2, 2, ...
        'TileSpacing', 'compact', ...
        'Padding', 'compact');

    title(tl, sprintf('%s reszletes fogyasztasi profil | atlag %.0f kW | peak %.0f kW', ...
        selectedCustomer, meanPower_kW, peakPower_kW), ...
        'Interpreter', 'none', ...
        'FontWeight', 'bold');

    nexttile;
    hold on;
    grid on;
    box on;

    plot(timeOfDay_h, annualAverageProfile_kW, ...
        'k', ...
        'LineWidth', 2.5, ...
        'DisplayName', 'Eves atlagos napi profil');

    xlabel('Napon beluli ido [h]');
    ylabel('Teljesitmeny [kW]');
    title('Eves atlagos napi profil');
    xlim([0 24]);
    xticks(0:2:24);
    legend('Location', 'best');
    hold off;

    nexttile;
    hold on;
    grid on;
    box on;

    monthNames = ["Jan", "Feb", "Mar", "Apr", "Maj", "Jun", ...
                  "Jul", "Aug", "Szept", "Okt", "Nov", "Dec"];

    for m = 1:12
        if any(isfinite(monthlyAverageProfiles_kW(m, :)))
            plot(timeOfDay_h, monthlyAverageProfiles_kW(m, :), ...
                'LineWidth', 1.2, ...
                'DisplayName', monthNames(m));
        end
    end

    xlabel('Napon beluli ido [h]');
    ylabel('Teljesitmeny [kW]');
    title('Havi atlagos napi profilok');
    xlim([0 24]);
    xticks(0:2:24);
    legend('Location', 'eastoutside');
    hold off;

    nexttile;
    hold on;
    grid on;
    box on;

    plot(timeOfDay_h, dayMatrix_kW.', ...
        'Color', [0.75 0.75 0.75], ...
        'LineWidth', 0.35, ...
        'HandleVisibility', 'off');

    plot(timeOfDay_h, annualAverageProfile_kW, ...
        'k', ...
        'LineWidth', 2.5, ...
        'DisplayName', 'Eves atlag');

    xlabel('Napon beluli ido [h]');
    ylabel('Teljesitmeny [kW]');
    title(sprintf('Egyedi napi profilok, n = %d nap', size(dayMatrix_kW, 1)));
    xlim([0 24]);
    xticks(0:2:24);
    legend('Location', 'best');
    hold off;

    nexttile;

    imagesc(timeOfDay_h, 1:size(dayMatrix_kW, 1), dayMatrix_kW);
    set(gca, 'YDir', 'normal');
    grid on;
    box on;

    xlabel('Napon beluli ido [h]');
    ylabel('Nap sorszama');
    title('Napi profilok heatmapje');
    xlim([0 24]);
    xticks(0:2:24);

    cb = colorbar;
    cb.Label.String = 'Teljesitmeny [kW]';

    plotResult = struct();

    plotResult.selectedCustomer = selectedCustomer;
    plotResult.selectedIdx = selectedIdx;
    plotResult.dayMatrix_kW = dayMatrix_kW;
    plotResult.dayDates = dayDates;
    plotResult.dailyEnergy_kWh = dailyEnergy_kWh;
    plotResult.dailyPeak_kW = dailyPeak_kW;
    plotResult.annualAverageProfile_kW = annualAverageProfile_kW;
    plotResult.monthlyAverageProfiles_kW = monthlyAverageProfiles_kW;
    plotResult.timeOfDay_h = timeOfDay_h;
    plotResult.figure = fig;
end


function tempFilePath = local_create_decimal_dot_copy(inputFilePath)

    [~, fileName, fileExt] = fileparts(char(inputFilePath));

    if isempty(fileExt)
        fileExt = '.txt';
    end

    tempFilePath = fullfile(tempdir, [fileName '_decimaldot_tmp' fileExt]);

    fin = fopen(inputFilePath, 'r');

    if fin < 0
        error('Nem sikerult megnyitni a bemeneti fajlt.');
    end

    fout = fopen(tempFilePath, 'w');

    if fout < 0
        fclose(fin);
        error('Nem sikerult letrehozni az ideiglenes fajlt.');
    end

    while true
        line = fgetl(fin);

        if ~ischar(line)
            break;
        end

        line = strrep(line, ',', '.');
        fprintf(fout, '%s\n', line);
    end

    fclose(fin);
    fclose(fout);
end


function local_delete_temp_file(tempFilePath)

    if isfile(tempFilePath)
        delete(tempFilePath);
    end
end


function selectedIdx = local_resolve_profile_index(profileNumber, customerNames)

    if isstring(profileNumber) || ischar(profileNumber)

        profileName = string(profileNumber);
        selectedIdx = find(customerNames == profileName, 1, 'first');

        if isempty(selectedIdx)
            error('Nem talalhato ilyen fogyaszto azonosito: %s', profileName);
        end

        return;
    end

    if isnumeric(profileNumber)

        profileNumber = round(profileNumber);

        mtName = string(sprintf('MT_%03d', profileNumber));
        selectedIdx = find(customerNames == mtName, 1, 'first');

        if ~isempty(selectedIdx)
            return;
        end

        if profileNumber >= 1 && profileNumber <= numel(customerNames)
            selectedIdx = profileNumber;
            return;
        end

        error('Nem talalhato MT_%03d, es indexkent sem ervenyes.', profileNumber);
    end

    error('A profileNumber tipusa nem tamogatott.');
end


function [dayMatrix_kW, dayDates, dailyEnergy_kWh, dailyPeak_kW] = ...
    local_build_complete_day_matrix(timeVec, pVec, samplesPerDay, dt_h)

    activeIdx = pVec > 0 & ~isnan(pVec);

    if nnz(activeIdx) < samplesPerDay
        dayMatrix_kW = [];
        dayDates = [];
        dailyEnergy_kWh = [];
        dailyPeak_kW = [];
        return;
    end

    firstIdx = find(activeIdx, 1, 'first');
    lastIdx = find(activeIdx, 1, 'last');

    timeUse = timeVec(firstIdx:lastIdx);
    pUse = pVec(firstIdx:lastIdx);

    datesOnly = dateshift(timeUse, 'start', 'day');
    uniqueDays = unique(datesOnly);

    dayMatrixTmp = nan(numel(uniqueDays), samplesPerDay);
    dayDatesTmp = NaT(numel(uniqueDays), 1);
    dailyEnergyTmp = nan(numel(uniqueDays), 1);
    dailyPeakTmp = nan(numel(uniqueDays), 1);

    nSaved = 0;

    for d = 1:numel(uniqueDays)

        currentDay = uniqueDays(d);
        idxDay = datesOnly == currentDay;

        pDay = pUse(idxDay);

        if numel(pDay) ~= samplesPerDay
            continue;
        end

        if any(isnan(pDay)) || sum(pDay, 'omitnan') <= 0
            continue;
        end

        nSaved = nSaved + 1;

        dayMatrixTmp(nSaved, :) = pDay(:).';
        dayDatesTmp(nSaved) = currentDay;
        dailyEnergyTmp(nSaved) = sum(pDay, 'omitnan') * dt_h;
        dailyPeakTmp(nSaved) = max(pDay, [], 'omitnan');
    end

    dayMatrix_kW = dayMatrixTmp(1:nSaved, :);
    dayDates = dayDatesTmp(1:nSaved);
    dailyEnergy_kWh = dailyEnergyTmp(1:nSaved);
    dailyPeak_kW = dailyPeakTmp(1:nSaved);
end