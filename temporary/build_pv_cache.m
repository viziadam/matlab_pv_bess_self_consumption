function PV = build_pv_cache(tiltX, tiltZ, Pdc_kWp, Ppan_kWp)
    % BUILD_PV_CACHE - PV adatok dinamikus kinyerése és gyorsítótárazása
    % Csak a teljes, 365 napos éveket dolgozza fel, a szökőnapokat (Feb 29) szűri.
    % 
    % Bemenetek:
    %   tiltX   : Dőlésszög (pl. 10)
    %   tiltZ   : Tájolás (pl. [90, 270] Kelet-Nyugat esetén)
    %   Pdc_kWp : A tájolásokhoz tartozó beépített kapacitás [kWp] (pl. [274, 274])
    
    persistent PV_MAP
    
    % Gyorsítótár inicializálása
    if isempty(PV_MAP)
        PV_MAP = containers.Map('KeyType', 'char', 'ValueType', 'any');
    end
    
    % Egyedi kulcs generálása a bemenetekből
    cacheKey = sprintf('X%s_Z%s_P%s', mat2str(tiltX), mat2str(tiltZ), mat2str(Pdc_kWp));
    
    if PV_MAP.isKey(cacheKey)
        fprintf('PV adatok betöltve a memóriából: %s\n', cacheKey);
        PV = PV_MAP(cacheKey);
        return;
    end
    
    fprintf('PV adatok beolvasása a fájlokból: %s\n', cacheKey);
    
    % --- MAPPA AUTOMATIKUS KERESÉSE ---
    thisDir = fileparts(mfilename('fullpath'));
    pvDir = fullfile(thisDir, 'production');
    
    files = dir(fullfile(pvDir, '*.mat'));
    nF = numel(files);
    if nF == 0, error('Hiba: Nem találhatók .mat fájlok a %s mappában!', pvDir); end
    
    % =========================================================================
    % --- DÁTUMOK KINYERÉSE ÉS CSONKA ÉVEK (pl. 2019) KISZŰRÉSE ---
    % =========================================================================
    fprintf('Dátumok ellenőrzése és csonka évek kiszűrése...\n');
    dates = zeros(nF, 3);
    
    % Próbáljuk a fájlnévből kinyerni (gyorsabb)
    parseDate = @(fname) str2double(regexp(fname, '(\d{4})[._-](\d{2})[._-](\d{2})', 'tokens', 'once'));
    
    for i = 1:nF
        tmp = parseDate(files(i).name);
        if ~isempty(tmp)
            dates(i,:) = tmp;
        else
            % Fallback: ha nincs a fájlnévben, gyorsan belenézünk a fájlba
            S_temp = load(fullfile(pvDir, files(i).name), 'resultBuffer');
            if isfield(S_temp, 'resultBuffer') && isfield(S_temp.resultBuffer, 'timeDay')
                dStr = S_temp.resultBuffer.timeDay; % pl. '2019.06.03'
                dates(i,:) = str2double(strsplit(dStr, '.'));
            end
        end
    end
    
    % 1. Szökőnapok (Február 29.) törlése a Standard 365 napos naptárhoz
    validDays = ~(dates(:,2) == 2 & dates(:,3) == 29);
    files = files(validDays);
    dates = dates(validDays, :);
    
    % 2. Csak a teljes (365 napos) évek megtartása
    years = dates(:,1);
    uniqueYears = unique(years);
    validYears = [];
    
    for y = uniqueYears'
        daysInYear = sum(years == y);
        if daysInYear == 365
            validYears(end+1) = y;
        else
            fprintf('  -> Csonka év eldobva: %d (csak %d napot tartalmaz)\n', y, daysInYear);
        end
    end
    
    if isempty(validYears)
        error('Hiba: A szűrés után nem maradt egyetlen teljes (365 napos) év sem a mappában!');
    end
    
    % Fájlok szűrése csak a teljes évekre
    isFullYear = ismember(years, validYears);
    files = files(isFullYear);
    nF = numel(files);
    
    fprintf('Szűrés kész: %d teljes év (%d nap) kerül a memóriába.\n', numel(validYears), nF);
    % =========================================================================

    % --- ELŐALLOKÁLÁS A KÉRT FORMÁTUMRA ---
    PV(nF) = struct('Ppv', [], 'timeMinVec', [], 'dt_h', [], 'timeDay', '');
    
    for k = 1:nF
        fPath = fullfile(pvDir, files(k).name);
        S = load(fPath);
        
        if ~isfield(S, 'resultBuffer'), continue; end
        rb = S.resultBuffer;
        
        timeMinVec = rb.timeVectorMin;
        resTable = rb.results; % A 32x3-as MATLAB Table
        
        Ppv_total = zeros(1, length(timeMinVec));
        
        % Végigmegyünk a kért dőlés/tájolás párosokon
        for c = 1:length(tiltZ)
            if isscalar(tiltX), cX = tiltX; else, cX = tiltX(c); end
            cZ = tiltZ(c);
            cPower = Pdc_kWp(c);
            
            % Keresés a Table-ben
            rowIdx = find(resTable.tiltX == cX & resTable.tiltZ == cZ);
            
            if isempty(rowIdx)
                warning('Kihagyva: tiltX=%d, tiltZ=%d nem található a(z) %s fájlban.', cX, cZ, files(k).name);
                continue;
            end
            
            % Nyers adat kinyerése és felskálázása
            % Ellenőrizzük, hogy cellatömb-e, és kicsomagoljuk {} segítségével
            if iscell(resTable.tPDC)
                tPDC_raw = resTable.tPDC{rowIdx};
            else
                tPDC_raw = resTable.tPDC(rowIdx, :);
            end
            
            Ppv_total = Ppv_total + (tPDC_raw .* cPower / Ppan_kWp);
        end
        
        % --- KIMENETI MEZŐK KITÖLTÉSE PONTOSAN A KÉRT FORMÁBAN ---
        PV(k).Ppv        = Ppv_total;           % sorvektor [kW]
        PV(k).timeMinVec = timeMinVec;          % sorvektor
        PV(k).dt_h       = rb.timeStepMin / 60; % skalár
        PV(k).timeDay    = rb.timeDay;          
    end
    
    % Mentés a RAM-ba
    PV_MAP(cacheKey) = PV;
end