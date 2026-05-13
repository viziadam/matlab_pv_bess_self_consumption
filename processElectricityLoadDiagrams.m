function result = processElectricityLoadDiagrams(txtFileName)
% PROCESSELECTRICITYLOADDIAGRAMS
%
% Hasznalat:
%   result = processElectricityLoadDiagrams('LD2011_2014.txt');
%
% A fuggveny az ElectricityLoadDiagrams20112014 fogyasztasi adatfajlt
% dolgozza fel.
%
% Bemenet:
%   txtFileName - csak a txt fajl neve, nem teljes eleresi utvonal
%
% Automatikus eleresi ut:
%   aktualis_fuggveny_mappaja/consumption_csv/txtFileName
%
% Kimenet:
%   result - struktura a feldolgozott adatokkal es jellemzokkel
%
% Kivalasztasi logika:
%   1) Meghatarozza a residential / commercial / industry jellegu
%      fogyasztokat heurisztikusan.
%
%   2) Kiszamolja minden fogyasztora a PV-termelesi idoszak
%      atlagteljesitmenyet.
%
%   3) Kirajzolja azokat az ipari fogyasztokat, ahol:
%
%          PV-idoszaki atlagteljesitmeny <= 0.5 * csucsteljesitmeny
%
%   4) Ha nincs ilyen ipari fogyaszto, akkor kirajzolja az osszes
%      ervenyes fogyasztasi profilt.
%
% Fontos:
%   A dataset nem tartalmaz hivatalos residential / commercial / industry
%   cimkeket. A besorolas heurisztikus, fogyasztasi mintazat alapjan tortenik.

    %% 0. Alapbeallitasok

    maxProfilesPerFigure = 50;

    % PV-termelesi idoszak, ahol azt vizsgaljuk, hogy a fogyasztas
    % atlagosan legfeljebb a sajat csucsteljesitmeny fele-e.
    pvProductionStartHour = 10;
    pvProductionEndHour   = 14;

    pvMeanToPeakLimit = 0.50;

    if nargin < 1 || strlength(string(txtFileName)) == 0
        error('Meg kell adni a bemeneti txt fajl nevet. Pelda: processElectricityLoadDiagrams(''LD2011_2014.txt'')');
    end

    txtFileName = char(txtFileName);

    if contains(txtFileName, filesep) || contains(txtFileName, '/')
        error('Csak a fajlnevet add meg, ne teljes eleresi utvonalat. Pelda: LD2011_2014.txt');
    end

    functionFullPath = mfilename('fullpath');
    functionFolderPath = fileparts(functionFullPath);

    inputFolderPath = fullfile(functionFolderPath, 'consumption_csv');
    txtFilePath = fullfile(inputFolderPath, txtFileName);

    if ~isfolder(inputFolderPath)
        error('A consumption_csv mappa nem talalhato: %s', inputFolderPath);
    end

    if ~isfile(txtFilePath)
        error('A megadott fajl nem talalhato: %s', txtFilePath);
    end

    fprintf('Fajl feldolgozasa indul...\n');
    fprintf('Fuggveny mappa: %s\n', functionFolderPath);
    fprintf('Bemeneti fajl: %s\n', txtFilePath);
    fprintf('PV-termelesi idoszak: %.1f - %.1f h\n', ...
        pvProductionStartHour, pvProductionEndHour);
    fprintf('Kivalasztasi feltetel: PV-idoszaki atlag <= %.2f * peak\n\n', ...
        pvMeanToPeakLimit);

    %% 1. Decimalis vesszo kezelese ideiglenes fajllal

    tempFilePath = createDecimalDotCopy(txtFilePath);
    cleanupObj = onCleanup(@() deleteTempFile(tempFilePath)); %#ok<NASGU>

    %% 2. Adatok beolvasasa table formaban

    fprintf('Adatok beolvasasa...\n');

    opts = detectImportOptions(tempFilePath, ...
        'FileType', 'text', ...
        'Delimiter', ';');

    opts.VariableNamingRule = 'preserve';

    % Elso oszlop idobelyegkent szoveg.
    opts = setvartype(opts, opts.VariableNames{1}, 'char');

    % A tobbi oszlop numerikus.
    for i = 2:numel(opts.VariableNames)
        opts = setvartype(opts, opts.VariableNames{i}, 'double');
    end

    T = readtable(tempFilePath, opts);

    %% 3. Idovektor es fogyasztasi matrix kinyerese

    timeRaw = string(T{:, 1});
    timeRaw = erase(timeRaw, '"');

    time = datetime(timeRaw, ...
        'InputFormat', 'yyyy-MM-dd HH:mm:ss');

    customerNames = string(T.Properties.VariableNames(2:end));
    customerNames = erase(customerNames, '"');

    P = table2array(T(:, 2:end));
    P(P < 0) = NaN;

    nSamples = size(P, 1);
    nCustomers = size(P, 2);

    fprintf('Mintak szama: %d\n', nSamples);
    fprintf('Fogyasztok szama: %d\n', nCustomers);

    %% 4. Mintaveteli ido meghatarozasa

    timeDiff_h = hours(diff(time));
    dt_h = median(timeDiff_h, 'omitnan');

    fprintf('Becsult mintaveteli ido: %.4f ora\n', dt_h);

    if abs(dt_h - 0.25) > 1e-6
        warning('A mintaveteli ido nem pontosan 15 perc.');
    end

    samplesPerDay = round(24 / dt_h);

    if samplesPerDay <= 0
        error('Hibas mintaveteli ido.');
    end

    fprintf('Mintak szama egy napban: %d\n', samplesPerDay);

    %% 5. Fogyasztoi jellemzok szamitasa aktiv idoszak alapjan

    totalEnergy_kWh = nan(1, nCustomers);
    avgDailyEnergy_kWh = nan(1, nCustomers);
    meanPower_kW = nan(1, nCustomers);
    peakPower_kW = nan(1, nCustomers);
    loadFactor = nan(1, nCustomers);
    nightRatio = nan(1, nCustomers);
    daytimeRatio = nan(1, nCustomers);
    weekendToWeekdayRatio = nan(1, nCustomers);
    activeDays = nan(1, nCustomers);

    dailyProfiles = nan(samplesPerDay, nCustomers);

    validCustomer = false(1, nCustomers);

    fprintf('Fogyasztoi jellemzok szamitasa...\n');

    for c = 1:nCustomers

        pc = P(:, c);

        % Aktiv mintak: pozitiv, nem NaN ertekek.
        activeIdx = pc > 0 & ~isnan(pc);

        % Ha kevesebb mint 1 napnyi aktiv adat van, kihagyjuk.
        if nnz(activeIdx) < samplesPerDay
            continue;
        end

        firstIdx = find(activeIdx, 1, 'first');
        lastIdx = find(activeIdx, 1, 'last');

        idxWindow = firstIdx:lastIdx;

        pcWin = pc(idxWindow);
        timeWin = time(idxWindow);

        if all(isnan(pcWin)) || max(pcWin, [], 'omitnan') <= 0
            continue;
        end

        validCustomer(c) = true;

        % Aktiv idoszak hossza napban.
        activeDays(c) = max(days(timeWin(end) - timeWin(1)) + dt_h / 24, dt_h / 24);

        totalEnergy_kWh(c) = sum(pcWin, 'omitnan') * dt_h;
        avgDailyEnergy_kWh(c) = totalEnergy_kWh(c) / activeDays(c);

        meanPower_kW(c) = mean(pcWin, 'omitnan');
        peakPower_kW(c) = max(pcWin, [], 'omitnan');

        if peakPower_kW(c) > 0
            loadFactor(c) = meanPower_kW(c) / peakPower_kW(c);
        end

        hourOfDay = hour(timeWin) + minute(timeWin) / 60;
        dayOfWeek = weekday(timeWin);

        isNight = hourOfDay < 6 | hourOfDay >= 22;
        isDaytime = hourOfDay >= 8 & hourOfDay < 18;

        isWeekend = dayOfWeek == 1 | dayOfWeek == 7;
        isWeekday = ~isWeekend;

        nightEnergy = sum(pcWin(isNight), 'omitnan') * dt_h;
        daytimeEnergy = sum(pcWin(isDaytime), 'omitnan') * dt_h;

        if totalEnergy_kWh(c) > 0
            nightRatio(c) = nightEnergy / totalEnergy_kWh(c);
            daytimeRatio(c) = daytimeEnergy / totalEnergy_kWh(c);
        end

        if any(isWeekend) && any(isWeekday)

            weekendEnergy = sum(pcWin(isWeekend), 'omitnan') * dt_h;
            weekdayEnergy = sum(pcWin(isWeekday), 'omitnan') * dt_h;

            weekendHours = sum(isWeekend) * dt_h;
            weekdayHours = sum(isWeekday) * dt_h;

            avgWeekendPower = weekendEnergy / max(weekendHours, eps);
            avgWeekdayPower = weekdayEnergy / max(weekdayHours, eps);

            if avgWeekdayPower > 0
                weekendToWeekdayRatio(c) = avgWeekendPower / avgWeekdayPower;
            end
        end

        dailyProfiles(:, c) = calculateAverageDailyProfile(timeWin, pcWin, samplesPerDay);
    end

    %% 6. Ervenyes fogyasztok megtartasa

    P = P(:, validCustomer);
    customerNames = customerNames(validCustomer);

    totalEnergy_kWh = totalEnergy_kWh(validCustomer);
    avgDailyEnergy_kWh = avgDailyEnergy_kWh(validCustomer);
    meanPower_kW = meanPower_kW(validCustomer);
    peakPower_kW = peakPower_kW(validCustomer);
    loadFactor = loadFactor(validCustomer);
    nightRatio = nightRatio(validCustomer);
    daytimeRatio = daytimeRatio(validCustomer);
    weekendToWeekdayRatio = weekendToWeekdayRatio(validCustomer);
    activeDays = activeDays(validCustomer);
    dailyProfiles = dailyProfiles(:, validCustomer);

    nValidCustomers = numel(customerNames);

    fprintf('Ervenyes fogyasztok szama: %d\n', nValidCustomers);

    if nValidCustomers == 0
        error('Nincs egyetlen ervenyes fogyaszto sem.');
    end

    %% 7. Heurisztikus kategorizalas

    category = strings(1, nValidCustomers);

    qLowEnergy = localPercentile(avgDailyEnergy_kWh, 33);
    qHighEnergy = localPercentile(avgDailyEnergy_kWh, 75);
    qHighPeak = localPercentile(peakPower_kW, 75);

    for c = 1:nValidCustomers

        Eday = avgDailyEnergy_kWh(c);
        Ppeak = peakPower_kW(c);
        LF = loadFactor(c);
        NR = nightRatio(c);
        DR = daytimeRatio(c);
        WR = weekendToWeekdayRatio(c);

        if isnan(WR)
            WR = 0;
        end

        % INDUSTRY jelleg:
        % - nagy fogyasztas vagy nagy csucsteljesitmeny
        % - magas load factor vagy jelentosebb ejszakai fogyasztas
        % - hetvegen sem esik vissza nagyon
        if (Eday >= qHighEnergy || Ppeak >= qHighPeak) && ...
           (LF > 0.35 || NR > 0.25 || WR > 0.65)

            category(c) = "industry";

        % COMMERCIAL jelleg:
        % - kozepes vagy nagyobb fogyasztas
        % - nappali dominancia
        % - jellemzoen munkanapi / nappali mukodes
        elseif Eday > qLowEnergy && DR > 0.35

            category(c) = "commercial";

        % RESIDENTIAL jelleg:
        % - kisebb fogyasztas
        % - kisebb atlagos teljesitmeny
        % - nagyobb relativ napi ingadozas
        else
            category(c) = "residential";
        end
    end

    %% 8. PV-termelesi idoszaki metrikak

    timeOfDay = duration(0, 0, 0) + minutes((0:samplesPerDay-1) * dt_h * 60);
    hourAxis = hours(timeOfDay);

    pvWindowMask = ...
        hourAxis >= pvProductionStartHour & ...
        hourAxis < pvProductionEndHour;

    if ~any(pvWindowMask)
        error('A PV-termelesi idoszakhoz nem tartozik egyetlen idopont sem.');
    end

    pvWindowMeanPower_kW = nan(1, nValidCustomers);
    pvWindowPeakPower_kW = nan(1, nValidCustomers);
    pvWindowMeanToPeakRatio = nan(1, nValidCustomers);

    for c = 1:nValidCustomers

        prof = dailyProfiles(:, c);

        pvWindowMeanPower_kW(c) = mean(prof(pvWindowMask), 'omitnan');
        pvWindowPeakPower_kW(c) = max(prof(pvWindowMask), [], 'omitnan');

        if peakPower_kW(c) > 0
            pvWindowMeanToPeakRatio(c) = pvWindowMeanPower_kW(c) / peakPower_kW(c);
        end
    end

    %% 9. Osszefoglalo tabla

    summaryTable = table( ...
        customerNames(:), ...
        category(:), ...
        activeDays(:), ...
        totalEnergy_kWh(:), ...
        avgDailyEnergy_kWh(:), ...
        meanPower_kW(:), ...
        peakPower_kW(:), ...
        loadFactor(:), ...
        nightRatio(:), ...
        daytimeRatio(:), ...
        weekendToWeekdayRatio(:), ...
        pvWindowMeanPower_kW(:), ...
        pvWindowPeakPower_kW(:), ...
        pvWindowMeanToPeakRatio(:), ...
        'VariableNames', { ...
            'Customer', ...
            'Category', ...
            'ActiveDays', ...
            'TotalEnergy_kWh', ...
            'AvgDailyEnergy_kWh', ...
            'MeanPower_kW', ...
            'PeakPower_kW', ...
            'LoadFactor', ...
            'NightEnergyRatio', ...
            'DaytimeEnergyRatio', ...
            'WeekendToWeekdayRatio', ...
            'PvWindowMeanPower_kW', ...
            'PvWindowPeakPower_kW', ...
            'PvWindowMeanToPeakRatio'});

    fprintf('\nKategoriak osszesitese:\n');
    disp(groupsummary(summaryTable, 'Category'));

    %% 10. Kivalasztas: industry + PV-idoszaki atlag <= peak fele

    selectedMask = ...
        category(:) == "industry" & ...
        pvWindowMeanToPeakRatio(:) <= pvMeanToPeakLimit;

    selectedIdx = find(selectedMask);

    fallbackUsed = false;

    fprintf('\nIpari fogyasztok, ahol PV-idoszaki atlag <= %.0f %% * peak: %d db\n', ...
        pvMeanToPeakLimit * 100, numel(selectedIdx));

    if isempty(selectedIdx)

        warning(['Nincs olyan ipari fogyaszto, ahol a PV-termelesi idoszakban ', ...
                 'az atlagos teljesitmeny legfeljebb a csucsteljesitmeny fele. ', ...
                 'Ezert az osszes ervenyes fogyasztasi profilt rajzolom ki.']);

        selectedIdx = 1:nValidCustomers;
        fallbackUsed = true;
    end

    selectedTable = summaryTable(selectedIdx, :);

    if fallbackUsed
        selectedTable = sortrows(selectedTable, 'PeakPower_kW', 'descend');
    else
        selectedTable = sortrows(selectedTable, 'PvWindowMeanToPeakRatio', 'ascend');
    end

    fprintf('\nKirajzolasra kivalasztott profilok:\n');
    disp(selectedTable);

    %% 11. Profilok kirajzolasa

    if fallbackUsed
        plotSelectedProfiles( ...
            dailyProfiles, ...
            timeOfDay, ...
            customerNames, ...
            selectedIdx, ...
            summaryTable, ...
            maxProfilesPerFigure, ...
            pvProductionStartHour, ...
            pvProductionEndHour, ...
            'Osszes ervenyes fogyasztasi profil', ...
            false);
    else
        plotSelectedProfiles( ...
            dailyProfiles, ...
            timeOfDay, ...
            customerNames, ...
            selectedIdx, ...
            summaryTable, ...
            maxProfilesPerFigure, ...
            pvProductionStartHour, ...
            pvProductionEndHour, ...
            'Ipari profilok alacsony PV-idoszaki fogyasztassal', ...
            true);
    end

    plotSelectedMeanProfile( ...
        dailyProfiles, ...
        timeOfDay, ...
        selectedIdx, ...
        pvProductionStartHour, ...
        pvProductionEndHour, ...
        fallbackUsed);

    %% 12. Kimenet

    result = struct();

    result.sourceFile = txtFilePath;
    result.inputFolderPath = inputFolderPath;
    result.functionFolderPath = functionFolderPath;

    result.time = time;
    result.power_kW = P;
    result.customerNames = customerNames;
    result.category = category;

    result.summaryTable = summaryTable;

    result.selectedIdx = selectedIdx;
    result.selectedTable = selectedTable;
    result.selectedProfiles = dailyProfiles(:, selectedIdx);
    result.selectedCustomerNames = customerNames(selectedIdx);
    result.fallbackUsed = fallbackUsed;

    result.dailyProfiles = dailyProfiles;
    result.timeOfDay = timeOfDay;
    result.dt_h = dt_h;

    result.settings = struct();
    result.settings.maxProfilesPerFigure = maxProfilesPerFigure;
    result.settings.pvProductionStartHour = pvProductionStartHour;
    result.settings.pvProductionEndHour = pvProductionEndHour;
    result.settings.pvMeanToPeakLimit = pvMeanToPeakLimit;

    fprintf('Feldolgozas kesz.\n');
end


% =========================================================================
% SEGEDFUGGVENYEK
% =========================================================================

function tempFilePath = createDecimalDotCopy(inputFilePath)
% CREATEDECIMALDOTCOPY
% Letrehoz egy ideiglenes fajlt, amelyben a decimalis vesszok pontta
% vannak alakitva.

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


function deleteTempFile(tempFilePath)
% DELETETEMPFILE
% Ideiglenes fajl torlese.

    if isfile(tempFilePath)
        delete(tempFilePath);
    end
end


function avgProfile = calculateAverageDailyProfile(time, p, samplesPerDay)
% CALCULATEAVERAGEDAILYPROFILE
% Atlagos napi teljesitmenyprofil szamitasa egy fogyasztora.

    datesOnly = dateshift(time, 'start', 'day');
    uniqueDays = unique(datesOnly);

    profiles = nan(samplesPerDay, numel(uniqueDays));

    for d = 1:numel(uniqueDays)

        idxDay = datesOnly == uniqueDays(d);
        pDay = p(idxDay);

        % Csak teljes napokat hasznalunk.
        if numel(pDay) ~= samplesPerDay
            continue;
        end

        % Teljesen nulla napokat kihagyunk, mert gyakran inaktiv meresi
        % idoszakot jelentenek.
        if sum(pDay, 'omitnan') <= 0
            continue;
        end

        profiles(:, d) = pDay(:);
    end

    avgProfile = mean(profiles, 2, 'omitnan');
end


function plotSelectedProfiles(dailyProfiles, timeOfDay, customerNames, selectedIdx, summaryTable, ...
    maxProfilesPerFigure, pvStartHour, pvEndHour, plotTitleBase, isIndustrySelection)
% PLOTSELECTEDPROFILES
%
% Kirajzolja a kivalasztott atlagos napi profilokat.
% Ha sok profil van, tobb figurara bontja.

    if isempty(selectedIdx)
        fprintf('Nincs kirajzolhato profil.\n');
        return;
    end

    selectedSummary = summaryTable(selectedIdx, :);

    if isIndustrySelection
        [~, sortIdx] = sort(selectedSummary.PvWindowMeanToPeakRatio, 'ascend');
    else
        [~, sortIdx] = sort(selectedSummary.PeakPower_kW, 'descend');
    end

    selectedIdx = selectedIdx(sortIdx);

    nSelected = numel(selectedIdx);
    nFigures = ceil(nSelected / maxProfilesPerFigure);

    fprintf('Kirajzolando profilok szama: %d, figurak szama: %d\n', ...
        nSelected, nFigures);

    for figIdx = 1:nFigures

        startIdx = (figIdx - 1) * maxProfilesPerFigure + 1;
        endIdx = min(figIdx * maxProfilesPerFigure, nSelected);

        idxThisFigure = selectedIdx(startIdx:endIdx);

        selectedProfiles = dailyProfiles(:, idxThisFigure);
        selectedNames = customerNames(idxThisFigure);

        fig = figure('Color', 'w', ...
            'Name', sprintf('%s - %d of %d', plotTitleBase, figIdx, nFigures));

        hold on;
        grid on;

        % PV-termelesi idoszak hatterkiemelese.
        yLimitsInitial = [0, max(selectedProfiles, [], 'all', 'omitnan') * 1.10];

        if ~all(isfinite(yLimitsInitial)) || yLimitsInitial(2) <= 0
            yLimitsInitial = [0, 1];
        end

        pvStartDuration = duration(floor(pvStartHour), ...
            round((pvStartHour - floor(pvStartHour)) * 60), 0);

        pvEndDuration = duration(floor(pvEndHour), ...
            round((pvEndHour - floor(pvEndHour)) * 60), 0);

        patch([pvStartDuration pvEndDuration pvEndDuration pvStartDuration], ...
              [yLimitsInitial(1) yLimitsInitial(1) yLimitsInitial(2) yLimitsInitial(2)], ...
              [0.90 0.90 0.90], ...
              'EdgeColor', 'none', ...
              'FaceAlpha', 0.35, ...
              'DisplayName', 'PV-termelesi idoszak');

        % Egyedi napi profilok.
        plot(timeOfDay, selectedProfiles, 'LineWidth', 0.8);

        % Az adott abran szereplo profilok atlaga.
        meanProfile = mean(selectedProfiles, 2, 'omitnan');
        plot(timeOfDay, meanProfile, 'k', 'LineWidth', 3, ...
            'DisplayName', 'Atlag');

        xlabel('Napon beluli ido');
        ylabel('Atlagos teljesitmeny [kW]');

        title(sprintf('%s - %d/%d. abra', ...
            plotTitleBase, figIdx, nFigures), ...
            'Interpreter', 'none');

        if numel(idxThisFigure) <= 10
            legend(["PV-termelesi idoszak"; selectedNames(:); "Atlag"], ...
                'Location', 'best');
        else
            legend('PV-termelesi idoszak', 'Egyedi napi profilok', 'Atlag', ...
                'Location', 'best');
        end

        ylim(yLimitsInitial);
        hold off;
    end
end


function plotSelectedMeanProfile(dailyProfiles, timeOfDay, selectedIdx, pvStartHour, pvEndHour, fallbackUsed)
% PLOTSELECTEDMEANPROFILE
%
% Egy kulon abran kirajzolja a kivalasztott profilok atlagat,
% minimumat es maximumat.

    if isempty(selectedIdx)
        return;
    end

    selectedProfiles = dailyProfiles(:, selectedIdx);

    meanProfile = mean(selectedProfiles, 2, 'omitnan');
    minProfile = min(selectedProfiles, [], 2, 'omitnan');
    maxProfile = max(selectedProfiles, [], 2, 'omitnan');

    fig = figure('Color', 'w', ...
        'Name', 'Selected mean profile');

    hold on;
    grid on;

    yLimitsInitial = [0, max(maxProfile, [], 'omitnan') * 1.10];

    if ~all(isfinite(yLimitsInitial)) || yLimitsInitial(2) <= 0
        yLimitsInitial = [0, 1];
    end

    pvStartDuration = duration(floor(pvStartHour), ...
        round((pvStartHour - floor(pvStartHour)) * 60), 0);

    pvEndDuration = duration(floor(pvEndHour), ...
        round((pvEndHour - floor(pvEndHour)) * 60), 0);

    patch([pvStartDuration pvEndDuration pvEndDuration pvStartDuration], ...
          [yLimitsInitial(1) yLimitsInitial(1) yLimitsInitial(2) yLimitsInitial(2)], ...
          [0.90 0.90 0.90], ...
          'EdgeColor', 'none', ...
          'FaceAlpha', 0.35, ...
          'DisplayName', 'PV-termelesi idoszak');

    plot(timeOfDay, minProfile, '--', 'LineWidth', 1.2, ...
        'DisplayName', 'Minimum profil');

    plot(timeOfDay, maxProfile, '--', 'LineWidth', 1.2, ...
        'DisplayName', 'Maximum profil');

    plot(timeOfDay, meanProfile, 'k', 'LineWidth', 3, ...
        'DisplayName', 'Atlagos profil');

    xlabel('Napon beluli ido');
    ylabel('Atlagos teljesitmeny [kW]');

    if fallbackUsed
        title(sprintf('Osszes ervenyes fogyasztasi profil atlaga, n = %d', ...
            numel(selectedIdx)));
    else
        title(sprintf('Kivalasztott ipari profilok atlaga, n = %d', ...
            numel(selectedIdx)));
    end

    legend('Location', 'best');
    ylim(yLimitsInitial);

    hold off;
end


function q = localPercentile(x, p)
% LOCALPERCENTILE
% Toolbox fuggetlen percentilis szamitas.
%
% x : vektor
% p : percentilis 0...100 kozott

    x = x(:);
    x = x(~isnan(x));

    if isempty(x)
        q = NaN;
        return;
    end

    x = sort(x);

    if numel(x) == 1
        q = x;
        return;
    end

    pos = 1 + (p / 100) * (numel(x) - 1);
    lo = floor(pos);
    hi = ceil(pos);

    if lo == hi
        q = x(lo);
    else
        w = pos - lo;
        q = (1 - w) * x(lo) + w * x(hi);
    end
end