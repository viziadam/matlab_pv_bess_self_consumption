function evalCfg = create_evaluation_config(cfg)
% CREATE_EVALUATION_CONFIG
%
% Külön kiértékelési konfiguráció a grid-connected PV+BESS
% önfogyasztás-növelési vizsgálathoz.
%
% Cél:
%   - csak a riporthoz szükséges táblázatok mentése
%   - LCSE, NPV és self-sufficiency színezett táblázatok készítése
%   - 3 legjobb jelölt összesítő táblázata:
%       1) csak PV
%       2) kisebb BESS
%       3) nagyobb BESS
%
% Használat:
%
%   cfg = create_configurations(basePath);
%   evalCfg = create_evaluation_config(cfg);
%   evaluationResult = evaluation(cfg, evalCfg);

    % ---------------------------------------------------------------------
    % 0) Kötelező cfg mezők ellenőrzése
    % ---------------------------------------------------------------------
    if ~isfield(cfg, 'paths')
        error('cfg.paths hiányzik.');
    end

    if ~isfield(cfg.paths, 'results')
        error('cfg.paths.results hiányzik.');
    end

    if ~isfield(cfg.paths, 'figures')
        error('cfg.paths.figures hiányzik.');
    end

    if ~isfield(cfg, 'cost')
        error('cfg.cost hiányzik.');
    end

    requiredCostFields = { ...
        'pv_huf_per_kWp', ...
        'bess_huf_per_kWh', ...
        'bess_power_huf_per_kW', ...
        'inverter_huf_per_kW', ...
        'grid_import_huf_per_kWh'};

    for i = 1:numel(requiredCostFields)
        f = requiredCostFields{i};

        if ~isfield(cfg.cost, f)
            error('cfg.cost.%s hiányzik.', f);
        end
    end

    if ~isfield(cfg, 'grid')
        error('cfg.grid hiányzik.');
    end

    if ~isfield(cfg.grid, 'allowExport')
        error('cfg.grid.allowExport hiányzik.');
    end

    if logical(cfg.grid.allowExport) && ~isfield(cfg.cost, 'grid_export_huf_per_kWh')
        error('cfg.cost.grid_export_huf_per_kWh hiányzik, mert cfg.grid.allowExport = true.');
    end

    % ---------------------------------------------------------------------
    % 1) Input / output
    % ---------------------------------------------------------------------
    evalCfg = struct();

    % Ezt olvassa be az evaluation.
    % DC-csatolt futás esetén:
    evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_dccoupled.mat');

    % Ha AC-csatolt eredményt akarsz kiértékelni, akkor erre írd át:
    % evalCfg.input.resultFilePath = fullfile(cfg.paths.results, 'results_accoupled.mat');

    % Külön evaluation mappa.
    evalCfg.output.baseFolder = fullfile(cfg.paths.figures, 'evaluation');

    if ~isfolder(evalCfg.output.baseFolder)
        mkdir(evalCfg.output.baseFolder);
    end

    % Csak a szükséges riportanyagokat mentsük.
    evalCfg.output.saveEvaluationMat = true;

    % Teljes candidate táblát most ne mentsen külön CSV-be,
    % mert túl sok és sablonhoz felesleges.
    evalCfg.output.saveEvaluationCsv = false;

    % A riportba szánt táblázatokat mentse.
    evalCfg.output.saveReportTables = true;

    % ---------------------------------------------------------------------
    % 2) Plot beállítások
    % ---------------------------------------------------------------------
    evalCfg.plots.makePlots = true;

    % Alapból ne készítsen 3D scattert.
    % Ha később kell, állítsd true-ra.
    evalCfg.plots.make3DScatter = false;

    % Ha make3DScatter = true, akkor:
    % false -> csak a kompakt metrikákat rajzolja
    % true  -> minden megadott metrikát rajzol
    evalCfg.plots.showAllMetrics = false;

    % ---------------------------------------------------------------------
    % 3) Legjobb rendszer kiválasztása
    % ---------------------------------------------------------------------
    % Lehetséges értékek:
    %   "minLCSE"
    %   "maxNPV"
    %   "minDiscountedPayback"
    %   "maxPeriodNetValue"
    %
    % Sablonhoz és gazdasági összehasonlításhoz én LCSE-t javaslok,
    % mert közvetlenül azt mondja meg, mennyibe kerül 1 kWh hálózatról
    % kiváltott energia.
    evalCfg.selection.mode = "minLCSE";

    % Minimális elvárt hálózati importcsökkentés.
    % Ha nem akarsz előszűrést, legyen 0.
    evalCfg.selection.minGridImportReduction_pct = 0;

    % Csak pozitív NPV-s rendszerek közül válasszon-e.
    % Ha true, akkor gazdaságilag szigorúbb, de előfordulhat,
    % hogy nem talál minden kategóriára jelöltet.
    evalCfg.selection.requirePositiveNPV = false;

    % Globálisan megkövetelje-e, hogy legyen BESS.
    % Ezt itt false-on kell hagyni, mert külön akarunk "csak PV" jelöltet is.
    evalCfg.selection.requireBESS = false;

    % ---------------------------------------------------------------------
    % 4) A 3 összesítő jelölt kategóriája
    % ---------------------------------------------------------------------
    % 1) Csak PV:
    %       E_BESS_kWh <= 0
    %
    % 2) Kisebb BESS:
    %       0 < BESS_PV_ratio <= smallBessMaxRatio
    %
    % 3) Nagyobb BESS:
    %       BESS_PV_ratio >= largeBessMinRatio
    %
    % Ezeket az értékeket a saját candidate tartományodhoz igazítsd.
    % Ha BESS_PV_vec = 0:0.25:3.5 körül mozog, akkor ez jó induló.
    evalCfg.report.smallBessMaxRatio = 1.0;
    evalCfg.report.largeBessMinRatio = 2.0;

    % ---------------------------------------------------------------------
    % 5) Színezett táblázatok
    % ---------------------------------------------------------------------
    % Csak ezekből készüljön színezett táblázat:
    %
    %   1) LCSE
    %   2) NPV
    %   3) Self-sufficiency
    %
    % direction:
    %   "min" -> kisebb érték a jobb, zöld
    %   "max" -> nagyobb érték a jobb, zöld

    evalCfg.report.matrixMetrics = struct( ...
        'field', { ...
            'LCSE_HUF_per_kWh_saved', ...
            'NPV_millionHUF', ...
            'selfSufficiency_pct' ...
        }, ...
        'label', { ...
            'LCSE - megtakarított energia fajlagos költsége', ...
            'Nettó jelenérték', ...
            'Önellátási arány' ...
        }, ...
        'unit', { ...
            'Ft/kWh', ...
            'millió Ft', ...
            '%' ...
        }, ...
        'direction', { ...
            'min', ...
            'max', ...
            'max' ...
        }, ...
        'fileTag', { ...
            'lcse', ...
            'npv', ...
            'self_sufficiency' ...
        });

    % ---------------------------------------------------------------------
    % 6) Opcionális 3D scatter metrikák
    % ---------------------------------------------------------------------
    % Most nem készülnek el, mert evalCfg.plots.make3DScatter = false.
    % De ha később bekapcsolod, ezek alapján fog ábrázolni.
    %
    % plotWhenCompact:
    %   true  -> akkor is rajzolja, ha showAllMetrics = false
    %   false -> csak akkor rajzolja, ha showAllMetrics = true

    evalCfg.metrics = struct( ...
        'field', { ...
            'LCSE_HUF_per_kWh_saved', ...
            'NPV_millionHUF', ...
            'selfSufficiency_pct' ...
        }, ...
        'label', { ...
            'LCSE - megtakarított energia fajlagos költsége', ...
            'Nettó jelenérték', ...
            'Önellátási arány' ...
        }, ...
        'unit', { ...
            'Ft/kWh', ...
            'millió Ft', ...
            '%' ...
        }, ...
        'direction', { ...
            'min', ...
            'max', ...
            'max' ...
        }, ...
        'plotWhenCompact', { ...
            true, ...
            true, ...
            true ...
        });

    % ---------------------------------------------------------------------
    % 7) Gazdasági feltételezések
    % ---------------------------------------------------------------------
    % Itt ne használjunk rejtett defaultot az evaluation-ben.
    % Minden gazdasági időtáv és diszkontráta itt legyen megadva.

    % A szimulált időszak hossza.
    % Nálad eddig 4 éves esettanulmány volt.
    evalCfg.economics.simYears = 4;

    % Gazdasági értékelési időtáv.
    evalCfg.economics.projectLifetime_years = 15;

    % PV hasznos élettartam.
    evalCfg.economics.pvLifetime_years = 25;

    % Inverter élettartam.
    evalCfg.economics.inverterLifetime_years = 15;

    % Diszkontráta.
    evalCfg.economics.discountRate = 0.06;

    % Éves OPEX arányok a beruházási költséghez képest.
    evalCfg.economics.pv_opex_frac_per_year = 0.015;
    evalCfg.economics.bess_opex_frac_per_year = 0.020;
    evalCfg.economics.inverter_opex_frac_per_year = 0.010;
end