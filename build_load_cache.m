function Load = build_load_cache()
% BUILD_LOAD_CACHE
%
% Csak fogyasztasi adatok betoltese.
% Energiaarak nincsenek.
%
% Fontos:
%   - NEM kovetel teljes 365 napos eveket
%   - NEM dobja el a csonka eveket
%   - minden olyan napot betolt, amelyhez ertelmezheto datum tartozik
%   - a datum alapjan rendezi a kimenetet
%
% Kimenet:
%   Load(k).P_load_kW
%   Load(k).timeMinVec
%   Load(k).dt_h
%   Load(k).timeDay
%   Load(k).date

    persistent cachedLoad cachedLoadDir

    thisDir = fileparts(mfilename('fullpath'));
    loadDir = fullfile(thisDir, 'consumption');

    if ~isempty(cachedLoad) && strcmp(cachedLoadDir, loadDir)
        fprintf('Load data loaded from RAM cache.\n');
        Load = cachedLoad;
        return;
    end

    fprintf('Reading load data from consumption files...\n');

    files = dir(fullfile(loadDir, '*.mat'));

    if isempty(files)
        error('No .mat files found in load folder: %s', loadDir);
    end

    nF = numel(files);
    dates = nan(nF, 3);

    for i = 1:nF

        dates(i, :) = local_parse_date_from_filename(files(i).name);

        if any(isnan(dates(i, :)))
            S = load(fullfile(loadDir, files(i).name));

            if isfield(S, 'consumptionCache') && isfield(S.consumptionCache, 'dateString')
                dates(i, :) = local_parse_date_from_string(S.consumptionCache.dateString);
            end
        end
    end

    validDate = ~isnan(dates(:,1));
    files = files(validDate);
    dates = dates(validDate, :);

    if isempty(files)
        error('No load files with valid dates were found in folder: %s', loadDir);
    end

    dateSerial = datenum(dates(:,1), dates(:,2), dates(:,3));
    [~, order] = sort(dateSerial);

    files = files(order);
    dates = dates(order, :);

    nF = numel(files);

    Load(nF) = struct( ...
        'P_load_kW', [], ...
        'timeMinVec', [], ...
        'dt_h', [], ...
        'timeDay', '', ...
        'date', NaT);

    for k = 1:nF

        fPath = fullfile(loadDir, files(k).name);
        S = load(fPath);

        [P_load_kW, timeMinVec, dt_h] = local_extract_load_day(S);

        Load(k).P_load_kW = P_load_kW(:).';
        Load(k).timeMinVec = timeMinVec(:).';
        Load(k).dt_h = dt_h;
        Load(k).timeDay = sprintf('%04d.%02d.%02d', dates(k,1), dates(k,2), dates(k,3));
        Load(k).date = datetime(dates(k,1), dates(k,2), dates(k,3));
    end

    cachedLoad = Load;
    cachedLoadDir = loadDir;

    fprintf('Load cache ready: %d days.\n', numel(Load));
end


function [P_load_kW, timeMinVec, dt_h] = local_extract_load_day(S)

    if ~isfield(S, 'consumptionCache')
        error('Missing consumptionCache in load file.');
    end

    c = S.consumptionCache;

    if isfield(c, 'powerTotal_W')
        P_load_kW = double(c.powerTotal_W(:).') / 1000;
    elseif isfield(c, 'P_load_kW')
        P_load_kW = double(c.P_load_kW(:).');
    elseif isfield(c, 'powerTotal_kW')
        P_load_kW = double(c.powerTotal_kW(:).');
    else
        error('Could not find load power field in consumptionCache.');
    end

    if isfield(c, 'timeMinAxis')
        timeMinVec = double(c.timeMinAxis(:).');
    elseif isfield(c, 'timeMinVec')
        timeMinVec = double(c.timeMinVec(:).');
    else
        nT = numel(P_load_kW);
        timeMinVec = linspace(0, 24*60, nT + 1);
        timeMinVec = timeMinVec(1:end-1);
    end

    if numel(timeMinVec) >= 2
        dt_h = (timeMinVec(2) - timeMinVec(1)) / 60;
    else
        dt_h = 24 / numel(P_load_kW);
    end
end


function dateParts = local_parse_date_from_filename(fileName)

    tok = regexp(fileName, '(\d{4})[._-](\d{2})[._-](\d{2})', 'tokens', 'once');

    if isempty(tok)
        dateParts = [NaN NaN NaN];
    else
        dateParts = str2double(tok);
    end
end


function dateParts = local_parse_date_from_string(str)

    tok = regexp(char(str), '(\d{4})[._-](\d{2})[._-](\d{2})', 'tokens', 'once');

    if isempty(tok)
        dateParts = [NaN NaN NaN];
    else
        dateParts = str2double(tok);
    end
end