function result = process_load_to_structured_data(txtFileName)
% PROCESS_LOAD_TO_STRUCTURED_DATA
%
% ElectricityLoadDiagrams20112014 dataset feldolgozasa PV+BESS
% onfogyasztas-novelesi vizsgalathoz.
%
% Hasznalat:
%
%   result = process_load_to_structured_data('LD2011_2014.txt');
%
% Automatikus mappaszerkezet:
%
%   current_function_folder/
%       process_load_to_structured_data.m
%       consumption_csv/
%           LD2011_2014.txt
%       consumption/
%           consumption_ORIG_yyyy_mm_dd.mat
%
% A fuggveny:
%   1) Beolvassa a 15 perces fogyasztasi adatokat.
%   2) Kiszuri az ervenyes fogyasztokat.
%   3) Heurisztikusan besorolja oket:
%        residential / commercial / industry
%   4) Kivalaszt egy ipari profilt, amelynel:
%        - a csucsteljesitmeny legalabb 100 kW
%        - a 10:00-14:00 kozotti fogyasztasi energia aranya
%          a teljes napi fogyasztashoz kepest a legkisebb
%        - tehat PV termelesi csucsidoben kedvezotlenebb az onfogyasztas
%   5) A kivalasztott fogyasztot napi .mat fajlokra bontja.
%
% Megjegyzes:
%   A dataset nem tartalmaz hivatalos fogyasztotipus-cimkeket.
%   Az industry/commercial/residential besorolas heurisztikus.

    % ---------------------------------------------------------------------
    % 0) Automatikus utvonalak
    % ---------------------------------------------------------------------
    if nargin < 1 || strlength(string(txtFileName)) == 0
        error('Meg kell adni a bemeneti txt fajl nevet. Pelda: process_load_to_structured_data(''LD2011_2014.txt'')');
    end

    txtFileName = char(txtFileName);

    if contains(txtFileName, filesep) || contains(txtFileName, '/')
        error('Csak a fajlnevet add meg, ne teljes eleresi utvonalat. Pelda: LD2011_2014.txt');
    end

    functionFullPath = mfilename('fullpath');
    functionFolderPath = fileparts(functionFullPath);

    inputFolderPath = fullfile(functionFolderPath, 'consumption_csv');
    savePath = fullfile(functionFolderPath, 'consumption');

    txtFilePath = fullfile(inputFolderPath, txtFileName);

    assert(isfolder(inputFolderPath), ...
        'Hiba: A consumption_csv mappa nem talalhato: %s', inputFolderPath);

    assert(isfile(txtFilePath), ...
        'Hiba: A megadott txt fajl nem talalhato: %s', txtFilePath);

    if ~isfolder(savePath)
        mkdir(savePath);
    end

    fprintf('ElectricityLoadDiagrams feldolgozas indul...\n');
    fprintf('Fuggveny mappa: %s\n', functionFolderPath);
    fprintf('Bemeneti fajl: %s\n', txtFilePath);
    fprintf('Mentesi mappa: %s\n\n', savePath);

    % ---------------------------------------------------------------------
    % 1) Kivalasztasi beallitasok
    % ---------------------------------------------------------------------

    % Most nem celzott 400 kW koruli csucsot keresunk.
    % Csak az a feltetel, hogy ipari profil legyen es legalabb 100 kW felett legyen.
    minSelectionPeak_kW = 100;

    % Legalabb kb. egy ev aktiv adat.
    minActiveDays = 300;

    % A kimenet 30 perces legyen, hogy illeszkedjen a tovabbi keretrendszerhez.
    outputResolutionMin = 30;

    % Uzemi idoszak.
    productionStartHour = 6;
    productionEndHour   = 22;

    % PV-termelesi csucsidő, ahol minél kisebb fogyasztási arányt keresünk.
    pvPeakStartHour = 10;
    pvPeakEndHour   = 14;

    % Nem-PV idoszakok csak diagnosztikai metrikakhoz.
    morningNonPvPeakStartHour = 6;
    morningNonPvPeakEndHour   = 10;

    eveningNonPvPeakStartHour = 15;
    eveningNonPvPeakEndHour   = 22;

    % Uzemen kivuli idoszak.
    offHourMorningEnd = 6;
    offHourEveningStart = 22;

    % Szigoritott ipari jelleg feltetelek.
    minIndustrialLoadFactor = 0.35;
    minIndustrialNightRatio = 0.18;
    minIndustrialWeekendRatio = 0.55;

    % ---------------------------------------------------------------------
    % 2) Decimalis vesszo kezelese
    % ---------------------------------------------------------------------
    tempFilePath = local_create_decimal_dot_copy(txtFilePath);
    cleanupObj = onCleanup(@() local_delete_temp_file(tempFilePath)); %#ok<NASGU>

    % ---------------------------------------------------------------------
    % 3) Beolvasas
    % ---------------------------------------------------------------------
    fprintf('Fajl beolvasasa...\n');

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

    nSamples = size(P_kW, 1);
    nCustomers = size(P_kW, 2);

    fprintf('Mintak szama: %d\n', nSamples);
    fprintf('Fogyasztok szama: %d\n', nCustomers);

    % ---------------------------------------------------------------------
    % 4) Mintaveteli ido
    % ---------------------------------------------------------------------
    dtOriginal_h = hours(median(diff(time)));

    fprintf('Eredeti mintaveteli ido: %.4f h\n', dtOriginal_h);

    if abs(dtOriginal_h - 0.25) > 1e-6
        warning('A vart 15 perces mintavetelezes helyett %.4f h adodott.', dtOriginal_h);
    end

    samplesPerDayOriginal = round(24 / dtOriginal_h);

    % ---------------------------------------------------------------------
    % 5) Fogyasztoi jellemzok es napi atlagprofilok
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

            avgWeekendPower = weekendEnergy_kWh / max(weekendHours, eps);
            avgWeekdayPower = weekdayEnergy_kWh / max(weekdayHours, eps);

            if avgWeekdayPower > 0
                weekendToWeekdayRatio(c) = avgWeekendPower / avgWeekdayPower;
            end
        end

        dailyProfiles_kW(:, c) = local_average_daily_profile( ...
            tWin, pWin, samplesPerDayOriginal);
    end

    % ---------------------------------------------------------------------
    % 6) Ervenyes fogyasztok megtartasa
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

    if nValidCustomers == 0
        error('Nincs egyetlen ervenyes fogyaszto sem.');
    end

    % ---------------------------------------------------------------------
    % 7) Heurisztikus residential / commercial / industry besorolas
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
    % 8) Szigoritott ipari jelleg
    % ---------------------------------------------------------------------
    strictIndustry = false(1, nValidCustomers);

    for c = 1:nValidCustomers

        LF = loadFactor(c);
        NR = nightRatio(c);
        DR = daytimeRatio(c);
        WR = weekendToWeekdayRatio(c);

        if isnan(WR)
            WR = 0;
        end

        industrialContinuity = ...
            LF >= minIndustrialLoadFactor || ...
            NR >= minIndustrialNightRatio || ...
            WR >= minIndustrialWeekendRatio;

        likelyCommercialBuilding = ...
            DR >= 0.55 && ...
            NR < minIndustrialNightRatio && ...
            WR < 0.45;

        strictIndustry(c) = ...
            category(c) == "industry" && ...
            industrialContinuity && ...
            ~likelyCommercialBuilding;
    end

    % ---------------------------------------------------------------------
    % 9) Ipari profilkivalasztasi metrikak
    % ---------------------------------------------------------------------
    fprintf('\nIndustry jellegu profil kivalasztasa...\n');

    timeOfDayOriginal = duration(0, 0, 0) + ...
        minutes((0:samplesPerDayOriginal-1) * dtOriginal_h * 60);

    hourAxis = hours(timeOfDayOriginal);

    isProductionTime = ...
        hourAxis >= productionStartHour & ...
        hourAxis < productionEndHour;

    isPvPeakWindow = ...
        hourAxis >= pvPeakStartHour & ...
        hourAxis < pvPeakEndHour;

    isMorningNonPvPeak = ...
        hourAxis >= morningNonPvPeakStartHour & ...
        hourAxis < morningNonPvPeakEndHour;

    isEveningNonPvPeak = ...
        hourAxis >= eveningNonPvPeakStartHour & ...
        hourAxis < eveningNonPvPeakEndHour;

    isNonPvPeakWindow = isMorningNonPvPeak | isEveningNonPvPeak;

    isOffTime = ...
        hourAxis < offHourMorningEnd | ...
        hourAxis >= offHourEveningStart;

    productionPeakDaily_kW = nan(1, nValidCustomers);
    productionMeanDaily_kW = nan(1, nValidCustomers);

    nonPvPeakDaily_kW = nan(1, nValidCustomers);
    nonPvPeakHour = nan(1, nValidCustomers);

    pvPeakWindowMean_kW = nan(1, nValidCustomers);
    pvPeakWindowPeak_kW = nan(1, nValidCustomers);
    pvPeakWindowEnergy_kWh = nan(1, nValidCustomers);

    totalDailyProfileEnergy_kWh = nan(1, nValidCustomers);

    pvWindowToTotalEnergyRatio = nan(1, nValidCustomers);
    pvWindowMeanToDailyMeanRatio = nan(1, nValidCustomers);

    middayDip_kW = nan(1, nValidCustomers);
    middayDipPercent = nan(1, nValidCustomers);

    offMeanDaily_kW = nan(1, nValidCustomers);
    offToNonPvPeakRatio = nan(1, nValidCustomers);

    globalPeakHour = nan(1, nValidCustomers);
    globalPeakDuringPVPeakWindow = false(1, nValidCustomers);

    selectionScore = nan(1, nValidCustomers);

    for c = 1:nValidCustomers

        prof = dailyProfiles_kW(:, c);

        if all(isnan(prof))
            continue;
        end

        % Teljes napi energia az atlagprofilbol.
        totalDailyProfileEnergy_kWh(c) = sum(prof, 'omitnan') * dtOriginal_h;

        productionPeakDaily_kW(c) = max(prof(isProductionTime), [], 'omitnan');
        productionMeanDaily_kW(c) = mean(prof(isProductionTime), 'omitnan');

        [nonPvPeakDaily_kW(c), idxLocalNonPv] = max(prof(isNonPvPeakWindow), [], 'omitnan');
        nonPvHours = hourAxis(isNonPvPeakWindow);

        if ~isempty(idxLocalNonPv) && ~isnan(nonPvPeakDaily_kW(c))
            nonPvPeakHour(c) = nonPvHours(idxLocalNonPv);
        end

        pvPeakWindowMean_kW(c) = mean(prof(isPvPeakWindow), 'omitnan');
        pvPeakWindowPeak_kW(c) = max(prof(isPvPeakWindow), [], 'omitnan');

        pvPeakWindowEnergy_kWh(c) = sum(prof(isPvPeakWindow), 'omitnan') * dtOriginal_h;

        if totalDailyProfileEnergy_kWh(c) > 0
            pvWindowToTotalEnergyRatio(c) = ...
                pvPeakWindowEnergy_kWh(c) / totalDailyProfileEnergy_kWh(c);
        end

        dailyMean_kW = mean(prof, 'omitnan');

        if dailyMean_kW > 0
            pvWindowMeanToDailyMeanRatio(c) = ...
                pvPeakWindowMean_kW(c) / dailyMean_kW;
        end

        offMeanDaily_kW(c) = mean(prof(isOffTime), 'omitnan');

        [~, idxGlobalPeak] = max(prof, [], 'omitnan');
        globalPeakHour(c) = hourAxis(idxGlobalPeak);

        globalPeakDuringPVPeakWindow(c) = ...
            globalPeakHour(c) >= pvPeakStartHour && ...
            globalPeakHour(c) < pvPeakEndHour;

        if nonPvPeakDaily_kW(c) > 0

            middayDip_kW(c) = ...
                nonPvPeakDaily_kW(c) - pvPeakWindowMean_kW(c);

            middayDipPercent(c) = ...
                local_safe_divide(middayDip_kW(c), nonPvPeakDaily_kW(c));

            offToNonPvPeakRatio(c) = ...
                offMeanDaily_kW(c) / nonPvPeakDaily_kW(c);
        end

        % -------------------------------------------------------------
        % Kivalasztasi score
        % -------------------------------------------------------------
        % A legfontosabb tag:
        %   10-14 kozotti energia / teljes napi energia.
        %
        % Minel kisebb, annal jobb.
        %
        % Nincs 400 kW-os cel, a peak csak minimumfeltetel.
        if isnan(pvWindowToTotalEnergyRatio(c))
            pvEnergyShareTerm = 10;
        else
            pvEnergyShareTerm = pvWindowToTotalEnergyRatio(c);
        end

        if isnan(pvWindowMeanToDailyMeanRatio(c))
            pvMeanTerm = 2;
        else
            pvMeanTerm = pvWindowMeanToDailyMeanRatio(c);
        end

        activePenalty = 0;
        if activeDays(c) < minActiveDays
            activePenalty = 10;
        end

        industryPenalty = 0;
        if ~strictIndustry(c)
            industryPenalty = 5;
        end

        peakPenalty = 0;
        if peakPower_kW(c) < minSelectionPeak_kW
            peakPenalty = 10;
        end

        pvPeakGlobalPenalty = 0;
        if globalPeakDuringPVPeakWindow(c)
            pvPeakGlobalPenalty = 0.5;
        end

        % A kisebb score jobb.
        selectionScore(c) = ...
            10.00 * pvEnergyShareTerm + ...
            1.00  * pvMeanTerm + ...
            pvPeakGlobalPenalty + ...
            activePenalty + ...
            industryPenalty + ...
            peakPenalty;
    end

    % ---------------------------------------------------------------------
    % 10) Candidate table
    % ---------------------------------------------------------------------
    candidateTable = table( ...
        customerNames(:), ...
        category(:), ...
        strictIndustry(:), ...
        activeDays(:), ...
        avgDailyEnergy_kWh(:), ...
        meanPower_kW(:), ...
        peakPower_kW(:), ...
        loadFactor(:), ...
        nightRatio(:), ...
        daytimeRatio(:), ...
        weekendToWeekdayRatio(:), ...
        productionPeakDaily_kW(:), ...
        productionMeanDaily_kW(:), ...
        nonPvPeakDaily_kW(:), ...
        nonPvPeakHour(:), ...
        pvPeakWindowMean_kW(:), ...
        pvPeakWindowPeak_kW(:), ...
        pvPeakWindowEnergy_kWh(:), ...
        totalDailyProfileEnergy_kWh(:), ...
        pvWindowToTotalEnergyRatio(:), ...
        pvWindowMeanToDailyMeanRatio(:), ...
        middayDip_kW(:), ...
        middayDipPercent(:), ...
        offMeanDaily_kW(:), ...
        offToNonPvPeakRatio(:), ...
        globalPeakHour(:), ...
        globalPeakDuringPVPeakWindow(:), ...
        selectionScore(:), ...
        'VariableNames', { ...
            'Customer', ...
            'Category', ...
            'StrictIndustry', ...
            'ActiveDays', ...
            'AvgDailyEnergy_kWh', ...
            'MeanPower_kW', ...
            'GlobalPeakPower_kW', ...
            'LoadFactor', ...
            'NightRatio', ...
            'DaytimeRatio', ...
            'WeekendToWeekdayRatio', ...
            'ProductionPeakDaily_kW', ...
            'ProductionMeanDaily_kW', ...
            'NonPvPeakDaily_kW', ...
            'NonPvPeakHour', ...
            'PvPeakWindowMean_kW', ...
            'PvPeakWindowPeak_kW', ...
            'PvPeakWindowEnergy_kWh', ...
            'TotalDailyProfileEnergy_kWh', ...
            'PvWindowToTotalEnergyRatio', ...
            'PvWindowMeanToDailyMeanRatio', ...
            'MiddayDip_kW', ...
            'MiddayDipPercent', ...
            'OffMeanDaily_kW', ...
            'OffToNonPvPeakRatio', ...
            'GlobalPeakHour', ...
            'GlobalPeakDuringPVPeakWindow', ...
            'SelectionScore'});

    % ---------------------------------------------------------------------
    % 11) Jeloltek szurese - csak ipari, nincs commercial fallback
    % ---------------------------------------------------------------------

    % Elsodleges: strict industry, legalabb 300 aktiv nap, peak >= 100 kW.
    candidateMask = ...
        candidateTable.StrictIndustry == true & ...
        candidateTable.ActiveDays >= minActiveDays & ...
        candidateTable.GlobalPeakPower_kW >= minSelectionPeak_kW & ...
        isfinite(candidateTable.PvWindowToTotalEnergyRatio);

    % Ha nincs strict industry, akkor is csak industry kategoria,
    % commercial/residential nem megengedett.
    if ~any(candidateMask)
        warning(['Nem talaltam strictIndustry profilt. ', ...
                 'Csak category == "industry" profilokra lazitok, commercial/residential tovabbra sem engedett.']);

        candidateMask = ...
            candidateTable.Category == "industry" & ...
            candidateTable.ActiveDays >= minActiveDays & ...
            candidateTable.GlobalPeakPower_kW >= minSelectionPeak_kW & ...
            isfinite(candidateTable.PvWindowToTotalEnergyRatio);
    end

    % Ha igy sincs, hiba.
    if ~any(candidateMask)
        error(['Nem talaltam megfelelo ipari fogyasztasi profilt. ', ...
               'Feltetelek: industry jelleg, legalabb %.0f aktiv nap, ', ...
               'legalabb %.0f kW csucsteljesitmeny, ervenyes 10-14h energiaarany.'], ...
               minActiveDays, minSelectionPeak_kW);
    end

    candidates = candidateTable(candidateMask, :);

    % Fontos:
    %   A fo rendezesi szempont a 10-14h energia / teljes napi energia.
    %   Masodlagos a SelectionScore.
    candidates = sortrows(candidates, ...
        {'PvWindowToTotalEnergyRatio', 'SelectionScore'}, ...
        {'ascend', 'ascend'});

    selectedCustomer = candidates.Customer(1);
    selectedIdx = find(customerNames == selectedCustomer, 1, 'first');

    fprintf('\nKivalasztott fogyaszto: %s\n', selectedCustomer);
    fprintf('Kategoria: %s\n', category(selectedIdx));
    fprintf('Strict industry: %d\n', strictIndustry(selectedIdx));
    fprintf('Aktiv napok szama: %.1f\n', activeDays(selectedIdx));
    fprintf('Atlagos napi energia: %.1f kWh/nap\n', avgDailyEnergy_kWh(selectedIdx));
    fprintf('Globalis csucsteljesitmeny: %.1f kW\n', peakPower_kW(selectedIdx));
    fprintf('Nem-PV idoszaki csucs: %.1f kW\n', nonPvPeakDaily_kW(selectedIdx));
    fprintf('Nem-PV csucs oraja: %.2f h\n', nonPvPeakHour(selectedIdx));
    fprintf('10-14h atlagteljesitmeny: %.1f kW\n', pvPeakWindowMean_kW(selectedIdx));
    fprintf('10-14h energia: %.1f kWh/nap\n', pvPeakWindowEnergy_kWh(selectedIdx));
    fprintf('Teljes napi profilenergia: %.1f kWh/nap\n', totalDailyProfileEnergy_kWh(selectedIdx));
    fprintf('10-14h energia aranya a teljes napi fogyasztashoz kepest: %.2f %%\n', ...
        pvWindowToTotalEnergyRatio(selectedIdx) * 100);
    fprintf('Deli visszaeses a nem-PV csucshoz kepest: %.1f kW\n', middayDip_kW(selectedIdx));
    fprintf('Deli visszaeses aranya: %.1f %%\n', middayDipPercent(selectedIdx) * 100);
    fprintf('Selection score: %.4f\n\n', selectionScore(selectedIdx));

    disp('Legjobb 10 ipari jelolt a 10-14h energiaarany alapjan:');
    disp(candidates(1:min(10, height(candidates)), :));

    % ---------------------------------------------------------------------
    % 12) Kivalasztott fogyaszto napi atlagprofiljanak plottolasa
    % ---------------------------------------------------------------------
    selectedProfile_kW = dailyProfiles_kW(:, selectedIdx);

    fig = figure('Color', 'w', 'Name', 'Selected industry load profile');
    hold on;
    grid on;

    yLimMax = max(selectedProfile_kW, [], 'omitnan') * 1.15;
    if isempty(yLimMax) || isnan(yLimMax) || yLimMax <= 0
        yLimMax = 1;
    end

    pvStartDur = duration(floor(pvPeakStartHour), ...
        round((pvPeakStartHour - floor(pvPeakStartHour)) * 60), 0);

    pvEndDur = duration(floor(pvPeakEndHour), ...
        round((pvPeakEndHour - floor(pvPeakEndHour)) * 60), 0);

    patch([pvStartDur pvEndDur pvEndDur pvStartDur], ...
          [0 0 yLimMax yLimMax], ...
          [0.90 0.90 0.90], ...
          'EdgeColor', 'none', ...
          'FaceAlpha', 0.35, ...
          'DisplayName', '10-14h PV-termelesi idoszak');

    plot(timeOfDayOriginal, selectedProfile_kW, ...
        'LineWidth', 2.5, ...
        'DisplayName', 'Atlagos napi fogyasztas');

    yline(minSelectionPeak_kW, '--', ...
        'Legalabb 100 kW csucs', ...
        'LineWidth', 1.2, ...
        'DisplayName', 'Minimum csucs feltetel');

    ylim([0 yLimMax]);

    xlabel('Napon beluli ido');
    ylabel('Atlagos teljesitmeny [kW]');
    title(sprintf('Kivalasztott ipari fogyaszto: %s', selectedCustomer), ...
        'Interpreter', 'none');

    legend('Location', 'best');
    hold off;

    saveas(fig, fullfile(savePath, 'selected_industry_profile.png'));
    savefig(fig, fullfile(savePath, 'selected_industry_profile.fig'));

    % ---------------------------------------------------------------------
    % 13) Napi .mat fajlok keszitese a kivalasztott fogyasztora
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

        if numel(pDay_kW_15min) ~= samplesPerDayOriginal
            skippedDays = skippedDays + 1;
            continue;
        end

        if any(isnan(pDay_kW_15min)) || sum(pDay_kW_15min) <= 0
            skippedDays = skippedDays + 1;
            continue;
        end

        eDay_kWh_15min = pDay_kW_15min(:)' * dtOriginal_h;

        if outputResolutionMin == 30

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

        pvPower_W = zeros(size(loadPower_W));
        pvEnergy_Wh = zeros(size(loadEnergy_Wh));

        consumptionCache = struct();

        consumptionCache.projectName = 'ElectricityLoadDiagrams_Industry_PV_BESS';
        consumptionCache.sourceName = 'ElectricityLoadDiagrams20112014';
        consumptionCache.selectedCustomer = selectedCustomer;
        consumptionCache.selectedCategory = category(selectedIdx);
        consumptionCache.strictIndustry = strictIndustry(selectedIdx);

        consumptionCache.dateString = datestr(currentDay, 'yyyy.mm.dd');
        consumptionCache.date = currentDay;

        consumptionCache.dt_h = dtOut_h;
        consumptionCache.timeMinAxis = timeMinAxis;

        consumptionCache.powerTotal_W = loadPower_W;
        consumptionCache.energyTotal_Wh = loadEnergy_Wh;

        consumptionCache.powerPV_W = pvPower_W;
        consumptionCache.energyPV_Wh = pvEnergy_Wh;

        consumptionCache.loadPower_W = loadPower_W;
        consumptionCache.loadEnergy_Wh = loadEnergy_Wh;
        consumptionCache.pvPower_W = pvPower_W;
        consumptionCache.pvEnergy_Wh = pvEnergy_Wh;

        consumptionCache.totalLoadEnergy_kWh = sum(loadEnergy_Wh) / 1000;
        consumptionCache.totalPVEnergy_kWh = 0;
        consumptionCache.peakLoad_W = max(loadPower_W);
        consumptionCache.peakPV_W = 0;

        consumptionCache.originalDt_h = dtOriginal_h;
        consumptionCache.outputResolutionMin = outputResolutionMin;
        consumptionCache.originalSamplesPerDay = samplesPerDayOriginal;

        consumptionCache.productionStartHour = productionStartHour;
        consumptionCache.productionEndHour = productionEndHour;

        consumptionCache.pvPeakStartHour = pvPeakStartHour;
        consumptionCache.pvPeakEndHour = pvPeakEndHour;

        consumptionCache.averageDailyNonPvPeak_kW = nonPvPeakDaily_kW(selectedIdx);
        consumptionCache.averageDailyNonPvPeakHour = nonPvPeakHour(selectedIdx);
        consumptionCache.averageDailyPvPeakWindowMean_kW = pvPeakWindowMean_kW(selectedIdx);
        consumptionCache.averageDailyPvPeakWindowEnergy_kWh = pvPeakWindowEnergy_kWh(selectedIdx);
        consumptionCache.averageDailyTotalProfileEnergy_kWh = totalDailyProfileEnergy_kWh(selectedIdx);
        consumptionCache.averageDailyPvWindowToTotalEnergyRatio = pvWindowToTotalEnergyRatio(selectedIdx);
        consumptionCache.averageDailyMiddayDip_kW = middayDip_kW(selectedIdx);
        consumptionCache.averageDailyMiddayDipPercent = middayDipPercent(selectedIdx);
        consumptionCache.averageDailyOffMean_kW = offMeanDaily_kW(selectedIdx);

        fileName = sprintf('consumption_ORIG_%s.mat', ...
            datestr(currentDay, 'yyyy_mm_dd'));

        fullFilePath = fullfile(savePath, fileName);

        save(fullFilePath, 'consumptionCache');

        totalSavedDays = totalSavedDays + 1;
    end

    % ---------------------------------------------------------------------
    % 14) Processing summary mentese
    % ---------------------------------------------------------------------
    processingSummary = struct();

    processingSummary.sourceFile = txtFilePath;
    processingSummary.inputFolderPath = inputFolderPath;
    processingSummary.savePath = savePath;

    processingSummary.selectedCustomer = selectedCustomer;
    processingSummary.selectedCategory = category(selectedIdx);
    processingSummary.strictIndustry = strictIndustry(selectedIdx);

    processingSummary.dtOriginal_h = dtOriginal_h;
    processingSummary.dtOutput_h = dtOut_h;
    processingSummary.timeMinAxis = timeMinAxis;

    processingSummary.totalSavedDays = totalSavedDays;
    processingSummary.skippedDays = skippedDays;

    processingSummary.selectionSettings = struct();
    processingSummary.selectionSettings.minSelectionPeak_kW = minSelectionPeak_kW;
    processingSummary.selectionSettings.minActiveDays = minActiveDays;
    processingSummary.selectionSettings.pvPeakStartHour = pvPeakStartHour;
    processingSummary.selectionSettings.pvPeakEndHour = pvPeakEndHour;
    processingSummary.selectionSettings.primaryCriterion = ...
        'minimal 10-14h energy share relative to total daily consumption';

    processingSummary.candidateTable = candidateTable;
    processingSummary.bestCandidates = candidates(1:min(20, height(candidates)), :);
    processingSummary.selectedMetrics = candidateTable(selectedIdx, :);
    processingSummary.selectedProfile_kW = selectedProfile_kW;
    processingSummary.timeOfDayOriginal = timeOfDayOriginal;

    save(fullfile(savePath, 'electricityloaddiagrams_industry_processing_summary.mat'), ...
        'processingSummary');

    fprintf('Feldolgozas kesz.\n');
    fprintf('Mentett napi .mat fajlok szama: %d\n', totalSavedDays);
    fprintf('Kihagyott napok szama: %d\n', skippedDays);

    % ---------------------------------------------------------------------
    % 15) Kimeneti result struktura
    % ---------------------------------------------------------------------
    result = struct();

    result.time = time;
    result.power_kW = P_kW;
    result.customerNames = customerNames;
    result.category = category;
    result.strictIndustry = strictIndustry;

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


function avgProfile = local_average_daily_profile(time, p, samplesPerDay)

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


function y = local_safe_divide(a, b)

    if isempty(b) || isnan(b) || abs(b) < 1e-12
        y = NaN;
    else
        y = a / b;
    end
end