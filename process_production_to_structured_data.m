function process_production_to_structured_data(P_stc, targetStepMin)
% PROCESS_PRODUCTION_TO_STRUCTURED_DATA
%
% Feldolgozza a BUD BSRN .tab fajlokat, es napi bontasban legeneralja
% a resultBuffer strukturakat megadott perces felbontasban.
%
% Bemenetek:
%   P_stc         : PV modul nevleges teljesitmenye [W]
%   targetStepMin : kimeneti idofelbontas [perc], pl. 5, 10, 15, 30, 60
%
% Hasznalat:
%   process_production_to_structured_data(500, 15)
%
% Automatikus mappaszerkezet:
%
%   process_production_to_structured_data.m mappaja/
%       production_csv/   -> bemeneti BUD .tab fajlok
%       consumption/      -> fogyasztasi consumption_ORIG_*.mat fajlok
%       production/       -> kimeneti resultBuffer_ORIG_*.mat fajlok
%
% Ha a consumption mappa tartalmaz consumption_ORIG_*.mat fajlokat:
%   - a fogyasztasi napok datumait olvassa ki
%   - a BSRN napokat honap-nap szerint illeszti a fogyasztasi napokhoz
%   - pelda:
%       consumption: 2011-01-01
%       BSRN:        2023-07-01 ... 2023-12-31 -> kihagyva
%       BSRN:        2024-01-01                -> mentve 2011-01-01 neven
%
% Fontos:
%   A szinkronizalas evet nem vizsgal, csak honap-nap egyezest.
%   Igy a fogyasztasi idosor eve es a meteorologiai idosor eve lehet kulonbozo,
%   de a szezonalis egyezes megmarad.

    % ---------------------------------------------------------------------
    % 0) Automatikus mappautvonalak
    % ---------------------------------------------------------------------
    functionFullPath = mfilename('fullpath');
    functionFolderPath = fileparts(functionFullPath);

    inputFolderPath = fullfile(functionFolderPath, 'production_csv');
    consumptionFolderPath = fullfile(functionFolderPath, 'consumption');
    outputFolderPath = fullfile(functionFolderPath, 'production');

    if nargin < 1 || isempty(P_stc)
        error('P_stc megadasa kotelezo. Pelda: process_production_to_structured_data(500, 15)');
    end

    if nargin < 2 || isempty(targetStepMin)
        targetStepMin = 5;
    end

    if targetStepMin <= 0 || abs(targetStepMin - round(targetStepMin)) > 1e-9
        error('targetStepMin pozitiv egesz perc kell legyen.');
    end

    if mod(1440, targetStepMin) ~= 0
        error('targetStepMin olyan ertek kell legyen, amely osztja az 1440 percet. Pelda: 5, 10, 15, 30, 60.');
    end

    if ~exist(inputFolderPath, 'dir')
        error('Nem talalhato production_csv mappa: %s', inputFolderPath);
    end

    if ~exist(outputFolderPath, 'dir')
        mkdir(outputFolderPath);
    end

    matchToConsumption = false;

    if exist(consumptionFolderPath, 'dir')
        consumptionFiles = dir(fullfile(consumptionFolderPath, 'consumption_ORIG_*.mat'));

        if ~isempty(consumptionFiles)
            matchToConsumption = true;
        end
    end

    % ---------------------------------------------------------------------
    % BUD .tab fajlok keresese a production_csv mappaban
    % ---------------------------------------------------------------------
    allTabFiles = dir(fullfile(inputFolderPath, '*.tab'));

    if isempty(allTabFiles)
        error('Nem talalhato .tab fajl a megadott mappaban: %s', inputFolderPath);
    end

    tabFileNames = string({allTabFiles.name});
    budMask = contains(upper(tabFileNames), "BUD");

    bsrnFiles = allTabFiles(budMask);

    if isempty(bsrnFiles)
        error('Nem talalhato BUD .tab fajl a megadott mappaban: %s', inputFolderPath);
    end

    [~, idxSort] = sort({bsrnFiles.name});
    bsrnFiles = bsrnFiles(idxSort);

    if matchToConsumption
        targetDates = local_get_consumption_dates(consumptionFolderPath);
        nTargetDays = numel(targetDates);

        fprintf('Fogyasztasi napok szama: %d\n', nTargetDays);
        fprintf('BSRN BUD havi fajlok szama: %d\n', numel(bsrnFiles));
        fprintf('Kimeneti idofelbontas: %d perc\n', targetStepMin);
        fprintf('Szinkronizalt mentes fogyasztasi datumokra.\n');
        fprintf('Illesztes modja: BSRN honap-nap == consumption honap-nap.\n\n');
    else
        targetDates = NaT(0,1);
        nTargetDays = inf;

        fprintf('Osszesen %d db BUD havi fajl feldolgozasa indul...\n', length(bsrnFiles));
        fprintf('Kimeneti idofelbontas: %d perc\n\n', targetStepMin);
    end

    % Budapest - Lorinc BSRN allomas koordinatai
    lat = 47.429;
    lon = 19.182;

    savedDayCounter = 0;
    syncStarted = false;

    for f = 1:length(bsrnFiles)

        if savedDayCounter >= nTargetDays
            break;
        end

        fullFilePath = fullfile(inputFolderPath, bsrnFiles(f).name);
        fprintf('Feldolgozas alatt: %s\n', bsrnFiles(f).name);

        % -----------------------------------------------------------------
        % A) Fejlec dinamikus megkeresese
        % -----------------------------------------------------------------
        lines = readlines(fullFilePath);
        headerLineIdx = find(startsWith(lines, 'Date/Time'), 1);

        if isempty(headerLineIdx)
            warning('Nem talalhato Date/Time fejlec a fajlban: %s. Kihagyva.', bsrnFiles(f).name);
            continue;
        end

        % -----------------------------------------------------------------
        % B) Adatok beolvasasa
        % -----------------------------------------------------------------
        opts = detectImportOptions(fullFilePath, 'FileType', 'text', 'Delimiter', '\t');
        opts.VariableNamesLine = headerLineIdx;
        opts.DataLines = [headerLineIdx + 1, Inf];

        data = readtable(fullFilePath, opts);

        colNames = data.Properties.VariableNames;

        idxDate = find(contains(colNames, 'Date_Time'), 1);

        idxSWD  = find(contains(colNames, 'SWD') & ...
                       ~contains(colNames, 'std') & ...
                       ~contains(colNames, 'min') & ...
                       ~contains(colNames, 'max'), 1);

        idxDIF  = find(contains(colNames, 'DIF') & ...
                       ~contains(colNames, 'std') & ...
                       ~contains(colNames, 'min') & ...
                       ~contains(colNames, 'max'), 1);

        idxSWU  = find(contains(colNames, 'SWU') & ...
                       ~contains(colNames, 'std') & ...
                       ~contains(colNames, 'min') & ...
                       ~contains(colNames, 'max'), 1);

        idxT2   = find(contains(colNames, 'T2'), 1);

        if isempty(idxDate) || isempty(idxSWD) || isempty(idxDIF) || isempty(idxSWU) || isempty(idxT2)
            warning('Hianyzo kotelezo oszlop a fajlban: %s. Kihagyva.', bsrnFiles(f).name);
            continue;
        end

        dates = data{:, idxDate};

        if ~isdatetime(dates)
            try
                dates = datetime(dates, 'InputFormat', 'yyyy-MM-dd''T''HH:mm:ss');
            catch
                dates = datetime(dates, 'InputFormat', 'yyyy-MM-dd''T''HH:mm');
            end
        end

        % -----------------------------------------------------------------
        % C) Napi bontas
        % -----------------------------------------------------------------
        uniqueDays = unique(dates - timeofday(dates));

        for d = 1:length(uniqueDays)

            if savedDayCounter >= nTargetDays
                break;
            end

            currentDay = uniqueDays(d);

            % -------------------------------------------------------------
            % C/1) Fogyasztasi napokhoz valo szinkronizalas
            % -------------------------------------------------------------
            if matchToConsumption

                nextTargetDate = targetDates(savedDayCounter + 1);

                if ~local_same_month_day(currentDay, nextTargetDate)
                    continue;
                end

                if ~syncStarted
                    fprintf('Szinkronizacio kezdete megtalalva:\n');
                    fprintf('  Elso BSRN forrasnap:     %s\n', datestr(currentDay, 'yyyy-mm-dd'));
                    fprintf('  Elso fogyasztasi celnap: %s\n\n', datestr(nextTargetDate, 'yyyy-mm-dd'));
                    syncStarted = true;
                end
            end

            dayMask = (dates >= currentDay) & (dates < currentDay + days(1));

            if sum(dayMask) == 0
                continue;
            end

            rawTime = dates(dayMask);
            rawGHI  = data{dayMask, idxSWD};
            rawDIF  = data{dayMask, idxDIF};
            rawSWU  = data{dayMask, idxSWU};
            rawTamb = data{dayMask, idxT2};

            % -----------------------------------------------------------------
            % Cell/string -> double
            % -----------------------------------------------------------------
            if iscell(rawGHI) || isstring(rawGHI)
                rawGHI = str2double(string(rawGHI));
            end

            if iscell(rawDIF) || isstring(rawDIF)
                rawDIF = str2double(string(rawDIF));
            end

            if iscell(rawSWU) || isstring(rawSWU)
                rawSWU = str2double(string(rawSWU));
            end

            if iscell(rawTamb) || isstring(rawTamb)
                rawTamb = str2double(string(rawTamb));
            end

            rawGHI  = double(rawGHI);
            rawDIF  = double(rawDIF);
            rawSWU  = double(rawSWU);
            rawTamb = double(rawTamb);

            % -----------------------------------------------------------------
            % D) Tisztitas es 1 perces szinkronizalas
            % -----------------------------------------------------------------
            rawGHI(rawGHI < 0) = 0;
            rawDIF(rawDIF < 0) = 0;
            rawSWU(rawSWU < 0) = 0;

            rawTamb(rawTamb < -50) = NaN;

            perfect1MinAxis = ...
                (currentDay : minutes(1) : currentDay + hours(23) + minutes(59))';

            % GHI
            valid = ~isnan(rawGHI);
            [uTime, uIdx] = unique(rawTime(valid));
            uVal = rawGHI(valid);
            uVal = uVal(uIdx);

            if length(uTime) >= 2
                cleanGHI = interp1(uTime, uVal, perfect1MinAxis, 'linear', 0);
            else
                cleanGHI = zeros(size(perfect1MinAxis));
            end

            % DIF
            valid = ~isnan(rawDIF);
            [uTime, uIdx] = unique(rawTime(valid));
            uVal = rawDIF(valid);
            uVal = uVal(uIdx);

            if length(uTime) >= 2
                cleanDIF = interp1(uTime, uVal, perfect1MinAxis, 'linear', 0);
            else
                cleanDIF = zeros(size(perfect1MinAxis));
            end

            % SWU
            valid = ~isnan(rawSWU);
            [uTime, uIdx] = unique(rawTime(valid));
            uVal = rawSWU(valid);
            uVal = uVal(uIdx);

            if length(uTime) >= 2
                cleanSWU = interp1(uTime, uVal, perfect1MinAxis, 'linear', 0);
            else
                cleanSWU = zeros(size(perfect1MinAxis));
            end

            % Tamb
            valid = ~isnan(rawTamb);
            [uTime, uIdx] = unique(rawTime(valid));
            uVal = rawTamb(valid);
            uVal = uVal(uIdx);

            if length(uTime) >= 2
                cleanTamb = interp1(uTime, uVal, perfect1MinAxis, 'nearest', 'extrap');
            else
                cleanTamb = 20 * ones(size(perfect1MinAxis));
            end

            cleanGHI(cleanGHI < 0) = 0;
            cleanDIF(cleanDIF < 0) = 0;
            cleanSWU(cleanSWU < 0) = 0;

            % -----------------------------------------------------------------
            % E) Downsampling megadott felbontasra
            % -----------------------------------------------------------------
            blockSize = targetStepMin;

            GHI_out  = mean(reshape(cleanGHI,  blockSize, []), 1);
            DIF_out  = mean(reshape(cleanDIF,  blockSize, []), 1);
            SWU_out  = mean(reshape(cleanSWU,  blockSize, []), 1);
            Tamb_out = mean(reshape(cleanTamb, blockSize, []), 1);

            tminVec = 0:targetStepMin:(1440 - targetStepMin);

            perfectTargetAxis = perfect1MinAxis(1:targetStepMin:end);

            % -----------------------------------------------------------------
            % F) Napallas szamitas a BSRN forrasnaphoz
            % -----------------------------------------------------------------
            [sunElev_vec, sunAzim_vec] = calculate_sun_position(perfectTargetAxis, lat, lon);

            % -----------------------------------------------------------------
            % G) Mentendo datum meghatarozasa
            % -----------------------------------------------------------------
            if matchToConsumption
                savedDayCounter = savedDayCounter + 1;
                targetDate = targetDates(savedDayCounter);

                [saveYear, saveMonth, saveDay] = ymd(targetDate);
            else
                savedDayCounter = savedDayCounter + 1;

                [saveYear, saveMonth, saveDay] = ymd(currentDay);
            end

            % -----------------------------------------------------------------
            % H) ResultBuffer generalas
            % -----------------------------------------------------------------
            create_daily_production_buffer(P_stc, saveYear, saveMonth, saveDay, tminVec, ...
                GHI_out, DIF_out, SWU_out, Tamb_out, ...
                sunElev_vec, sunAzim_vec, outputFolderPath);

            if matchToConsumption && (mod(savedDayCounter, 50) == 0 || savedDayCounter == nTargetDays)
                fprintf('Szinkronizalt napok mentve: %d / %d\n', savedDayCounter, nTargetDays);
            end
        end
    end

    if matchToConsumption && savedDayCounter < nTargetDays
        warning('Csak %d napot sikerult menteni a kert %d fogyasztasi napbol.', savedDayCounter, nTargetDays);
    end

    fprintf('\nAz osszes fajl feldolgozasa es a napi strukturak mentese befejezodott.\n');
    fprintf('Osszes mentett nap: %d\n', savedDayCounter);
end


function targetDates = local_get_consumption_dates(consumptionFolderPath)
% LOCAL_GET_CONSUMPTION_DATES
%
% Beolvassa es idorendbe rendezi a fogyasztasi napi fajlok datumait.

    assert(isfolder(consumptionFolderPath), ...
        'Hiba: A fogyasztasi mappa nem letezik: %s', consumptionFolderPath);

    consumptionFiles = dir(fullfile(consumptionFolderPath, 'consumption_ORIG_*.mat'));

    if isempty(consumptionFiles)
        error('Nem talaltam consumption_ORIG_*.mat fajlokat itt: %s', consumptionFolderPath);
    end

    targetDates = NaT(numel(consumptionFiles), 1);

    for i = 1:numel(consumptionFiles)
        filePath = fullfile(consumptionFiles(i).folder, consumptionFiles(i).name);
        targetDates(i) = local_get_date_from_consumption_file(filePath, consumptionFiles(i).name);
    end

    targetDates = sort(targetDates);

    [targetDates, ia] = unique(targetDates, 'stable');

    if numel(ia) < numel(consumptionFiles)
        warning('Duplikalt fogyasztasi datumokat talaltam. Csak egy peldanyt hasznalok datumonkent.');
    end
end


function targetDate = local_get_date_from_consumption_file(filePath, fileName)

    S = load(filePath);

    if isfield(S, 'consumptionCache')
        C = S.consumptionCache;

        if isfield(C, 'date')
            targetDate = C.date;
            targetDate = local_fix_two_digit_year(targetDate);
            return;
        end

        if isfield(C, 'dateString')
            targetDate = datetime(C.dateString, 'InputFormat', 'yyyy.MM.dd');
            targetDate = local_fix_two_digit_year(targetDate);
            return;
        end
    end

    tok = regexp(fileName, '(\d{4})_(\d{2})_(\d{2})', 'tokens', 'once');

    if isempty(tok)
        error('Nem sikerult datumot kinyerni a fogyasztasi fajlbol: %s', fileName);
    end

    y = str2double(tok{1});
    m = str2double(tok{2});
    d = str2double(tok{3});

    if y < 100
        y = y + 2000;
    end

    targetDate = datetime(y, m, d);
end


function dt = local_fix_two_digit_year(dt)

    y = year(dt);

    if y < 100
        dt = dt + calyears(2000);
    end
end


function tf = local_same_month_day(sourceDate, targetDate)
% LOCAL_SAME_MONTH_DAY
%
% Igazat ad vissza, ha ket datum honap-nap szerint egyezik.
% Az evet szandekosan nem vizsgalja.
%
% Pelda:
%   sourceDate = 2024-01-01
%   targetDate = 2011-01-01
%   -> true

    tf = month(sourceDate) == month(targetDate) && ...
         day(sourceDate, 'dayofmonth') == day(targetDate, 'dayofmonth');
end


function create_daily_production_buffer(P_stc, year, month, day, tminVec, GHI_vec, DIF_vec, SWU_vec, Tamb_vec, sunElev_vec, sunAzim_vec, savePath)
% CREATE_DAILY_PRODUCTION_BUFFER
%
% Legeneralja a napi termelesi matrixot minden orientaciora.
% A formatum megegyezik a korabbi resultBuffer formatummal.

    tiltsX = 0:1:40;
    tiltsZ = 0:5:355;

    fileName = sprintf('resultBuffer_ORIG_%04d_%02d_%02d.mat', year, month, day);
    fullFilePath = fullfile(savePath, fileName);

    timeDayStr = sprintf('%04d.%02d.%02d', year, month, day);

    numComb = length(tiltsX) * length(tiltsZ);

    resultsTable = table('Size', [numComb, 3], ...
        'VariableTypes', {'double', 'double', 'cell'}, ...
        'VariableNames', {'tiltX', 'tiltZ', 'tPDC'});

    rowIdx = 1;

    for tx = tiltsX
        for tz = tiltsZ

            P_dc_daily = pv_module_model( ...
                P_stc, ...
                tminVec, ...
                GHI_vec, ...
                DIF_vec, ...
                SWU_vec, ...
                Tamb_vec, ...
                sunElev_vec, ...
                sunAzim_vec, ...
                tx, ...
                tz);

            resultsTable.tiltX(rowIdx) = tx;
            resultsTable.tiltZ(rowIdx) = tz;
            resultsTable.tPDC{rowIdx}  = P_dc_daily;

            rowIdx = rowIdx + 1;
        end
    end

    resultBuffer = struct();

    resultBuffer.projectName = 'PV_PRODUCTION_VALIDATED_BSRN_BUDAPEST';
    resultBuffer.timeDay = timeDayStr;
    resultBuffer.timeVectorMin = tminVec;

    if numel(tminVec) >= 2
        resultBuffer.timeStepMin = tminVec(2) - tminVec(1);
    else
        resultBuffer.timeStepMin = NaN;
    end

    resultBuffer.timeIdx = length(tminVec);

    resultBuffer.sunPathData = struct( ...
        'elevation', sunElev_vec, ...
        'azimuth', sunAzim_vec);

    resultBuffer.irradiationData = struct( ...
        'GHI', ...
        GHI_vec, ...
        'DIF', ...
        DIF_vec, ...
        'ALBEDO', ...
        SWU_vec);

    resultBuffer.temperatureData = struct( ...
        'Tamb', Tamb_vec);

    resultBuffer.windSpeedData = struct();

    resultBuffer.results = resultsTable;

    if exist(fullFilePath, 'file')
        fprintf('Fajl mar letezik (%s), teljes feluliras...\n', fileName);
        delete(fullFilePath);
    end

    save(fullFilePath, 'resultBuffer');

    % fprintf('Sikeres mentes: %s\n', fullFilePath);
end


function [elevation, azimuth] = calculate_sun_position(datetimeVec, lat, lon)
% CALCULATE_SUN_POSITION
%
% Gyors es robusztus napallas kalkulator.
% datetimeVec: UTC idobelyegek
% Visszateresi ertekek fokban:
%   elevation
%   azimuth, ahol 0 = Eszak, 180 = Del

    [h, mn, s] = hms(datetimeVec);

    dayOfYear = day(datetimeVec, 'dayofyear');

    hour_utc = h + mn/60 + s/3600;

    B = 2 * pi * (dayOfYear - 1) / 365;

    eqtime = 229.18 * ...
        (0.000075 + ...
         0.001868 * cos(B) - ...
         0.032077 * sin(B) - ...
         0.014615 * cos(2*B) - ...
         0.040849 * sin(2*B));

    declination = ...
        0.006918 - ...
        0.399912 * cos(B) + ...
        0.070257 * sin(B) - ...
        0.006758 * cos(2*B) + ...
        0.000907 * sin(2*B) - ...
        0.002697 * cos(3*B) + ...
        0.00148  * sin(3*B);

    declination = rad2deg(declination);

    time_offset = eqtime + 4 * lon;
    tst = hour_utc * 60 + time_offset;

    hra = tst / 4 - 180;

    sin_elev = sind(declination) .* sind(lat) + ...
               cosd(declination) .* cosd(lat) .* cosd(hra);

    elevation = asind(sin_elev);

    cos_azim = ...
        (sind(declination) .* cosd(lat) - ...
         cosd(declination) .* sind(lat) .* cosd(hra)) ./ cosd(elevation);

    cos_azim = max(-1, min(1, cos_azim));

    azimuth = acosd(cos_azim);

    idx = hra > 0;
    azimuth(idx) = 360 - azimuth(idx);

    elevation = elevation(:).';
    azimuth = azimuth(:).';
end