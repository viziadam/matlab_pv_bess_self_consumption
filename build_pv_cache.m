
function PV = build_pv_cache(tiltX, tiltZ, Pdc_kWp, modulePower_kWp)
% BUILD_PV_CACHE
%
% PV termelesi cache letrehozasa megadott tajolasokra.
%
% Fontos:
%   - NEM kovetel teljes 365 napos eveket
%   - NEM dobja el a csonka eveket
%   - minden olyan napot betolt, amelyhez ertelmezheto datum tartozik
%   - a datum alapjan rendezi a kimenetet
%
% Bemenet:
%   tiltX            : doles [deg], skalar vagy vektor
%   tiltZ            : tajolas [deg], skalar vagy vektor
%   Pdc_kWp          : az egyes tajolasokhoz tartozo DC kapacitas [kWp]
%   modulePower_kWp  : egy modul nevleges teljesitmenye [kWp]
%
% Kimenet:
%   PV(k).Ppv        : PV teljesitmeny [kW], 1 nap
%   PV(k).timeMinVec : idotengely [min]
%   PV(k).dt_h       : idolepes [h]
%   PV(k).timeDay    : datum string
%   PV(k).date       : datetime datum

    persistent PV_MAP

    if nargin < 4 || isempty(modulePower_kWp)
        modulePower_kWp = 0.5;
    end

    thisDir = fileparts(mfilename('fullpath'));
    pvDir = fullfile(thisDir, 'production');

    if isempty(PV_MAP)
        PV_MAP = containers.Map('KeyType', 'char', 'ValueType', 'any');
    end

    if isscalar(Pdc_kWp) && numel(tiltZ) > 1
        Pdc_kWp = repmat(Pdc_kWp / numel(tiltZ), 1, numel(tiltZ));
    end

    if numel(Pdc_kWp) ~= numel(tiltZ)
        error('Pdc_kWp length must match tiltZ length, or Pdc_kWp must be scalar.');
    end

    cacheKey = sprintf('X%s_Z%s_P%s_MOD%.6f_DIR%s', ...
        mat2str(tiltX), mat2str(tiltZ), mat2str(Pdc_kWp), modulePower_kWp, pvDir);

    if PV_MAP.isKey(cacheKey)
        fprintf('PV reference data loaded from RAM cache.\n');
        PV = PV_MAP(cacheKey);
        return;
    end

    fprintf('Reading PV reference data from production files...\n');

    files = dir(fullfile(pvDir, '*.mat'));

    if isempty(files)
        error('No .mat files found in PV folder: %s', pvDir);
    end

    nF = numel(files);
    dates = nan(nF, 3);

    for i = 1:nF

        dates(i, :) = local_parse_date_from_filename(files(i).name);

        if any(isnan(dates(i, :)))
            S = load(fullfile(pvDir, files(i).name), 'resultBuffer');

            if isfield(S, 'resultBuffer') && isfield(S.resultBuffer, 'timeDay')
                dates(i, :) = local_parse_date_from_string(S.resultBuffer.timeDay);
            end
        end
    end

    validDate = ~isnan(dates(:,1));
    files = files(validDate);
    dates = dates(validDate, :);

    if isempty(files)
        error('No PV files with valid dates were found in folder: %s', pvDir);
    end

    dateSerial = datenum(dates(:,1), dates(:,2), dates(:,3));
    [~, order] = sort(dateSerial);

    files = files(order);
    dates = dates(order, :);

    nF = numel(files);

    PV(nF) = struct( ...
        'Ppv', [], ...
        'timeMinVec', [], ...
        'dt_h', [], ...
        'timeDay', '', ...
        'date', NaT);

    for k = 1:nF

        fPath = fullfile(pvDir, files(k).name);
        S = load(fPath);

        if ~isfield(S, 'resultBuffer')
            error('Missing resultBuffer in file: %s', files(k).name);
        end

        rb = S.resultBuffer;

        timeMinVec = rb.timeVectorMin;
        resTable = rb.results;

        Ppv_total_kW = zeros(1, numel(timeMinVec));

        for c = 1:numel(tiltZ)

            if isscalar(tiltX)
                cX = tiltX;
            else
                cX = tiltX(c);
            end

            cZ = tiltZ(c);
            cPower_kWp = Pdc_kWp(c);

            rowIdx = find(resTable.tiltX == cX & resTable.tiltZ == cZ, 1);

            if isempty(rowIdx)
                warning('PV orientation not found: tiltX=%g, tiltZ=%g in %s', ...
                    cX, cZ, files(k).name);
                continue;
            end

            if iscell(resTable.tPDC)
                tPDC_raw = resTable.tPDC{rowIdx};
            else
                tPDC_raw = resTable.tPDC(rowIdx, :);
            end

            tPDC_raw = double(tPDC_raw(:).');

            % Feltetelezes:
            %   tPDC_raw [W] egy modulra.
            %   Atvaltjuk kW-ra, majd skalazzuk a megadott kWp reszre.
            Ppv_orientation_kW = (tPDC_raw / 1000) * (cPower_kWp / modulePower_kWp);

            Ppv_total_kW = Ppv_total_kW + Ppv_orientation_kW;
        end

        PV(k).Ppv = Ppv_total_kW;
        PV(k).timeMinVec = timeMinVec;
        PV(k).dt_h = rb.timeStepMin / 60;
        PV(k).date = datetime(dates(k,1), dates(k,2), dates(k,3));

        if isfield(rb, 'timeDay')
            PV(k).timeDay = rb.timeDay;
        else
            PV(k).timeDay = sprintf('%04d.%02d.%02d', dates(k,1), dates(k,2), dates(k,3));
        end
    end

    PV_MAP(cacheKey) = PV;

    fprintf('PV reference cache ready: %d days, %.3f kWp reference.\n', ...
        numel(PV), sum(Pdc_kWp));
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