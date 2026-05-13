function [Load, Price] = build_load_price_cache()
    % BUILD_LOAD_PRICE_CACHE - Fogyasztás és Tőzsdei Árak szinkronizált betöltése
    % Garantálja a 365 napos éveket (Feb 29. kiszűrése), és az 1 éves tőzsdei 
    % árat "ráhurkolja" a több éves fogyasztási adatokra.
    
    persistent cachedLoad cachedPrice
    
    if ~isempty(cachedLoad)
        fprintf('Load és Price adatok betöltve a memóriából (RAM).\n');
        Load = cachedLoad; Price = cachedPrice;
        return;
    end
    
    fprintf('Load és Price adatok szinkronizálása a 365-napos virtuális évekre...\n');
    
    % --- MAPPÁK AUTOMATIKUS KERESÉSE ---
    thisDir = fileparts(mfilename('fullpath'));
    loadDir = fullfile(thisDir, 'consumption');
    priceDir = fullfile(thisDir, 'energy_prices');
    
    loadFiles = dir(fullfile(loadDir, '*.mat'));
    priceFiles = dir(fullfile(priceDir, '*.mat'));
    
    if isempty(loadFiles) || isempty(priceFiles)
        error('Hiba: Nem találhatók adatok a consumption vagy energy_prices mappában!');
    end
    
    % --- DÁTUMOK KINYERÉSE A FÁJLNEVEKBŐL ---
    % Reguláris kifejezés, ami megkeresi a YYYY.MM.DD vagy YYYY_MM_DD formátumot
    parseDate = @(fname) str2double(regexp(fname, '(\d{4})[._-](\d{2})[._-](\d{2})', 'tokens', 'once'));
    
    loadDates = nan(numel(loadFiles), 3);
    for i=1:numel(loadFiles)
        tmp = parseDate(loadFiles(i).name);
        if ~isempty(tmp), loadDates(i,:) = tmp; end
    end
    
    priceDates = nan(numel(priceFiles), 3);
    for i=1:numel(priceFiles)
        tmp = parseDate(priceFiles(i).name);
        if ~isempty(tmp), priceDates(i,:) = tmp; end
    end
    
    % --- SZÖKŐNAPOK (FEBRUÁR 29) KÍMÉLETLEN TÖRLÉSE ---
    validLoad = ~(loadDates(:,2) == 2 & loadDates(:,3) == 29);
    loadFiles = loadFiles(validLoad);
    loadDates = loadDates(validLoad, :);
    
    validPrice = ~(priceDates(:,2) == 2 & priceDates(:,3) == 29);
    priceFiles = priceFiles(validPrice);
    priceDates = priceDates(validPrice, :);
    
    % --- FOGYASZTÁSI ÉVEK AZONOSÍTÁSA ---
    yearsLoad = unique(loadDates(:,1));
    yearsLoad(isnan(yearsLoad)) = [];
    numYears = numel(yearsLoad); % Ez elvileg 5 lesz a te esetedben
    
    % --- STANDARD 365 NAPOS NAPTÁR GENERÁLÁSA ---
    standardMMDD = zeros(365, 2);
    idx = 1;
    for m = 1:12
        dMax = eomday(2019, m); % A 2019 nem szökőév, így február fixen 28 napos
        for d = 1:dMax
            standardMMDD(idx, 1) = m;
            standardMMDD(idx, 2) = d;
            idx = idx + 1;
        end
    end
    
    % --- ELŐALLOKÁLÁS (Sebesség optimalizálás) ---
    totalDays = numYears * 365;
    Load(totalDays)  = struct('P_load_kW', []);
    Price(totalDays) = struct('buy_huf', [], 'sell_huf', []);
    
    % --- SZINKRONIZÁLT BETÖLTÉS ---
    globalIdx = 1;
    for y = 1:numYears
        curYear = yearsLoad(y); % A Fogyasztás aktuális éve (pl. 2018)
        
        for d = 1:365
            curM = standardMMDD(d, 1);
            curD = standardMMDD(d, 2);
            
            % 1. Megkeressük az adott napot a Fogyasztásnál (Év + Hónap + Nap alapján)
            lIdx = find(loadDates(:,1)==curYear & loadDates(:,2)==curM & loadDates(:,3)==curD, 1);
            
            % 2. Megkeressük az adott napot a Tőzsdénél (CSAK Hónap + Nap alapján, az év mindegy!)
            pIdx = find(priceDates(:,2)==curM & priceDates(:,3)==curD, 1);
            
            if isempty(lIdx) || isempty(pIdx)
                warning('Hiányzó adat a %d-%02d-%02d napon! 0-val töltjük fel.', curYear, curM, curD);
                Load(globalIdx).P_load_kW = zeros(1, 288);
                Price(globalIdx).buy_huf = zeros(1, 288);
                Price(globalIdx).sell_huf = zeros(1, 288);
                globalIdx = globalIdx + 1;
                continue;
            end
            
            % --- Tényleges fájl beolvasás ---
            lData = load(fullfile(loadDir, loadFiles(lIdx).name));
            prData = load(fullfile(priceDir, priceFiles(pIdx).name));
            
            % Betöltjük és kW-ra konvertáljuk a fogyasztást
            Load(globalIdx).P_load_kW = lData.consumptionCache.powerTotal_W / 1000;
            
            % Betöltjük az árakat (Feltételezve a cache belső mezőneveit)
            Price(globalIdx).buy_huf  = prData.priceCache.buyPrice_HUF;
            Price(globalIdx).sell_huf = prData.priceCache.sellPrice_HUF;
            
            globalIdx = globalIdx + 1;
        end
    end
    
    cachedLoad = Load; cachedPrice = Price;
    fprintf('Kész! %d év szinkronizálva (%d nap összesen).\n', numYears, totalDays);
end