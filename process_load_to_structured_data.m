function result = process_load_to_structured_data(txtFilePath, savePath)
% PROCESS_ELECTRICITYLOADDIAGRAMS_INDUSTRY_FOR_BESS
% use: process_load_to_structured_data('C:\Users\Vizi\Desktop\Egyetem\MSC VIK\Villamosmérnök\Diplomamunka\Napelemes rendszerek\Szimulaciok\Rendszerelemzes\industrial_use_case-self-consumption\consumption_csv\LD2011_2014.txt', 'C:\Users\Vizi\Desktop\Egyetem\MSC VIK\Villamosmérnök\Diplomamunka\Napelemes rendszerek\Szimulaciok\Rendszerelemzes\industrial_use_case-self-consumption\consumption')
% ElectricityLoadDiagrams20112014 dataset feldolgozasa PV+BESS
% onfogyasztas-novelesi vizsgalathoz.
%
% Bemenet:
%   txtFilePath : ElectricityLoadDiagrams txt fajl teljes eleresi utvonala
%   savePath    : mappa, ahova a napi .mat fajlok kerulnek
%
% A fuggveny:
%   1) Beolvassa a 15 perces fogyasztasi adatokat.
%   2) Kiszuri az ervenyes fogyasztokat.
%   3) Heurisztikusan besorolja oket:
%        residential / commercial / industry
%   4) Az industry jellegu fogyasztok kozul kivalaszt egyet,
%      amelynek uzemi napi profilcsucsa kb. 800 kW.
%   5) A kivalasztott fogyasztot napi .mat fajlokra bontja.
%
% Megjegyzes:
%   A dataset nem tartalmaz hivatalos fogyasztotipus-cimkeket.
%   Az industry/commercial/residential besorolas heurisztikus.

    % ---------------------------------------------------------------------
    % 0) Beallitasok
    % ---------------------------------------------------------------------
    targetProductionPeak_kW = 800;     % celzott uzemi csucs kb. 800 kW
    minActiveDays = 300;               % legalabb kb. egy ev aktiv adat
    outputResolutionMin = 30;          % Ausgridhez hasonlo 30 perces kimenet

    productionStartHour = 8;           % uzemi idoszak kezdete
    productionEndHour   = 22;          % uzemi idoszak vege

    offHourMorningEnd = 6;             % uzemen kivuli reggeli veg
    offHourEveningStart = 22;          % uzemen kivuli esti kezd

    assert(isfile(txtFilePath), ...
        'Hiba: A megadott txt fajl nem talalhato: %s', txtFilePath);

    if ~isfolder(savePath)
        mkdir(savePath);
    end

    fprintf('ElectricityLoadDiagrams feldolgozas indul...\n');
    fprintf('Bemeneti fajl: %s\n', txtFilePath);
    fprintf('Mentesi mappa: %s\n\n', savePath);

    % ---------------------------------------------------------------------
    % 1) Decimalis vesszo kezelese
    % ---------------------------------------------------------------------
    tempFilePath = local_create_decimal_dot_copy(txtFilePath);
    cleanupObj = onCleanup(@() local_delete_temp_file(tempFilePath));

    % ---------------------------------------------------------------------
    % 2) Beolvasas
    % ---------------------------------------------------------------------
    fprintf('Fajl beolvasasa...\n');

    opts = detectImportOptions(tempFilePath, ...
        'FileType', 'text', ...
        'Delimiter', ';');

    opts.VariableNamingRule = 'preserve';

    % Elso oszlop: idobelyeg
    opts = setvartype(opts, opts.VariableNames{1}, 'char');

    % Tobbi oszlop: numerikus fogyasztasi adat
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

    nSamples = size(P_kW, 1);
    nCustomers = size(P_kW, 2);

    fprintf('Mintak szama: %d\n', nSamples);
    fprintf('Fogyasztok szama: %d\n', nCustomers);

    % ---------------------------------------------------------------------
    % 3) Mintaveteli ido
    % ---------------------------------------------------------------------
    dtOriginal_h = hours(median(diff(time)));

    fprintf('Eredeti mintaveteli ido: %.4f h\n', dtOriginal_h);

    if abs(dtOriginal_h - 0.25) > 1e-6
        warning('A vart 15 perces mintavetelezes helyett %.4f h adodott.', dtOriginal_h);
    end

    samplesPerDayOriginal = round(24 / dtOriginal_h);

    % ---------------------------------------------------------------------
    % 4) Fogyasztoi jellemzok es napi atlagprofilok
    % ---------------------------------------------------------------------
    fprintf('Fogyasztoi jellemzok szamitasa...\n');

    validCustomer = false(1, nCustomers);

    activeDays = nan(1, nCustomers);
    totalEnergy_kWh = nan(1, nCustomers);
    avgDailyEnergy_kWh = nan(1, nCustomers);
    meanPower_kW = nan(1, nCustomers);
    peakPower_kW = nan(1, nCustomers);
    loadFactor = nan(1, nCustomers);
    nightRatio = nan(1, nCustomers);
    daytimeRatio = nan(1, nCustomers);
    weekendToWeekdayRatio = nan(1, nCustomers);

    dailyProfiles_kW = nan(samplesPerDayOriginal, nCustomers);

    for c = 1:nCustomers

        p = P_kW(:, c);

        activeIdx = p > 0 & ~isnan(p);

        if nnz(activeIdx) < samplesPerDayOriginal
            continue;
        end

        firstIdx = find(activeIdx, 1, 'first');
        lastIdx  = find(activeIdx, 1, 'last');

        idxWindow = firstIdx:lastIdx;

        pWin = p(idxWindow);
        tWin = time(idxWindow);

        if all(isnan(pWin)) || max(pWin, [], 'omitnan') <= 0
            continue;
        end

        validCustomer(c) = true;

        activeDays(c) = max(days(tWin(end) - tWin(1)) + dtOriginal_h / 24, dtOriginal_h / 24);

        totalEnergy_kWh(c) = sum(pWin, 'omitnan') * dtOriginal_h;
        avgDailyEnergy_kWh(c) = totalEnergy_kWh(c) / activeDays(c);

        meanPower_kW(c) = mean(pWin, 'omitnan');
        peakPower_kW(c) = max(pWin, [], 'omitnan');

        if peakPower_kW(c) > 0
            loadFactor(c) = meanPower_kW(c) / peakPower_kW(c);
        end

        hourOfDay = hour(tWin) + minute(tWin) / 60;
        dayOfWeek = weekday(tWin);

        isNight = hourOfDay < 6 | hourOfDay >= 22;
        isDaytime = hourOfDay >= 8 & hourOfDay < 18;

        isWeekend = dayOfWeek == 1 | dayOfWeek == 7;
        isWeekday = ~isWeekend;

        nightEnergy_kWh = sum(pWin(isNight), 'omitnan') * dtOriginal_h;
        daytimeEnergy_kWh = sum(pWin(isDaytime), 'omitnan') * dtOriginal_h;

        if totalEnergy_kWh(c) > 0
            nightRatio(c) = nightEnergy_kWh / totalEnergy_kWh(c);
            daytimeRatio(c) = daytimeEnergy_kWh / totalEnergy_kWh(c);
        end

        if any(isWeekend) && any(isWeekday)
            weekendEnergy_kWh = sum(pWin(isWeekend), 'omitnan') * dtOriginal_h;
            weekdayEnergy_kWh = sum(pWin(isWeekday), 'omitnan') * dtOriginal_h;

            weekendHours = sum(isWeekend) * dtOriginal_h;
            weekdayHours = sum(isWeekday) * dtOriginal_h;

            avgWeekendPower = weekendEnergy_kWh / weekendHours;
            avgWeekdayPower = weekdayEnergy_kWh / weekdayHours;

            if avgWeekdayPower > 0
                weekendToWeekdayRatio(c) = avgWeekendPower / avgWeekdayPower;
            end
        end

        dailyProfiles_kW(:, c) = local_average_daily_profile( ...
            tWin, pWin, samplesPerDayOriginal);

    end

    % ---------------------------------------------------------------------
    % 5) Ervenyes fogyasztok megtartasa
    % ---------------------------------------------------------------------
    P_kW = P_kW(:, validCustomer);
    customerNames = customerNames(validCustomer);

    activeDays = activeDays(validCustomer);
    totalEnergy_kWh = totalEnergy_kWh(validCustomer);
    avgDailyEnergy_kWh = avgDailyEnergy_kWh(validCustomer);
    meanPower_kW = meanPower_kW(validCustomer);
    peakPower_kW = peakPower_kW(validCustomer);
    loadFactor = loadFactor(validCustomer);
    nightRatio = nightRatio(validCustomer);
    daytimeRatio = daytimeRatio(validCustomer);
    weekendToWeekdayRatio = weekendToWeekdayRatio(validCustomer);
    dailyProfiles_kW = dailyProfiles_kW(:, validCustomer);

    nValidCustomers = numel(customerNames);

    fprintf('Ervenyes fogyasztok szama: %d\n', nValidCustomers);

    % ---------------------------------------------------------------------
    % 6) Heurisztikus residential / commercial / industry besorolas
    % ---------------------------------------------------------------------
    category = strings(1, nValidCustomers);

    qLowEnergy  = local_percentile(avgDailyEnergy_kWh, 33);
    qHighEnergy = local_percentile(avgDailyEnergy_kWh, 75);
    qHighPeak   = local_percentile(peakPower_kW, 75);

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

        if (Eday >= qHighEnergy || Ppeak >= qHighPeak) && ...
           (LF > 0.35 || NR > 0.25 || WR > 0.65)

            category(c) = "industry";

        elseif Eday > qLowEnergy && DR > 0.35

            category(c) = "commercial";

        else

            category(c) = "residential";
        end
    end

    % ---------------------------------------------------------------------
    % 7) Kivalasztas: industry profil kb. 800 kW uzemi csuccsal
    % ---------------------------------------------------------------------
    fprintf('\nIndustry jellegu profil kivalasztasa...\n');

    timeOfDayOriginal = duration(0, 0, 0) + minutes((0:samplesPerDayOriginal-1) * dtOriginal_h * 60);
    hourAxis = hours(timeOfDayOriginal);

    isProductionTime = hourAxis >= productionStartHour & hourAxis < productionEndHour;
    isOffTime = hourAxis < offHourMorningEnd | hourAxis >= offHourEveningStart;

    productionPeakDaily_kW = nan(1, nValidCustomers);
    productionMeanDaily_kW = nan(1, nValidCustomers);
    offMeanDaily_kW = nan(1, nValidCustomers);
    offToProductionRatio = nan(1, nValidCustomers);
    selectionScore = nan(1, nValidCustomers);

    for c = 1:nValidCustomers

        prof = dailyProfiles_kW(:, c);

        productionPeakDaily_kW(c) = max(prof(isProductionTime), [], 'omitnan');
        productionMeanDaily_kW(c) = mean(prof(isProductionTime), 'omitnan');
        offMeanDaily_kW(c) = mean(prof(isOffTime), 'omitnan');

        if productionPeakDaily_kW(c) > 0
            offToProductionRatio(c) = offMeanDaily_kW(c) / productionPeakDaily_kW(c);
        end

        peakError = abs(productionPeakDaily_kW(c) - targetProductionPeak_kW) / targetProductionPeak_kW;

        % A kisebb score jobb.
        % Fontos:
        %   - legyen kozel 800 kW az uzemi csucs
        %   - legyen alacsonyabb az uzemen kivuli fogyasztas
        %   - legyen eleg hosszu aktiv idosor
        activePenalty = 0;
        if activeDays(c) < minActiveDays
            activePenalty = 10;
        end

        categoryPenalty = 0;
        if category(c) ~= "industry"
            categoryPenalty = 5;
        end

        selectionScore(c) = ...
            peakError + ...
            0.75 * offToProductionRatio(c) + ...
            activePenalty + ...
            categoryPenalty;
    end

    candidateTable = table( ...
        customerNames(:), ...
        category(:), ...
        activeDays(:), ...
        avgDailyEnergy_kWh(:), ...
        peakPower_kW(:), ...
        productionPeakDaily_kW(:), ...
        productionMeanDaily_kW(:), ...
        offMeanDaily_kW(:), ...
        offToProductionRatio(:), ...
        selectionScore(:), ...
        'VariableNames', { ...
            'Customer', ...
            'Category', ...
            'ActiveDays', ...
            'AvgDailyEnergy_kWh', ...
            'GlobalPeakPower_kW', ...
            'ProductionPeakDaily_kW', ...
            'ProductionMeanDaily_kW', ...
            'OffMeanDaily_kW', ...
            'OffToProductionRatio', ...
            'SelectionScore'});

    % Eloszor csak industry + eleg hosszu + 500...1100 kW kozotti profilok.
    candidateMask = ...
        candidateTable.Category == "industry" & ...
        candidateTable.ActiveDays >= minActiveDays & ...
        candidateTable.ProductionPeakDaily_kW >= 500 & ...
        candidateTable.ProductionPeakDaily_kW <= 1100;

    % Ha tul szigoruek voltunk, lazitunk.
    if ~any(candidateMask)
        candidateMask = ...
            candidateTable.Category == "industry" & ...
            candidateTable.ActiveDays >= minActiveDays;
    end

    % Ha meg igy sincs, akkor minden industry.
    if ~any(candidateMask)
        candidateMask = candidateTable.Category == "industry";
    end

    % Ha valamiert nincs industry, akkor minden ervenyes fogyasztobol valasztunk.
    if ~any(candidateMask)
        candidateMask = true(height(candidateTable), 1);
    end

    candidates = candidateTable(candidateMask, :);
    candidates = sortrows(candidates, 'SelectionScore', 'ascend');

    selectedCustomer = candidates.Customer(1);
    selectedIdx = find(customerNames == selectedCustomer, 1, 'first');

    fprintf('\nKivalasztott fogyaszto: %s\n', selectedCustomer);
    fprintf('Kategoria: %s\n', category(selectedIdx));
    fprintf('Aktiv napok szama: %.1f\n', activeDays(selectedIdx));
    fprintf('Atlagos napi energia: %.1f kWh/nap\n', avgDailyEnergy_kWh(selectedIdx));
    fprintf('Uzemi napi csucs: %.1f kW\n', productionPeakDaily_kW(selectedIdx));
    fprintf('Uzemi atlagteljesitmeny: %.1f kW\n', productionMeanDaily_kW(selectedIdx));
    fprintf('Uzemen kivuli atlagteljesitmeny: %.1f kW\n', offMeanDaily_kW(selectedIdx));
    fprintf('Off/production arany: %.3f\n\n', offToProductionRatio(selectedIdx));

    disp('Legjobb 10 jelolt:');
    disp(candidates(1:min(10, height(candidates)), :));

    % ---------------------------------------------------------------------
    % 8) Kivalasztott fogyaszto napi atlagprofiljanak plottolasa
    % ---------------------------------------------------------------------
    figure('Color', 'w', 'Name', 'Selected industry profile');
    hold on;
    grid on;

    selectedProfile_kW = dailyProfiles_kW(:, selectedIdx);

    plot(timeOfDayOriginal, selectedProfile_kW, 'LineWidth', 2.5);
    yline(targetProductionPeak_kW, '--', 'Target 800 kW');

    xlabel('Napon beluli ido');
    ylabel('Atlagos teljesitmeny [kW]');
    title(sprintf('Kivalasztott industry jellegu fogyaszto: %s', selectedCustomer));

    hold off;

    % ---------------------------------------------------------------------
    % 9) Napi .mat fajlok keszitese a kivalasztott fogyasztora
    % ---------------------------------------------------------------------
    fprintf('Napi .mat fajlok keszitese...\n');

    selectedPower_kW = P_kW(:, selectedIdx);

    activeIdx = selectedPower_kW > 0 & ~isnan(selectedPower_kW);
    firstIdx = find(activeIdx, 1, 'first');
    lastIdx  = find(activeIdx, 1, 'last');

    selectedPower_kW = selectedPower_kW(firstIdx:lastIdx);
    selectedTime = time(firstIdx:lastIdx);

    datesOnly = dateshift(selectedTime, 'start', 'day');
    uniqueDays = unique(datesOnly);

    if outputResolutionMin == 30
        dtOut_h = 0.5;
        timeMinAxis = 0:30:1410;
        expectedOutputCount = 48;
    elseif outputResolutionMin == 15
        dtOut_h = 0.25;
        timeMinAxis = 0:15:1425;
        expectedOutputCount = 96;
    else
        error('Csak 15 vagy 30 perces kimeneti felbontas tamogatott.');
    end

    totalSavedDays = 0;
    skippedDays = 0;

    for d = 1:numel(uniqueDays)

        currentDay = uniqueDays(d);
        dayMask = datesOnly == currentDay;

        pDay_kW_15min = selectedPower_kW(dayMask);

        % Csak teljes 15 perces napokat mentunk.
        if numel(pDay_kW_15min) ~= samplesPerDayOriginal
            skippedDays = skippedDays + 1;
            continue;
        end

        if any(isnan(pDay_kW_15min)) || sum(pDay_kW_15min) <= 0
            skippedDays = skippedDays + 1;
            continue;
        end

        % Energia 15 perces intervallumokra [kWh]
        eDay_kWh_15min = pDay_kW_15min(:)' * dtOriginal_h;

        if outputResolutionMin == 30

            % 15 perces energiak osszegzese 30 percre.
            eDay_kWh = eDay_kWh_15min(1:2:end) + eDay_kWh_15min(2:2:end);
            pDay_kW = eDay_kWh / dtOut_h;

        else

            eDay_kWh = eDay_kWh_15min;
            pDay_kW = pDay_kW_15min(:)';

        end

        if numel(pDay_kW) ~= expectedOutputCount
            skippedDays = skippedDays + 1;
            continue;
        end

        loadPower_W = pDay_kW * 1000;
        loadEnergy_Wh = eDay_kWh * 1000;

        % Nincs PV adat ebben a datasetben.
        pvPower_W = zeros(size(loadPower_W));
        pvEnergy_Wh = zeros(size(loadEnergy_Wh));

        consumptionCache = struct();

        consumptionCache.projectName = 'ElectricityLoadDiagrams_Industry_PV_BESS';
        consumptionCache.sourceName = 'ElectricityLoadDiagrams20112014';
        consumptionCache.selectedCustomer = selectedCustomer;
        consumptionCache.selectedCategory = category(selectedIdx);

        consumptionCache.dateString = datestr(currentDay, 'yyyy.mm.dd');
        consumptionCache.date = currentDay;

        consumptionCache.dt_h = dtOut_h;
        consumptionCache.timeMinAxis = timeMinAxis;

        % Ausgrid formatumhoz illeszkedo mezok
        consumptionCache.powerTotal_W = loadPower_W;
        consumptionCache.energyTotal_Wh = loadEnergy_Wh;

        consumptionCache.powerPV_W = pvPower_W;
        consumptionCache.energyPV_Wh = pvEnergy_Wh;

        % Alternativ, egyertelmu mezok
        consumptionCache.loadPower_W = loadPower_W;
        consumptionCache.loadEnergy_Wh = loadEnergy_Wh;
        consumptionCache.pvPower_W = pvPower_W;
        consumptionCache.pvEnergy_Wh = pvEnergy_Wh;

        % Napi osszesitok
        consumptionCache.totalLoadEnergy_kWh = sum(loadEnergy_Wh) / 1000;
        consumptionCache.totalPVEnergy_kWh = 0;
        consumptionCache.peakLoad_W = max(loadPower_W);
        consumptionCache.peakPV_W = 0;

        % Eredeti adat informacio
        consumptionCache.originalDt_h = dtOriginal_h;
        consumptionCache.outputResolutionMin = outputResolutionMin;
        consumptionCache.originalSamplesPerDay = samplesPerDayOriginal;

        consumptionCache.productionStartHour = productionStartHour;
        consumptionCache.productionEndHour = productionEndHour;

        consumptionCache.averageDailyProductionPeak_kW = productionPeakDaily_kW(selectedIdx);
        consumptionCache.averageDailyOffMean_kW = offMeanDaily_kW(selectedIdx);

        fileName = sprintf('consumption_ORIG_%s.mat', ...
            datestr(currentDay, 'yyyy_mm_dd'));

        fullFilePath = fullfile(savePath, fileName);

        save(fullFilePath, 'consumptionCache');

        totalSavedDays = totalSavedDays + 1;
    end

    % ---------------------------------------------------------------------
    % 10) Processing summary mentese
    % ---------------------------------------------------------------------
    processingSummary = struct();

    processingSummary.sourceFile = txtFilePath;
    processingSummary.savePath = savePath;
    processingSummary.selectedCustomer = selectedCustomer;
    processingSummary.selectedCategory = category(selectedIdx);

    processingSummary.dtOriginal_h = dtOriginal_h;
    processingSummary.dtOutput_h = dtOut_h;
    processingSummary.timeMinAxis = timeMinAxis;

    processingSummary.totalSavedDays = totalSavedDays;
    processingSummary.skippedDays = skippedDays;

    processingSummary.candidateTable = candidateTable;
    processingSummary.bestCandidates = candidates(1:min(20, height(candidates)), :);

    processingSummary.selectedMetrics = candidateTable(selectedIdx, :);

    save(fullfile(savePath, 'electricityloaddiagrams_industry_processing_summary.mat'), ...
        'processingSummary');

    fprintf('Feldolgozas kesz.\n');
    fprintf('Mentett napi .mat fajlok szama: %d\n', totalSavedDays);
    fprintf('Kihagyott napok szama: %d\n', skippedDays);

    % ---------------------------------------------------------------------
    % 11) Kimeneti result struktura
    % ---------------------------------------------------------------------
    result = struct();

    result.time = time;
    result.power_kW = P_kW;
    result.customerNames = customerNames;
    result.category = category;

    result.dailyProfiles_kW = dailyProfiles_kW;
    result.timeOfDayOriginal = timeOfDayOriginal;

    result.candidateTable = candidateTable;
    result.bestCandidates = candidates;
    result.selectedCustomer = selectedCustomer;
    result.selectedIdx = selectedIdx;
    result.selectedProfile_kW = selectedProfile_kW;

    result.processingSummary = processingSummary;

end


% =========================================================================
% SEGEDFUGGVENYEK
% =========================================================================

function tempFilePath = local_create_decimal_dot_copy(inputFilePath)
% Letrehoz egy ideiglenes fajlt, ahol a decimalis vesszok pontok.

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
% Ideiglenes fajl torlese.

    if isfile(tempFilePath)
        delete(tempFilePath);
    end

end


function avgProfile = local_average_daily_profile(time, p, samplesPerDay)
% Atlagos napi profil szamitasa teljes napokbol.

    datesOnly = dateshift(time, 'start', 'day');
    uniqueDays = unique(datesOnly);

    profiles = nan(samplesPerDay, numel(uniqueDays));

    for d = 1:numel(uniqueDays)

        idxDay = datesOnly == uniqueDays(d);
        pDay = p(idxDay);

        if numel(pDay) ~= samplesPerDay
            continue;
        end

        if any(isnan(pDay)) || sum(pDay) <= 0
            continue;
        end

        profiles(:, d) = pDay(:);

    end

    avgProfile = mean(profiles, 2, 'omitnan');

end


function q = local_percentile(x, p)
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