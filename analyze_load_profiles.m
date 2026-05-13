function [analysisResult, cfg] = analyze_load_profiles(cfg)
% ANALYZE_LOAD_PROFILES
%
% Grid-connected ipari PV+BESS onfogyasztas-novelesi esettanulmanyhoz
% fogyasztasi es PV-termelesi elozetes adatelemzest keszit.
%
% A fuggveny a teljes szimulacios konfiguraciot kapja bemenetkent:
%
%   cfg = create_configurations(basePath);
%   [analysisResult, cfg] = analyze_load_profiles(cfg);
%
% A fuggveny:
%   1) Beolvassa a napi consumption es production .mat fajlokat.
%   2) Datum szerint parositja oket.
%   3) Kiszamolja a fogyasztasi/PV illeszkedesi mutatokat.
%   4) Elkesziti a 4 fo abrazolast:
%       - havi atlagos napon beluli fogyasztasi gorbek
%       - havi energiafelhasznalas vs. PV termeles
%       - het napjai szerinti fogyasztasi gorbek
%       - napi fogyasztasi csucsteljesitmeny hisztogram
%   5) Osszegyujti a fogyasztasi es PV teljesitmenymintakat.
%   6) Kiszamolja a napi fogyasztasi csucsteljesitmenyeket.
%   7) A NAPI FOGYASZTASI CSUCSOK percentilisei alapjan meghatarozza
%      a javasolt invertermereteket.
%   8) A javasolt invertermereteket visszairja:
%       cfg.candidates.P_inv_kW_vec
%       cfg.inverter.P_inv_kW
%
% Fontos:
%   Az invertermeretezes NEM az osszes idolepes teljesitmenymintajabol,
%   hanem a napi fogyasztasi csucsteljesitmenyekbol tortenik:
%
%       dailyLoadPeak_kW(d) = max(loadMatrix_kW(d, :))

    if nargin < 1
        error('A teljes szimulacios cfg bemenet szukseges.');
    end

    % ---------------------------------------------------------------------
    % 0) CFG elokeszites elemzeshez
    % ---------------------------------------------------------------------
    cfg = local_apply_analysis_defaults(cfg);

    consumptionFolderPath = cfg.paths.consumption;
    productionFolderPath  = cfg.paths.production;
    savePath              = cfg.paths.analysis;
    figurePath            = cfg.paths.analysisFigures;

    fprintf('Projekt mappa: %s\n', cfg.paths.base);
    fprintf('Fogyasztasi adatok: %s\n', consumptionFolderPath);
    fprintf('Termelesi adatok: %s\n', productionFolderPath);
    fprintf('Elemzes mentese: %s\n', savePath);
    fprintf('Abrak mentese: %s\n\n', figurePath);

    assert(isfolder(consumptionFolderPath), ...
        'Hiba: nem letezik a fogyasztasi mappa: %s', consumptionFolderPath);

    assert(isfolder(productionFolderPath), ...
        'Hiba: nem letezik a termelesi mappa: %s', productionFolderPath);

    if ~exist(savePath, 'dir')
        mkdir(savePath);
    end

    if ~exist(figurePath, 'dir')
        mkdir(figurePath);
    end

    % ---------------------------------------------------------------------
    % 1) Konfiguracios parameterek
    % ---------------------------------------------------------------------
    tiltX = cfg.pv.tiltX;
    tiltZ = cfg.pv.tiltZ;

    pvForAnalysis_kW = cfg.analysis.PV_kW_forAnalysis;
    makePlots = cfg.analysis.makePlots;

    fprintf('Valasztott PV orientacio: tiltX = %.1f deg, tiltZ = %.1f deg\n', tiltX, tiltZ);
    fprintf('Elemzesi PV teljesitmeny: %.1f kWp\n', pvForAnalysis_kW);
    fprintf('Invertermeretezes alapja: napi fogyasztasi csucsteljesitmenyek percentilisei\n\n');

    % ---------------------------------------------------------------------
    % 2) Fajlok beolvasasa es datum szerinti parositas
    % ---------------------------------------------------------------------
    cFiles = dir(fullfile(consumptionFolderPath, 'consumption_ORIG_*.mat'));
    pFiles = dir(fullfile(productionFolderPath, 'resultBuffer_ORIG_*.mat'));

    if isempty(cFiles)
        error('Nem talaltam consumption_ORIG_*.mat fajlokat itt: %s', consumptionFolderPath);
    end

    if isempty(pFiles)
        error('Nem talaltam resultBuffer_ORIG_*.mat fajlokat itt: %s', productionFolderPath);
    end

    cDates = NaT(numel(cFiles), 1);
    pDates = NaT(numel(pFiles), 1);

    for i = 1:numel(cFiles)
        cDates(i) = local_date_from_file(cFiles(i).name);
    end

    for i = 1:numel(pFiles)
        pDates(i) = local_date_from_file(pFiles(i).name);
    end

    [commonDates, ic, ip] = intersect(cDates, pDates);

    if isempty(commonDates)
        error('Nincs kozos datum a fogyasztasi es PV fajlok kozott.');
    end

    [commonDates, order] = sort(commonDates);
    ic = ic(order);
    ip = ip(order);

    nDays = numel(commonDates);

    fprintf('Kozos napok szama: %d\n\n', nDays);

    % ---------------------------------------------------------------------
    % 3) Elso nap alapjan idofelbontas es meretek
    % ---------------------------------------------------------------------
    C0 = load(fullfile(cFiles(ic(1)).folder, cFiles(ic(1)).name));
    load0_W = double(C0.consumptionCache.powerTotal_W(:).');

    P0 = load(fullfile(pFiles(ip(1)).folder, pFiles(ip(1)).name));
    pv0_W = local_get_pv_from_resultbuffer(P0.resultBuffer, tiltX, tiltZ);
    pv0_W = double(pv0_W(:).') * pvForAnalysis_kW;

    nT = min(numel(load0_W), numel(pv0_W));

    if isfield(C0.consumptionCache, 'dt_h')
        dt_h = C0.consumptionCache.dt_h;
    else
        dt_h = 24 / nT;
    end

    time_h = (0:nT-1) * dt_h;

    loadMatrix_kW = zeros(nDays, nT);
    pvMatrix_kW   = zeros(nDays, nT);

    % ---------------------------------------------------------------------
    % 4) Napi adatok matrixba rendezese
    % ---------------------------------------------------------------------
    for d = 1:nDays

        C = load(fullfile(cFiles(ic(d)).folder, cFiles(ic(d)).name));
        P = load(fullfile(pFiles(ip(d)).folder, pFiles(ip(d)).name));

        load_W = double(C.consumptionCache.powerTotal_W(:).');

        pv_W = local_get_pv_from_resultbuffer(P.resultBuffer, tiltX, tiltZ);
        pv_W = double(pv_W(:).') * pvForAnalysis_kW;

        nUse = min([numel(load_W), numel(pv_W), nT]);

        loadMatrix_kW(d, 1:nUse) = load_W(1:nUse) / 1000;
        pvMatrix_kW(d, 1:nUse)   = pv_W(1:nUse) / 1000;
    end

    % ---------------------------------------------------------------------
    % 5) Napi fogyasztasi mutatok
    % ---------------------------------------------------------------------
    dailyLoadEnergy_kWh = sum(loadMatrix_kW, 2) * dt_h;
    dailyLoadPeak_kW    = max(loadMatrix_kW, [], 2);
    dailyLoadMean_kW    = mean(loadMatrix_kW, 2);
    dailyLoadMin_kW     = min(loadMatrix_kW, [], 2);

    [~, peakIdx] = max(loadMatrix_kW, [], 2);
    dailyLoadPeakHour = time_h(peakIdx).';

    % ---------------------------------------------------------------------
    % 6) PV es fogyasztas illeszkedese BESS nelkul
    % ---------------------------------------------------------------------
    directPV_kW    = min(loadMatrix_kW, pvMatrix_kW);
    pvSurplus_kW   = max(pvMatrix_kW - loadMatrix_kW, 0);
    loadDeficit_kW = max(loadMatrix_kW - pvMatrix_kW, 0);

    dailyPVEnergy_kWh    = sum(pvMatrix_kW, 2) * dt_h;
    dailyDirectPVUse_kWh = sum(directPV_kW, 2) * dt_h;
    dailyPVSurplus_kWh   = sum(pvSurplus_kW, 2) * dt_h;
    dailyLoadDeficit_kWh = sum(loadDeficit_kW, 2) * dt_h;

    selfSufficiency_noBESS = dailyDirectPVUse_kWh ./ max(dailyLoadEnergy_kWh, eps);
    selfConsumption_noBESS = dailyDirectPVUse_kWh ./ max(dailyPVEnergy_kWh, eps);
    pvLoadEnergyRatio      = dailyPVEnergy_kWh ./ max(dailyLoadEnergy_kWh, eps);

    [~, pvPeakIdx] = max(pvMatrix_kW, [], 2);
    dailyPVPeakHour = time_h(pvPeakIdx).';

    peakTimeDifference_h = dailyLoadPeakHour - dailyPVPeakHour;

    dailyCorrelation = NaN(nDays, 1);

    for d = 1:nDays
        x = loadMatrix_kW(d, :).';
        y = pvMatrix_kW(d, :).';

        if std(x) >= 1e-9 && std(y) >= 1e-9
            R = corrcoef(x, y);
            dailyCorrelation(d) = R(1, 2);
        end
    end

    % ---------------------------------------------------------------------
    % 7) Datumcsoportositas
    % ---------------------------------------------------------------------
    weekdayNum = weekday(commonDates);
    isWeekend = weekdayNum == 1 | weekdayNum == 7;

    monthNum = month(commonDates);

    seasonName = strings(nDays, 1);

    for d = 1:nDays
        seasonName(d) = local_season_name(monthNum(d));
    end

    % ---------------------------------------------------------------------
    % 8) Napi eredmenytabla
    % ---------------------------------------------------------------------
    dailyTable = table();

    dailyTable.Date = commonDates;
    dailyTable.WeekdayNumber = weekdayNum;
    dailyTable.IsWeekend = isWeekend;
    dailyTable.Month = monthNum;
    dailyTable.Season = seasonName;

    dailyTable.LoadEnergy_kWh = dailyLoadEnergy_kWh;
    dailyTable.LoadPeak_kW = dailyLoadPeak_kW;
    dailyTable.LoadMean_kW = dailyLoadMean_kW;
    dailyTable.LoadMin_kW = dailyLoadMin_kW;
    dailyTable.LoadPeakHour = dailyLoadPeakHour;

    dailyTable.PVEnergy_kWh = dailyPVEnergy_kWh;
    dailyTable.PVPeakHour = dailyPVPeakHour;
    dailyTable.DirectPVUse_kWh = dailyDirectPVUse_kWh;
    dailyTable.PVSurplus_kWh = dailyPVSurplus_kWh;
    dailyTable.LoadDeficitWithoutStorage_kWh = dailyLoadDeficit_kWh;

    dailyTable.SelfSufficiency_noBESS = selfSufficiency_noBESS;
    dailyTable.SelfConsumption_noBESS = selfConsumption_noBESS;
    dailyTable.PVLoadEnergyRatio = pvLoadEnergyRatio;
    dailyTable.PeakTimeDifference_h = peakTimeDifference_h;
    dailyTable.LoadPVCorrelation = dailyCorrelation;

    % ---------------------------------------------------------------------
    % 9) Havi profilok es havi energiatabla
    % ---------------------------------------------------------------------
    monthNamesHU = ["Január", "Február", "Március", "Április", "Május", "Június", ...
                    "Július", "Augusztus", "Szeptember", "Október", "November", "December"];

    monthlyProfiles = struct();
    monthlyProfiles.time_h = time_h;
    monthlyProfiles.monthNames = monthNamesHU;
    monthlyProfiles.loadMean_kW = NaN(12, nT);
    monthlyProfiles.pvMean_kW = NaN(12, nT);
    monthlyProfiles.directPVMean_kW = NaN(12, nT);
    monthlyProfiles.surplusMean_kW = NaN(12, nT);
    monthlyProfiles.deficitMean_kW = NaN(12, nT);
    monthlyProfiles.nDays = zeros(12, 1);

    monthlyLoadEnergy_kWh = zeros(12, 1);
    monthlyPVEnergy_kWh = zeros(12, 1);
    monthlyDirectPVUse_kWh = zeros(12, 1);
    monthlyPVSurplus_kWh = zeros(12, 1);
    monthlyLoadDeficit_kWh = zeros(12, 1);

    for m = 1:12

        mask = monthNum == m;
        monthlyProfiles.nDays(m) = sum(mask);

        if any(mask)
            monthlyProfiles.loadMean_kW(m, :) = mean(loadMatrix_kW(mask, :), 1, 'omitnan');
            monthlyProfiles.pvMean_kW(m, :) = mean(pvMatrix_kW(mask, :), 1, 'omitnan');
            monthlyProfiles.directPVMean_kW(m, :) = mean(directPV_kW(mask, :), 1, 'omitnan');
            monthlyProfiles.surplusMean_kW(m, :) = mean(pvSurplus_kW(mask, :), 1, 'omitnan');
            monthlyProfiles.deficitMean_kW(m, :) = mean(loadDeficit_kW(mask, :), 1, 'omitnan');

            monthlyLoadEnergy_kWh(m) = sum(dailyLoadEnergy_kWh(mask));
            monthlyPVEnergy_kWh(m) = sum(dailyPVEnergy_kWh(mask));
            monthlyDirectPVUse_kWh(m) = sum(dailyDirectPVUse_kWh(mask));
            monthlyPVSurplus_kWh(m) = sum(dailyPVSurplus_kWh(mask));
            monthlyLoadDeficit_kWh(m) = sum(dailyLoadDeficit_kWh(mask));
        end
    end

    monthlyTable = table();

    monthlyTable.MonthNumber = (1:12).';
    monthlyTable.MonthName = monthNamesHU(:);
    monthlyTable.NDays = monthlyProfiles.nDays;
    monthlyTable.LoadEnergy_kWh = monthlyLoadEnergy_kWh;
    monthlyTable.PVEnergy_kWh = monthlyPVEnergy_kWh;
    monthlyTable.DirectPVUse_kWh = monthlyDirectPVUse_kWh;
    monthlyTable.PVSurplus_kWh = monthlyPVSurplus_kWh;
    monthlyTable.LoadDeficitWithoutStorage_kWh = monthlyLoadDeficit_kWh;
    monthlyTable.SelfSufficiency_noBESS = monthlyDirectPVUse_kWh ./ max(monthlyLoadEnergy_kWh, eps);
    monthlyTable.SelfConsumption_noBESS = monthlyDirectPVUse_kWh ./ max(monthlyPVEnergy_kWh, eps);

    % ---------------------------------------------------------------------
    % 10) Heti napok szerinti atlagprofilok
    % ---------------------------------------------------------------------
    weekdayOrder = [2 3 4 5 6 7 1];
    weekdayNamesHU = ["Hétfő", "Kedd", "Szerda", "Csütörtök", "Péntek", "Szombat", "Vasárnap"];

    weekdayProfiles = struct();
    weekdayProfiles.time_h = time_h;
    weekdayProfiles.weekdayNames = weekdayNamesHU;
    weekdayProfiles.loadMean_kW = NaN(7, nT);
    weekdayProfiles.pvMean_kW = NaN(7, nT);
    weekdayProfiles.nDays = zeros(7, 1);

    for i = 1:7

        mask = weekdayNum == weekdayOrder(i);
        weekdayProfiles.nDays(i) = sum(mask);

        if any(mask)
            weekdayProfiles.loadMean_kW(i, :) = mean(loadMatrix_kW(mask, :), 1, 'omitnan');
            weekdayProfiles.pvMean_kW(i, :) = mean(pvMatrix_kW(mask, :), 1, 'omitnan');
        end
    end

    % ---------------------------------------------------------------------
    % 11) Osszesites
    % ---------------------------------------------------------------------
    summary = struct();

    summary.nDays = nDays;
    summary.dt_h = dt_h;
    summary.time_h = time_h;

    summary.totalLoadEnergy_kWh = sum(dailyLoadEnergy_kWh);
    summary.totalPVEnergy_kWh = sum(dailyPVEnergy_kWh);
    summary.totalDirectPVUse_kWh = sum(dailyDirectPVUse_kWh);
    summary.totalPVSurplus_kWh = sum(dailyPVSurplus_kWh);
    summary.totalLoadDeficitWithoutStorage_kWh = sum(dailyLoadDeficit_kWh);

    summary.meanDailyLoadEnergy_kWh = mean(dailyLoadEnergy_kWh);
    summary.meanDailyPVEnergy_kWh = mean(dailyPVEnergy_kWh);
    summary.maxDailyLoadPeak_kW = max(dailyLoadPeak_kW);
    summary.meanDailyLoadPeak_kW = mean(dailyLoadPeak_kW);

    summary.meanSelfSufficiency_noBESS = mean(selfSufficiency_noBESS, 'omitnan');
    summary.meanSelfConsumption_noBESS = mean(selfConsumption_noBESS, 'omitnan');
    summary.meanPVLoadEnergyRatio = mean(pvLoadEnergyRatio, 'omitnan');
    summary.meanPeakTimeDifference_h = mean(peakTimeDifference_h, 'omitnan');
    summary.meanLoadPVCorrelation = mean(dailyCorrelation, 'omitnan');

    summary.weekday.meanLoadEnergy_kWh = mean(dailyLoadEnergy_kWh(~isWeekend), 'omitnan');
    summary.weekday.meanLoadPeak_kW = mean(dailyLoadPeak_kW(~isWeekend), 'omitnan');
    summary.weekend.meanLoadEnergy_kWh = mean(dailyLoadEnergy_kWh(isWeekend), 'omitnan');
    summary.weekend.meanLoadPeak_kW = mean(dailyLoadPeak_kW(isWeekend), 'omitnan');

    % ---------------------------------------------------------------------
    % 12) Atlagprofilok
    % ---------------------------------------------------------------------
    avgProfiles = struct();

    avgProfiles.time_h = time_h;
    avgProfiles.loadMean_kW = mean(loadMatrix_kW, 1);
    avgProfiles.pvMean_kW = mean(pvMatrix_kW, 1);
    avgProfiles.directPVMean_kW = mean(directPV_kW, 1);
    avgProfiles.surplusMean_kW = mean(pvSurplus_kW, 1);
    avgProfiles.deficitMean_kW = mean(loadDeficit_kW, 1);

    avgProfiles.weekdayLoadMean_kW = mean(loadMatrix_kW(~isWeekend, :), 1, 'omitnan');
    avgProfiles.weekendLoadMean_kW = mean(loadMatrix_kW(isWeekend, :), 1, 'omitnan');
    avgProfiles.weekdayPVMean_kW = mean(pvMatrix_kW(~isWeekend, :), 1, 'omitnan');
    avgProfiles.weekendPVMean_kW = mean(pvMatrix_kW(isWeekend, :), 1, 'omitnan');

    seasons = ["Winter", "Spring", "Summer", "Autumn"];

    for s = 1:numel(seasons)

        mask = seasonName == seasons(s);

        avgProfiles.season(s).name = seasons(s);
        avgProfiles.season(s).nDays = sum(mask);
        avgProfiles.season(s).loadMean_kW = mean(loadMatrix_kW(mask, :), 1, 'omitnan');
        avgProfiles.season(s).pvMean_kW = mean(pvMatrix_kW(mask, :), 1, 'omitnan');
        avgProfiles.season(s).deficitMean_kW = mean(loadDeficit_kW(mask, :), 1, 'omitnan');
        avgProfiles.season(s).surplusMean_kW = mean(pvSurplus_kW(mask, :), 1, 'omitnan');
    end

    % ---------------------------------------------------------------------
    % 13) Teljesitmenymintak es invertermeretezes napi csucsokbol
    % ---------------------------------------------------------------------
    powerSamples = struct();

    % Teljes idosoros mintak megmaradnak elemzeshez/debughoz.
    powerSamples.load_kW = loadMatrix_kW(:);
    powerSamples.pv_kW = pvMatrix_kW(:);
    powerSamples.directPV_kW = directPV_kW(:);
    powerSamples.pvSurplus_kW = pvSurplus_kW(:);
    powerSamples.loadDeficit_kW = loadDeficit_kW(:);

    % Invertermerezes alapja: napi csucsteljesitmeny.
    powerSamples.dailyLoadPeak_kW = dailyLoadPeak_kW(:);

    inverterSizing = local_estimate_inverter_sizes_from_daily_peaks( ...
        dailyLoadPeak_kW, ...
        cfg.analysis.inverterSizing);

    % Frissitett inverter meretek visszairasa a teljes szimulacios cfg-be.
    cfg.candidates.P_inv_kW_vec = inverterSizing.suggestedInverterSizes_kW(:).';
    cfg.inverter.P_inv_kW = cfg.candidates.P_inv_kW_vec(1);

    fprintf('\nJavasolt inverter meretek NAPI FOGYASZTASI CSUCS percentilisek alapjan:\n');
    disp(inverterSizing.candidateTable);

    fprintf('cfg.candidates.P_inv_kW_vec frissitve:\n');
    disp(cfg.candidates.P_inv_kW_vec);

    % ---------------------------------------------------------------------
    % 14) Kimeneti struktura
    % ---------------------------------------------------------------------
    analysisResult = struct();

    analysisResult.updatedCfg = cfg;

    analysisResult.dailyTable = dailyTable;
    analysisResult.monthlyTable = monthlyTable;

    analysisResult.summary = summary;
    analysisResult.avgProfiles = avgProfiles;
    analysisResult.monthlyProfiles = monthlyProfiles;
    analysisResult.weekdayProfiles = weekdayProfiles;

    analysisResult.loadMatrix_kW = loadMatrix_kW;
    analysisResult.pvMatrix_kW = pvMatrix_kW;
    analysisResult.directPV_kW = directPV_kW;
    analysisResult.pvSurplus_kW = pvSurplus_kW;
    analysisResult.loadDeficit_kW = loadDeficit_kW;

    analysisResult.powerSamples = powerSamples;
    analysisResult.inverterSizing = inverterSizing;

    % ---------------------------------------------------------------------
    % 15) Mentes
    % ---------------------------------------------------------------------
    save(fullfile(savePath, 'self_consumption_load_pv_profile_analysis.mat'), ...
        'analysisResult', 'cfg');

    writetable(dailyTable, ...
        fullfile(savePath, 'self_consumption_daily_analysis_table.csv'));

    writetable(monthlyTable, ...
        fullfile(savePath, 'self_consumption_monthly_analysis_table.csv'));

    writetable(inverterSizing.percentileTable, ...
        fullfile(savePath, 'daily_load_peak_percentile_table.csv'));

    writetable(inverterSizing.histogramTable, ...
        fullfile(savePath, 'daily_load_peak_histogram_table.csv'));

    writetable(inverterSizing.candidateTable, ...
        fullfile(savePath, 'suggested_inverter_sizes_from_daily_peaks.csv'));

    if makePlots
        local_plot_results(analysisResult, cfg, figurePath);
    end

    fprintf('\nElemzes kesz.\n');
    fprintf('Eredmeny mentve: %s\n', ...
        fullfile(savePath, 'self_consumption_load_pv_profile_analysis.mat'));

    fprintf('Frissitett inverter candidate vektor:\n');
    disp(cfg.candidates.P_inv_kW_vec);
end


% =========================================================================
% CFG DEFAULTOK
% =========================================================================
function cfg = local_apply_analysis_defaults(cfg)

    if ~isfield(cfg, 'paths')
        error('cfg.paths hianyzik.');
    end

    if ~isfield(cfg.paths, 'base')
        error('cfg.paths.base hianyzik.');
    end

    if ~isfield(cfg.paths, 'results')
        cfg.paths.results = fullfile(cfg.paths.base, 'results');
    end

    if ~isfield(cfg.paths, 'figures')
        cfg.paths.figures = fullfile(cfg.paths.results, 'figures');
    end

    if ~isfield(cfg.paths, 'consumption')
        cfg.paths.consumption = fullfile(cfg.paths.base, 'consumption');
    end

    if ~isfield(cfg.paths, 'production')
        cfg.paths.production = fullfile(cfg.paths.base, 'production');
    end

    if ~isfield(cfg.paths, 'analysis')
        cfg.paths.analysis = fullfile(cfg.paths.results, 'feldolgozas');
    end

    if ~isfield(cfg.paths, 'analysisFigures')
        cfg.paths.analysisFigures = fullfile(cfg.paths.figures, 'load_pv_analysis');
    end

    if ~exist(cfg.paths.results, 'dir')
        mkdir(cfg.paths.results);
    end

    if ~exist(cfg.paths.figures, 'dir')
        mkdir(cfg.paths.figures);
    end

    if ~exist(cfg.paths.analysis, 'dir')
        mkdir(cfg.paths.analysis);
    end

    if ~exist(cfg.paths.analysisFigures, 'dir')
        mkdir(cfg.paths.analysisFigures);
    end

    if ~isfield(cfg, 'pv')
        error('cfg.pv hianyzik.');
    end

    if ~isfield(cfg.pv, 'tiltX')
        cfg.pv.tiltX = 35;
    end

    if ~isfield(cfg.pv, 'tiltZ')
        cfg.pv.tiltZ = 180;
    end

    if ~isfield(cfg, 'analysis')
        cfg.analysis = struct();
    end

    % Elemzesi PV meret.
    % Ha 700 kWp szerepel a candidate tartomanyban, azt valasztjuk,
    % mert a korabbi abrazolasban is ez szerepelt.
    if ~isfield(cfg.analysis, 'PV_kW_forAnalysis')

        if isfield(cfg, 'candidates') && isfield(cfg.candidates, 'PV_kW')

            pvVec = cfg.candidates.PV_kW(:);
            idx700 = find(abs(pvVec - 700) < 1e-9, 1, 'first');

            if ~isempty(idx700)
                cfg.analysis.PV_kW_forAnalysis = pvVec(idx700);
            else
                cfg.analysis.PV_kW_forAnalysis = median(pvVec);
            end
        else
            cfg.analysis.PV_kW_forAnalysis = 700;
        end
    end

    if ~isfield(cfg.analysis, 'makePlots')
        cfg.analysis.makePlots = true;
    end

    if ~isfield(cfg.analysis, 'inverterSizing')
        cfg.analysis.inverterSizing = struct();
    end

    % Az invertermeretezes napi fogyasztasi csucsokbol tortenik.
    if ~isfield(cfg.analysis.inverterSizing, 'percentiles')
        cfg.analysis.inverterSizing.percentiles = [90 95 98 99];
    end

    if ~isfield(cfg.analysis.inverterSizing, 'reportPercentiles')
        cfg.analysis.inverterSizing.reportPercentiles = [50 75 90 95 98 99 99.5 100];
    end

    if ~isfield(cfg.analysis.inverterSizing, 'roundStep_kW')
        cfg.analysis.inverterSizing.roundStep_kW = 50;
    end

    if ~isfield(cfg.analysis.inverterSizing, 'histBinWidth_kW')
        cfg.analysis.inverterSizing.histBinWidth_kW = 25;
    end

    if ~isfield(cfg.analysis.inverterSizing, 'includeMaximum')
        cfg.analysis.inverterSizing.includeMaximum = true;
    end

    if ~isfield(cfg.analysis.inverterSizing, 'maxCandidateCount')
        cfg.analysis.inverterSizing.maxCandidateCount = 4;
    end
end


% =========================================================================
% DATUM ES PV SEGEDFUGGVENYEK
% =========================================================================
function dt = local_date_from_file(fileName)

    tok = regexp(fileName, '(\d{4})_(\d{2})_(\d{2})', 'tokens', 'once');

    if isempty(tok)
        error('Nem sikerult datumot kinyerni a fajlnevbol: %s', fileName);
    end

    y = str2double(tok{1});
    m = str2double(tok{2});
    d = str2double(tok{3});

    if y < 100
        y = y + 2000;
    end

    dt = datetime(y, m, d);
end


function pv_W = local_get_pv_from_resultbuffer(resultBuffer, tiltX, tiltZ)

    T = resultBuffer.results;

    mask = abs(T.tiltX - tiltX) < 1e-9 & abs(T.tiltZ - tiltZ) < 1e-9;

    if ~any(mask)
        error('Nincs ilyen orientacio a resultBuffer-ben: tiltX = %.1f, tiltZ = %.1f', tiltX, tiltZ);
    end

    pv_W = T.tPDC{find(mask, 1, 'first')};
end


function s = local_season_name(monthNum)

    if ismember(monthNum, [12, 1, 2])
        s = "Winter";
    elseif ismember(monthNum, [3, 4, 5])
        s = "Spring";
    elseif ismember(monthNum, [6, 7, 8])
        s = "Summer";
    else
        s = "Autumn";
    end
end


% =========================================================================
% INVERTER MERETEZES NAPI FOGYASZTASI CSUCSOK ALAPJAN
% =========================================================================
function inverterSizing = local_estimate_inverter_sizes_from_daily_peaks(dailyLoadPeak_kW, sizingCfg)
% LOCAL_ESTIMATE_INVERTER_SIZES_FROM_DAILY_PEAKS
%
% Invertermeretek meghatarozasa a napi fogyasztasi csucsteljesitmenyekbol.
%
% Fontos:
%   Nem az osszes napon beluli teljesitmenymintabol dolgozik,
%   hanem naponta egyetlen ertekbol:
%
%       dailyLoadPeak_kW(d) = max(loadMatrix_kW(d, :))
%
% A modszer:
%   1) osszegyujti a pozitiv napi csucsokat,
%   2) hisztogramot keszit a napi csucsokbol,
%   3) kiszamolja a megadott percentiliseket,
%   4) felkerekiti oket a megadott teljesitmenylepcsore,
%   5) legfeljebb maxCandidateCount darab invertermeretet ad vissza.

    x = dailyLoadPeak_kW(:);
    x = x(~isnan(x));
    xPositive = x(x > 1e-9);

    if isempty(xPositive)
        error('Nincs pozitiv napi fogyasztasi csucsteljesitmeny az inverter meretezeshez.');
    end

    reportP = sizingCfg.reportPercentiles(:);
    sizingP = sizingCfg.percentiles(:);

    roundStep_kW = sizingCfg.roundStep_kW;
    histBinWidth_kW = sizingCfg.histBinWidth_kW;

    % ---------------------------------------------------------------------
    % Percentilis tabla - napi csucsokbol
    % ---------------------------------------------------------------------
    percentileTable = table();

    percentileTable.Percentile = reportP;
    percentileTable.DailyLoadPeak_kW = local_percentile_vector(xPositive, reportP);

    % ---------------------------------------------------------------------
    % Hisztogram - napi csucsokbol
    % ---------------------------------------------------------------------
    maxPower = max(xPositive);

    maxEdge = ceil(maxPower / histBinWidth_kW) * histBinWidth_kW;

    if maxEdge <= 0
        maxEdge = histBinWidth_kW;
    end

    edges = 0:histBinWidth_kW:maxEdge;

    if numel(edges) < 2
        edges = [0 histBinWidth_kW];
    end

    counts = histcounts(xPositive, edges);

    histogramTable = table();

    histogramTable.BinStart_kW = edges(1:end-1).';
    histogramTable.BinEnd_kW = edges(2:end).';
    histogramTable.BinCenter_kW = ((edges(1:end-1) + edges(2:end)) / 2).';
    histogramTable.Count = counts(:);
    histogramTable.RelativeFrequency = counts(:) / sum(counts);
    histogramTable.CumulativeFrequency = cumsum(counts(:)) / sum(counts);

    % ---------------------------------------------------------------------
    % Javasolt invertermeretek - napi csucs percentilisekbol
    % ---------------------------------------------------------------------
    rawSizes_kW = local_percentile_vector(xPositive, sizingP);

    roundedSizes_kW = ceil(rawSizes_kW / roundStep_kW) * roundStep_kW;

    [roundedUnique, ia] = unique(roundedSizes_kW, 'stable');

    rawUnique = rawSizes_kW(ia);
    pUnique = sizingP(ia);

    if sizingCfg.includeMaximum

        maxRounded = ceil(maxPower / roundStep_kW) * roundStep_kW;

        if ~ismember(maxRounded, roundedUnique)
            roundedUnique(end+1, 1) = maxRounded;
            rawUnique(end+1, 1) = maxPower;
            pUnique(end+1, 1) = 100;
        end
    end

    maxCandidateCount = sizingCfg.maxCandidateCount;

    if numel(roundedUnique) > maxCandidateCount

        idx = round(linspace(1, numel(roundedUnique), maxCandidateCount));

        roundedUnique = roundedUnique(idx);
        rawUnique = rawUnique(idx);
        pUnique = pUnique(idx);
    end

    candidateTable = table();

    candidateTable.Basis = repmat("Napi fogyasztasi csucsteljesitmeny", numel(roundedUnique), 1);
    candidateTable.BasisPercentile = pUnique(:);
    candidateTable.RawDailyLoadPeak_kW = rawUnique(:);
    candidateTable.SuggestedInverter_kW = roundedUnique(:);

    inverterSizing = struct();

    inverterSizing.basis = "daily_load_peak";
    inverterSizing.basisLabel = "Napi fogyasztasi csucsteljesitmeny";
    inverterSizing.roundStep_kW = roundStep_kW;
    inverterSizing.histBinWidth_kW = histBinWidth_kW;

    inverterSizing.sizingPercentiles = sizingP;
    inverterSizing.reportPercentiles = reportP;

    inverterSizing.percentileTable = percentileTable;
    inverterSizing.histogramTable = histogramTable;
    inverterSizing.candidateTable = candidateTable;

    inverterSizing.suggestedInverterSizes_kW = roundedUnique(:).';

    inverterSizing.dailyLoadPeakVector_kW = xPositive;
end


function values = local_percentile_vector(x, pVec)

    x = x(:);
    x = x(~isnan(x));

    values = NaN(size(pVec));

    if isempty(x)
        return;
    end

    x = sort(x);

    for i = 1:numel(pVec)
        values(i) = local_percentile_sorted(x, pVec(i));
    end
end


function q = local_percentile_sorted(xSorted, p)

    if isempty(xSorted)
        q = NaN;
        return;
    end

    if numel(xSorted) == 1
        q = xSorted(1);
        return;
    end

    p = max(0, min(100, p));

    pos = 1 + (p / 100) * (numel(xSorted) - 1);

    lo = floor(pos);
    hi = ceil(pos);

    if lo == hi
        q = xSorted(lo);
    else
        w = pos - lo;
        q = (1 - w) * xSorted(lo) + w * xSorted(hi);
    end
end


% =========================================================================
% ABRAZOLAS
% =========================================================================
function local_plot_results(analysisResult, cfg, figurePath)

    M = analysisResult.monthlyTable;
    MP = analysisResult.monthlyProfiles;
    WP = analysisResult.weekdayProfiles;
    IS = analysisResult.inverterSizing;

    time_h = analysisResult.summary.time_h;

    xTicks = 0:6:24;
    xTickLabels = {'00:00', '06:00', '12:00', '18:00', '24:00'};

    % ---------------------------------------------------------------------
    % 1) Havi atlagos napon beluli fogyasztasi gorbek
    % ---------------------------------------------------------------------
    fig1 = figure('Name', 'Havi atlagos napon beluli fogyasztasi gorbek', ...
        'Color', 'w', ...
        'Position', [100, 100, 1050, 520]);

    hold on;
    grid on;

    for m = 1:12
        if MP.nDays(m) > 0
            plot(time_h, MP.loadMean_kW(m, :), ...
                'LineWidth', 1.1, ...
                'DisplayName', MP.monthNames(m));
        end
    end

    xlabel('Idő');
    ylabel('Teljesítmény [kW]');
    title('Havi átlagos napon belüli fogyasztási görbék');
    xlim([0 24]);
    xticks(xTicks);
    xticklabels(xTickLabels);
    legend('Location', 'eastoutside');

    saveas(fig1, fullfile(figurePath, '01_havi_atlagos_napon_beluli_fogyasztasi_gorbek.png'));

    % ---------------------------------------------------------------------
    % 2) Havi fogyasztas vs PV termeles es felhasznalt energia
    % ---------------------------------------------------------------------
    fig2 = figure('Name', 'Havi energiafelhasznalas vs PV termeles', ...
        'Color', 'w', ...
        'Position', [120, 120, 1050, 560]);

    monthIdx = 1:12;

    hold on;
    grid on;

    area(monthIdx, M.PVEnergy_kWh, ...
        'FaceAlpha', 0.25, ...
        'DisplayName', 'Össztermelés');

    area(monthIdx, M.DirectPVUse_kWh, ...
        'FaceAlpha', 0.45, ...
        'DisplayName', 'Közvetlenül felhasznált PV energia');

    bar(monthIdx, M.LoadEnergy_kWh, ...
        0.55, ...
        'FaceAlpha', 0.70, ...
        'DisplayName', 'Fogyasztás');

    xlabel('Hónap');
    ylabel('Energia [kWh]');
    title(sprintf('%.0f kWp-es rendszer termelésének közvetlen illeszkedése a fogyasztáshoz', ...
        cfg.analysis.PV_kW_forAnalysis));

    xticks(monthIdx);
    xticklabels(M.MonthName);
    xtickangle(45);

    legend('Location', 'best');

    saveas(fig2, fullfile(figurePath, '02_havi_energiafelhasznalas_vs_pv_termeles.png'));

    % ---------------------------------------------------------------------
    % 3) Heti napok szerinti napi atlagos fogyasztasi gorbek
    % ---------------------------------------------------------------------
    fig3 = figure('Name', 'Napi atlagos fogyasztasi gorbek a het kulonbozo napjain', ...
        'Color', 'w', ...
        'Position', [140, 140, 1050, 520]);

    hold on;
    grid on;

    for i = 1:7
        if WP.nDays(i) > 0
            plot(time_h, WP.loadMean_kW(i, :), ...
                'LineWidth', 1.25, ...
                'DisplayName', WP.weekdayNames(i));
        end
    end

    xlabel('Idő');
    ylabel('Teljesítmény [kW]');
    title('Heti napok szerinti átlagos fogyasztási görbék');
    xlim([0 24]);
    xticks(xTicks);
    xticklabels(xTickLabels);
    legend('Location', 'eastoutside');

    saveas(fig3, fullfile(figurePath, '03_heti_napok_atlagos_fogyasztasi_gorbei.png'));

    % ---------------------------------------------------------------------
    % 4) Napi fogyasztasi csucsteljesitmeny hisztogram inverter meretezeshez
    % ---------------------------------------------------------------------
    fig4 = figure('Name', 'Napi fogyasztasi csucs hisztogram inverter meretezeshez', ...
        'Color', 'w', ...
        'Position', [160, 160, 1050, 560]);

    hold on;
    grid on;

    H = IS.histogramTable;
    C = IS.candidateTable;

    bar(H.BinCenter_kW, H.Count, 1.0, ...
        'FaceAlpha', 0.70, ...
        'DisplayName', 'Napi fogyasztási csúcsteljesítmény');

    for i = 1:height(C)

        xline(C.SuggestedInverter_kW(i), '--', ...
            sprintf('P%.1f -> %.0f kW', C.BasisPercentile(i), C.SuggestedInverter_kW(i)), ...
            'LineWidth', 1.2, ...
            'LabelOrientation', 'horizontal', ...
            'HandleVisibility', 'off');
    end

    xlabel('Napi fogyasztási csúcsteljesítmény [kW]');
    ylabel('Napok száma');
    title('Napi fogyasztási csúcsteljesítmények és percentilis alapú inverterméretezés');
    legend('Location', 'best');

    saveas(fig4, fullfile(figurePath, '04_napi_fogyasztasi_csucs_hisztogram_inverter_meretezeshez.png'));
end