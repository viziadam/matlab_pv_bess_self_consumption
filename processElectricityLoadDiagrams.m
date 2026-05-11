
function result = processElectricityLoadDiagrams(txtFilePath)
% PROCESSELECTRICITYLOADDIAGRAMS
%processElectricityLoadDiagrams('C:\Users\Vizi\Downloads\electricityloaddiagrams20112014')
% Feldolgozza az ElectricityLoadDiagrams20112014 fogyasztasi adatfajlt.
%
% Bemenet:
%   txtFilePath - a txt fajl teljes eleresi utvonala
%
% Kimenet:
%   result - struktura a feldolgozott adatokkal es jellemzokkel
%
% A fajl vart formatuma:
%   - pontosvesszovel tagolt fajl
%   - elso oszlop: idobelyeg
%   - tovabbi oszlopok: MT_001 ... MT_370 fogyasztok
%   - decimalis jel: vesszo
%   - idofelbontas: 15 perc
%
% Megjegyzes:
%   A dataset nem tartalmaz hivatalos residential / commercial / industry
%   cimkeket. A besorolas heurisztikus, fogyasztasi mintazat alapjan tortenik.

    %% 0. Alapbeallitasok

    maxProfilesPerFigure = 50;

    if ~isfile(txtFilePath)
        error('A megadott fajl nem talalhato: %s', txtFilePath);
    end

    fprintf('Fajl feldolgozasa indul...\n');
    fprintf('Bemeneti fajl: %s\n', txtFilePath);

    %% 1. Decimalis vesszo kezelese ideiglenes fajllal

    % A fajlban a decimalis jel vesszo, pl. 71,7703.
    % A MATLAB biztosabb numerikus beolvasasa miatt ideiglenesen pontta alakitjuk.
    tempFilePath = createDecimalDotCopy(txtFilePath);
    cleanupObj = onCleanup(@() deleteTempFile(tempFilePath));

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

    nSamples = size(P, 1);
    nCustomers = size(P, 2);

    fprintf('Mintak szama: %d\n', nSamples);
    fprintf('Fogyasztok szama: %d\n', nCustomers);

    %% 4. Mintaveteli ido meghatarozasa

    dt_h = hours(median(diff(time), 'omitnan'));

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
        dayOfWeek = weekday(timeWin); % 1 = vasarnap, 7 = szombat

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

            avgWeekendPower = weekendEnergy / weekendHours;
            avgWeekdayPower = weekdayEnergy / weekdayHours;

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

    %% 7. Heurisztikus kategorizalas

    category = strings(1, nValidCustomers);

    qLowEnergy = quantile(avgDailyEnergy_kWh, 0.33);
    qHighEnergy = quantile(avgDailyEnergy_kWh, 0.75);
    qHighPeak = quantile(peakPower_kW, 0.75);

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

    %% 8. Osszefoglalo tabla

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
            'WeekendToWeekdayRatio'});

    fprintf('\nKategoriak osszesitese:\n');
    disp(groupsummary(summaryTable, 'Category'));

    %% 9. Plottolas kategoriankent, maximum 50 profil / abra

    timeOfDay = duration(0, 0, 0) + minutes((0:samplesPerDay-1) * dt_h * 60);

    plotDailyProfilesByCategory( ...
        dailyProfiles, ...
        timeOfDay, ...
        customerNames, ...
        category, ...
        summaryTable, ...
        maxProfilesPerFigure);

    %% 10. Kategoriaatlagok egy kozos abran

    plotCategoryMeanProfiles(dailyProfiles, timeOfDay, category);

    %% 11. Kimenet

    result = struct();

    result.time = time;
    result.power_kW = P;
    result.customerNames = customerNames;
    result.category = category;
    result.summaryTable = summaryTable;
    result.dailyProfiles = dailyProfiles;
    result.timeOfDay = timeOfDay;
    result.dt_h = dt_h;

    fprintf('Feldolgozas kesz.\n');

end


function tempFilePath = createDecimalDotCopy(inputFilePath)
% CREATEDECIMALDOTCOPY
% Letrehoz egy ideiglenes fajlt, amelyben a decimalis vesszok pontta
% vannak alakitva.

    [~, fileName, fileExt] = fileparts(char(inputFilePath));

    if strlength(fileExt) == 0
        fileExt = ".txt";
    end

    tempFilePath = fullfile(tempdir, [fileName '_decimaldot_tmp' char(fileExt)]);

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

        profiles(:, d) = pDay;
    end

    avgProfile = mean(profiles, 2, 'omitnan');

end


function plotDailyProfilesByCategory(dailyProfiles, timeOfDay, customerNames, category, summaryTable, maxProfilesPerFigure)
% PLOTDAILYPROFILESBYCATEGORY
% Kategoriankent kirajzolja az atlagos napi fogyasztasi profilokat.
% Egy abran legfeljebb maxProfilesPerFigure db fogyaszto szerepel.

    categories = ["residential", "commercial", "industry"];

    for k = 1:numel(categories)

        catName = categories(k);
        idxCat = find(category == catName);

        if isempty(idxCat)
            fprintf('Nincs fogyaszto ebben a kategoriaban: %s\n', catName);
            continue;
        end

        % Rendezés atlagos napi energia szerint csokkeno sorrendbe,
        % hogy az erosebb fogyasztok elore keruljenek.
        catSummary = summaryTable(idxCat, :);
        [~, sortIdx] = sort(catSummary.AvgDailyEnergy_kWh, 'descend');
        idxCat = idxCat(sortIdx);

        nCat = numel(idxCat);
        nFigures = ceil(nCat / maxProfilesPerFigure);

        fprintf('%s kategoria: %d fogyaszto, %d abra\n', ...
            upper(catName), nCat, nFigures);

        for figIdx = 1:nFigures

            startIdx = (figIdx - 1) * maxProfilesPerFigure + 1;
            endIdx = min(figIdx * maxProfilesPerFigure, nCat);

            selectedIdx = idxCat(startIdx:endIdx);

            selectedProfiles = dailyProfiles(:, selectedIdx);
            selectedNames = customerNames(selectedIdx);

            figure('Color', 'w', ...
                   'Name', sprintf('%s profiles %d of %d', upper(catName), figIdx, nFigures));

            hold on;
            grid on;

            % Egyedi napi profilok.
            plot(timeOfDay, selectedProfiles, 'LineWidth', 0.8);

            % Az adott abran szereplo profilok atlaga.
            meanProfile = mean(selectedProfiles, 2, 'omitnan');
            plot(timeOfDay, meanProfile, 'k', 'LineWidth', 3);

            xlabel('Napon beluli ido');
            ylabel('Atlagos teljesitmeny [kW]');

            title(sprintf('%s jellegu fogyasztok napi atlagprofiljai - %d/%d. abra', ...
                upper(catName), figIdx, nFigures));

            % Ha keves profil van, kiirjuk a fogyasztoneveket.
            % 50 profilnal a teljes legenda mar olvashatatlan lenne.
            if numel(selectedIdx) <= 10
                legend([selectedNames(:); "Atlag"], 'Location', 'best');
            else
                legend('Egyedi napi profilok', 'Atlag', 'Location', 'best');
            end

            hold off;
        end
    end

end


function plotCategoryMeanProfiles(dailyProfiles, timeOfDay, category)
% PLOTCATEGORYMEANPROFILES
% Egy kozos abran kirajzolja a kategoriak atlagos napi profiljait.

    categories = ["residential", "commercial", "industry"];

    figure('Color', 'w', 'Name', 'Category mean profiles');

    hold on;
    grid on;

    for k = 1:numel(categories)

        catName = categories(k);
        idx = category == catName;

        if any(idx)
            meanProfile = mean(dailyProfiles(:, idx), 2, 'omitnan');

            plot(timeOfDay, meanProfile, ...
                'LineWidth', 2.5, ...
                'DisplayName', upper(catName));
        end
    end

    xlabel('Napon beluli ido');
    ylabel('Atlagos teljesitmeny [kW]');
    title('Kategoriak atlagos napi fogyasztasi profiljainak osszehasonlitasa');
    legend('Location', 'best');

    hold off;

end